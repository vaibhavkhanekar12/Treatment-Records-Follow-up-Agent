/**
 * Human-in-the-loop workflow for follow-up recommendations: approve, bulk-approve, edit, reject, override,
 * complete. Used by the work-queue LWC controller (and the send service for loading records).
 *
 * Enforcement (server-side, independent of the UI):
 *  1. records are read WITH USER_MODE (sharing + CRUD + FLS) and edit access is verified via UserRecordAccess;
 *  2. custom permissions gate approve / bulk-approve / override;
 *  3. status transitions are validated here;
 *  4. only then is DML performed in SYSTEM_MODE, because workflow and audit fields (Status, Approved By,
 *     Draft) are intentionally read-only to users so they cannot be changed outside this service.
 */
public with sharing class FollowUpRecommendationService {
    public static final String RECOMMENDATION_FIELDS =
        'Id, Name, Matter__c, Matter__r.Name, Recommendation_Type__c, Rule__c, Status__c, Priority__c, Audience__c, ' +
        'Channel__c, Reason__c, Gap_Days__c, Records_Age_Days__c, Prior_Follow_Up_Count__c, Last_Treatment_Date__c, ' +
        'AI_Rationale__c, Draft_Subject__c, Draft_Message__c, Draft_Source__c, Recipient_Contact__c, ' +
        'Recipient_Contact__r.Name, Recipient_Contact__r.Email, Recipient_Contact__r.MobilePhone, ' +
        'Recipient_Contact__r.Phone, Recipient_Contact__r.HasOptedOutOfEmail, Medical_Provider__c, ' +
        'Medical_Provider__r.Name, Medical_Provider__r.Email__c, Medical_Provider__r.Fax__c, Medical_Provider__r.Phone__c, ' +
        'Records_Request__c, Records_Request__r.Name, Assigned_To__c, Assigned_To__r.Name, Approved_By__c, ' +
        'Approved_By__r.Name, Approved_Date__c, Sent_Date__c, Sent_By__c, Delivery_Note__c, Task_Id__c, ' +
        'Closed_Date__c, Rejection_Reason__c, Case_Manager_Override__c, Override_Reason__c, Response_Received__c, ' +
        'Response_Received_Date__c, Response_Text__c, Response_Classification__c, Classification_Confidence__c, ' +
        'Next_Follow_Up_Date__c, Dedupe_Key__c, Related_Recommendation__c, Recommended_Date__c, CreatedDate';

    /** Loads recommendations with the running user's permissions and verifies edit access. */
    public static List<Follow_Up_Recommendation__c> loadForAction(Set<Id> recommendationIds) {
        if (recommendationIds == null || recommendationIds.isEmpty()) {
            throw new FollowUpException(Label.FollowUp_Error_No_Access);
        }
        List<Follow_Up_Recommendation__c> recs;
        try {
            recs = query(recommendationIds, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            throw new FollowUpException(Label.FollowUp_Error_No_Access);
        }
        if (recs.size() != recommendationIds.size()) {
            throw new FollowUpException(Label.FollowUp_Error_No_Access);
        }
        FollowUpSecurity.requireEditAccess(recommendationIds);
        return recs;
    }

    public static List<Follow_Up_Recommendation__c> query(Set<Id> recommendationIds, AccessLevel mode) {
        return Database.queryWithBinds(
            'SELECT ' + RECOMMENDATION_FIELDS + ' FROM Follow_Up_Recommendation__c WHERE Id IN :ids ORDER BY Name',
            new Map<String, Object>{ 'ids' => recommendationIds },
            mode
        );
    }

    /** Approves one recommendation, optionally saving case-manager edits in the same step. */
    public static Follow_Up_Recommendation__c approve(Id recommendationId, String editedSubject, String editedMessage) {
        FollowUpSecurity.requirePermission(FollowUpConstants.PERM_APPROVE, Label.FollowUp_Error_No_Approve_Permission);
        Follow_Up_Recommendation__c rec = loadForAction(new Set<Id>{ recommendationId })[0];
        requireStatus(rec, new Set<String>{ FollowUpConstants.STATUS_PENDING_REVIEW });
        applyEdits(rec, editedSubject, editedMessage);
        stampApproval(rec);
        save(new List<Follow_Up_Recommendation__c>{ rec });
        return rec;
    }

    /** Bulk approval is limited to unedited template drafts (e.g. monthly status updates). All or nothing. */
    public static List<Follow_Up_Recommendation__c> bulkApprove(List<Id> recommendationIds) {
        FollowUpSecurity.requirePermission(FollowUpConstants.PERM_APPROVE, Label.FollowUp_Error_No_Approve_Permission);
        FollowUpSecurity.requirePermission(FollowUpConstants.PERM_BULK_APPROVE, Label.FollowUp_Error_No_Bulk_Approve_Permission);
        List<Follow_Up_Recommendation__c> recs = loadForAction(new Set<Id>(recommendationIds));
        for (Follow_Up_Recommendation__c rec : recs) {
            requireStatus(rec, new Set<String>{ FollowUpConstants.STATUS_PENDING_REVIEW });
            if (FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c) && rec.Draft_Source__c != FollowUpConstants.DRAFT_TEMPLATE) {
                throw new FollowUpException(String.format(Label.FollowUp_Error_Bulk_Approve_Non_Template, new List<String>{ rec.Name }));
            }
            stampApproval(rec);
        }
        save(recs);
        return recs;
    }

    /** Saves case-manager edits. Editing an approved draft re-opens approval. */
    public static Follow_Up_Recommendation__c saveDraft(Id recommendationId, String subject, String message) {
        Follow_Up_Recommendation__c rec = loadForAction(new Set<Id>{ recommendationId })[0];
        requireStatus(rec, FollowUpConstants.OPEN_STATUSES);
        if (applyEdits(rec, subject, message)) {
            FollowUpDraftService.resetApprovalIfNeeded(rec);
            save(new List<Follow_Up_Recommendation__c>{ rec });
        }
        return rec;
    }

    public static Follow_Up_Recommendation__c reject(Id recommendationId, String reason) {
        if (String.isBlank(reason)) {
            throw new FollowUpException(Label.FollowUp_Error_Reason_Required);
        }
        Follow_Up_Recommendation__c rec = loadForAction(new Set<Id>{ recommendationId })[0];
        requireStatus(rec, FollowUpConstants.OPEN_STATUSES);
        rec.Status__c = FollowUpConstants.STATUS_REJECTED;
        rec.Rejection_Reason__c = reason.left(255);
        rec.Closed_Date__c = System.now();
        save(new List<Follow_Up_Recommendation__c>{ rec });
        return rec;
    }

    /**
     * Case-manager override: change priority and/or snooze the follow-up until a date.
     * Snoozing closes the recommendation (Overridden) and the rule engine suppresses the same follow-up
     * until the snooze date.
     */
    public static Follow_Up_Recommendation__c overrideRecommendation(
        Id recommendationId,
        String reason,
        Date snoozeUntil,
        String newPriority
    ) {
        FollowUpSecurity.requirePermission(FollowUpConstants.PERM_OVERRIDE, Label.FollowUp_Error_No_Override_Permission);
        if (String.isBlank(reason)) {
            throw new FollowUpException(Label.FollowUp_Error_Reason_Required);
        }
        Follow_Up_Recommendation__c rec = loadForAction(new Set<Id>{ recommendationId })[0];
        requireStatus(rec, FollowUpConstants.OPEN_STATUSES);
        if (String.isNotBlank(newPriority)) {
            if (
                !new Set<String>{ FollowUpConstants.PRIORITY_HIGH, FollowUpConstants.PRIORITY_MEDIUM, FollowUpConstants.PRIORITY_LOW }
                    .contains(newPriority)
            ) {
                throw new FollowUpException(String.format(Label.FollowUp_Error_Invalid_Status, new List<String>{ rec.Name, newPriority }));
            }
            rec.Priority__c = newPriority;
        }
        if (snoozeUntil != null) {
            if (snoozeUntil <= Date.today()) {
                throw new FollowUpException(Label.FollowUp_Error_Snooze_Date);
            }
            rec.Next_Follow_Up_Date__c = snoozeUntil;
            rec.Status__c = FollowUpConstants.STATUS_OVERRIDDEN;
            rec.Closed_Date__c = System.now();
        }
        rec.Case_Manager_Override__c = true;
        rec.Override_Reason__c = reason.left(255);
        save(new List<Follow_Up_Recommendation__c>{ rec });
        return rec;
    }

    /** Marks an open or sent recommendation complete (e.g. the case manager called the client). */
    public static Follow_Up_Recommendation__c complete(Id recommendationId) {
        Follow_Up_Recommendation__c rec = loadForAction(new Set<Id>{ recommendationId })[0];
        Set<String> allowed = new Set<String>(FollowUpConstants.OPEN_STATUSES);
        allowed.add(FollowUpConstants.STATUS_SENT);
        requireStatus(rec, allowed);
        // Completing an external message without sending it is only allowed once it was sent or it is internal.
        if (FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c) && rec.Status__c != FollowUpConstants.STATUS_SENT) {
            FollowUpSecurity.requirePermission(FollowUpConstants.PERM_OVERRIDE, Label.FollowUp_Error_No_Override_Permission);
        }
        rec.Status__c = FollowUpConstants.STATUS_COMPLETED;
        rec.Closed_Date__c = System.now();
        save(new List<Follow_Up_Recommendation__c>{ rec });
        return rec;
    }

    public static void save(List<Follow_Up_Recommendation__c> recs) {
        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : recs) {
            updates.add(writableCopy(rec));
        }
        Database.update(updates, true, AccessLevel.SYSTEM_MODE);
    }

    /** Only workflow fields are written back; relationship data loaded for display is dropped. */
    private static Follow_Up_Recommendation__c writableCopy(Follow_Up_Recommendation__c rec) {
        return new Follow_Up_Recommendation__c(
            Id = rec.Id,
            Status__c = rec.Status__c,
            Priority__c = rec.Priority__c,
            Draft_Subject__c = rec.Draft_Subject__c,
            Draft_Message__c = rec.Draft_Message__c,
            Draft_Source__c = rec.Draft_Source__c,
            AI_Rationale__c = rec.AI_Rationale__c,
            Approved_By__c = rec.Approved_By__c,
            Approved_Date__c = rec.Approved_Date__c,
            Rejection_Reason__c = rec.Rejection_Reason__c,
            Case_Manager_Override__c = rec.Case_Manager_Override__c,
            Override_Reason__c = rec.Override_Reason__c,
            Next_Follow_Up_Date__c = rec.Next_Follow_Up_Date__c,
            Closed_Date__c = rec.Closed_Date__c
        );
    }

    private static Boolean applyEdits(Follow_Up_Recommendation__c rec, String subject, String message) {
        Boolean changed = false;
        if (subject != null && subject != rec.Draft_Subject__c) {
            rec.Draft_Subject__c = subject.left(255);
            changed = true;
        }
        if (message != null && message != rec.Draft_Message__c) {
            rec.Draft_Message__c = message.left(10000);
            changed = true;
        }
        if (changed) {
            rec.Draft_Source__c = FollowUpConstants.DRAFT_MANUAL;
        }
        return changed;
    }

    private static void stampApproval(Follow_Up_Recommendation__c rec) {
        if (FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c) && String.isBlank(rec.Draft_Message__c)) {
            throw new FollowUpException(String.format(Label.FollowUp_Error_Empty_Draft, new List<String>{ rec.Name }));
        }
        rec.Status__c = FollowUpConstants.STATUS_APPROVED;
        rec.Approved_By__c = UserInfo.getUserId();
        rec.Approved_Date__c = System.now();
    }

    public static void requireStatus(Follow_Up_Recommendation__c rec, Set<String> allowed) {
        if (!allowed.contains(rec.Status__c)) {
            throw new FollowUpException(String.format(Label.FollowUp_Error_Invalid_Status, new List<String>{ rec.Name, rec.Status__c }));
        }
    }
}
