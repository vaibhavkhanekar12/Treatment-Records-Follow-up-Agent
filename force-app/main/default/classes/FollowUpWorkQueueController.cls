/**
 * Apex controller for the treatmentRecordsFollowUpConsole LWC (Case Manager Work Queue).
 * Thin adapter: all authorization and business rules live in the services, so the same rules apply to
 * the UI, the Agentforce actions and any future API.
 */
public with sharing class FollowUpWorkQueueController {
    private static final Integer MAX_ROWS = 500;

    public class QueueItem {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Id matterId;
        @AuraEnabled
        public String matterName;
        @AuraEnabled
        public String recommendationType;
        @AuraEnabled
        public String typeLabel;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String priority;
        @AuraEnabled
        public String audience;
        @AuraEnabled
        public String channel;
        @AuraEnabled
        public String reason;
        @AuraEnabled
        public Decimal gapDays;
        @AuraEnabled
        public Decimal recordsAgeDays;
        @AuraEnabled
        public Decimal priorFollowUps;
        @AuraEnabled
        public String providerName;
        @AuraEnabled
        public String recipientName;
        @AuraEnabled
        public String assignedToName;
        @AuraEnabled
        public String draftSource;
        @AuraEnabled
        public Date recommendedDate;
        @AuraEnabled
        public String responseClassification;
        @AuraEnabled
        public Boolean external;
    }

    public class Detail {
        @AuraEnabled
        public QueueItem item;
        @AuraEnabled
        public String draftSubject;
        @AuraEnabled
        public String draftMessage;
        @AuraEnabled
        public String rationale;
        @AuraEnabled
        public String approvedByName;
        @AuraEnabled
        public Datetime approvedDate;
        @AuraEnabled
        public Datetime sentDate;
        @AuraEnabled
        public String deliveryNote;
        @AuraEnabled
        public String responseText;
        @AuraEnabled
        public Date nextFollowUpDate;
        @AuraEnabled
        public String matterFacts;
        @AuraEnabled
        public String history;
    }

    public class Permissions {
        @AuraEnabled
        public Boolean canApprove;
        @AuraEnabled
        public Boolean canBulkApprove;
        @AuraEnabled
        public Boolean canSend;
        @AuraEnabled
        public Boolean canOverride;
    }

    public class Suggestion {
        @AuraEnabled
        public String category;
        @AuraEnabled
        public Decimal confidence;
    }

    @AuraEnabled
    public static Permissions getPermissions() {
        Permissions perms = new Permissions();
        perms.canApprove = FollowUpSecurity.hasPermission(FollowUpConstants.PERM_APPROVE);
        perms.canBulkApprove = perms.canApprove && FollowUpSecurity.hasPermission(FollowUpConstants.PERM_BULK_APPROVE);
        perms.canSend = FollowUpSecurity.hasPermission(FollowUpConstants.PERM_SEND);
        perms.canOverride = FollowUpSecurity.hasPermission(FollowUpConstants.PERM_OVERRIDE);
        return perms;
    }

    /**
     * @param statusFilter Open (default), Awaiting_Response, Closed, or a single Status__c value
     * @param onlyMine     restrict to recommendations assigned to the running user
     * @param matterId     restrict to one matter (record-page usage)
     */
    @AuraEnabled
    public static List<QueueItem> getQueue(String statusFilter, String priority, String recommendationType, Boolean onlyMine, Id matterId) {
        try {
            Map<String, Object> binds = new Map<String, Object>{ 'statuses' => statusesFor(statusFilter) };
            String query =
                'SELECT ' +
                FollowUpRecommendationService.RECOMMENDATION_FIELDS +
                ' FROM Follow_Up_Recommendation__c WHERE Status__c IN :statuses';
            if (String.isNotBlank(priority)) {
                query += ' AND Priority__c = :priority';
                binds.put('priority', priority);
            }
            if (String.isNotBlank(recommendationType)) {
                query += ' AND Recommendation_Type__c = :recommendationType';
                binds.put('recommendationType', recommendationType);
            }
            if (onlyMine == true) {
                query += ' AND Assigned_To__c = :userId';
                binds.put('userId', UserInfo.getUserId());
            }
            if (matterId != null) {
                query += ' AND Matter__c = :matterId';
                binds.put('matterId', matterId);
            }
            // Picklist ORDER BY follows the picklist definition order: High, Medium, Low.
            query += ' ORDER BY Priority__c ASC, Recommended_Date__c ASC NULLS LAST, Name ASC LIMIT ' + MAX_ROWS;
            List<QueueItem> items = new List<QueueItem>();
            for (
                Follow_Up_Recommendation__c rec : (List<Follow_Up_Recommendation__c>) Database.queryWithBinds(
                    query,
                    binds,
                    AccessLevel.USER_MODE
                )
            ) {
                items.add(toItem(rec));
            }
            return items;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Detail getDetail(Id recommendationId) {
        try {
            List<Follow_Up_Recommendation__c> recs = FollowUpRecommendationService.query(
                new Set<Id>{ recommendationId },
                AccessLevel.USER_MODE
            );
            if (recs.isEmpty()) {
                throw new FollowUpException(Label.FollowUp_Error_No_Access);
            }
            Follow_Up_Recommendation__c rec = recs[0];
            Detail detail = new Detail();
            detail.item = toItem(rec);
            detail.draftSubject = rec.Draft_Subject__c;
            detail.draftMessage = rec.Draft_Message__c;
            detail.rationale = rec.AI_Rationale__c;
            detail.approvedByName = rec.Approved_By__c == null ? null : rec.Approved_By__r.Name;
            detail.approvedDate = rec.Approved_Date__c;
            detail.sentDate = rec.Sent_Date__c;
            detail.deliveryNote = rec.Delivery_Note__c;
            detail.responseText = rec.Response_Text__c;
            detail.nextFollowUpDate = rec.Next_Follow_Up_Date__c;
            FollowUpSecurity.requireSourceDataAccess();
            FollowUpMatterContext ctx = FollowUpMatterSelector.loadContext(rec.Matter__c, Date.today());
            if (ctx != null) {
                detail.matterFacts = FollowUpFactsBuilder.matterFacts(ctx, Date.today());
                detail.history = FollowUpFactsBuilder.historyFacts(ctx.history, 15);
            }
            return detail;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void approve(Id recommendationId, String subject, String message) {
        try {
            FollowUpRecommendationService.approve(recommendationId, subject, message);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void bulkApprove(List<Id> recommendationIds) {
        try {
            FollowUpRecommendationService.bulkApprove(recommendationIds);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void saveDraft(Id recommendationId, String subject, String message) {
        try {
            FollowUpRecommendationService.saveDraft(recommendationId, subject, message);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void reject(Id recommendationId, String reason) {
        try {
            FollowUpRecommendationService.reject(recommendationId, reason);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void overrideRecommendation(Id recommendationId, String reason, Date snoozeUntil, String priority) {
        try {
            FollowUpRecommendationService.overrideRecommendation(recommendationId, reason, snoozeUntil, priority);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void complete(Id recommendationId) {
        try {
            FollowUpRecommendationService.complete(recommendationId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static FollowUpSendService.SendOutcome send(List<Id> recommendationIds) {
        try {
            return FollowUpSendService.send(recommendationIds);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Rebuilds the draft from current facts (and AI when configured). Never sends; re-opens approval. */
    @AuraEnabled
    public static void regenerateDraft(Id recommendationId) {
        try {
            Follow_Up_Recommendation__c rec = FollowUpRecommendationService.loadForAction(new Set<Id>{ recommendationId })[0];
            FollowUpRecommendationService.requireStatus(rec, FollowUpConstants.OPEN_STATUSES);
            FollowUpSecurity.requireSourceDataAccess();
            FollowUpDraftService.regenerate(new List<Follow_Up_Recommendation__c>{ rec }, true);
            FollowUpRecommendationService.save(new List<Follow_Up_Recommendation__c>{ rec });
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static FollowUpResponseService.ResponseResult logResponse(
        Id recommendationId,
        String responseText,
        String category,
        String source
    ) {
        try {
            FollowUpResponseService.ResponseInput input = new FollowUpResponseService.ResponseInput();
            input.recommendationId = recommendationId;
            input.responseText = responseText;
            input.category = category;
            input.source = String.isBlank(source) ? 'Phone' : source;
            return FollowUpResponseService.logResponses(new List<FollowUpResponseService.ResponseInput>{ input })[0];
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Suggestion suggestClassification(String responseText, String audience) {
        Suggestion suggestion = new Suggestion();
        FollowUpClassification classification = FollowUpResponseService.suggest(responseText, audience);
        suggestion.category = classification.category;
        suggestion.confidence = classification.confidence;
        return suggestion;
    }

    /** Runs the deterministic rules for one matter now (same engine as the nightly batch). */
    @AuraEnabled
    public static Integer evaluateMatter(Id matterId) {
        try {
            return FollowUpAgentSupport.evaluateForUser(new Set<Id>{ matterId }, 'MANUAL').created;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static Set<String> statusesFor(String statusFilter) {
        if (String.isBlank(statusFilter) || statusFilter == 'Open') {
            return FollowUpConstants.OPEN_STATUSES;
        }
        if (statusFilter == 'Awaiting_Response') {
            return new Set<String>{ FollowUpConstants.STATUS_SENT };
        }
        if (statusFilter == 'Closed') {
            return FollowUpConstants.CLOSED_STATUSES;
        }
        return new Set<String>{ statusFilter };
    }

    private static QueueItem toItem(Follow_Up_Recommendation__c rec) {
        QueueItem item = new QueueItem();
        item.id = rec.Id;
        item.name = rec.Name;
        item.matterId = rec.Matter__c;
        item.matterName = rec.Matter__r == null ? null : rec.Matter__r.Name;
        item.recommendationType = rec.Recommendation_Type__c;
        item.typeLabel = FollowUpEvaluationService.typeLabel(rec.Recommendation_Type__c);
        item.status = rec.Status__c;
        item.priority = rec.Priority__c;
        item.audience = rec.Audience__c;
        item.channel = rec.Channel__c;
        item.reason = rec.Reason__c;
        item.gapDays = rec.Gap_Days__c;
        item.recordsAgeDays = rec.Records_Age_Days__c;
        item.priorFollowUps = rec.Prior_Follow_Up_Count__c;
        item.providerName = rec.Medical_Provider__c == null ? null : rec.Medical_Provider__r.Name;
        item.recipientName = rec.Recipient_Contact__c == null ? null : rec.Recipient_Contact__r.Name;
        item.assignedToName = rec.Assigned_To__c == null ? null : rec.Assigned_To__r.Name;
        item.draftSource = rec.Draft_Source__c;
        item.recommendedDate = rec.Recommended_Date__c;
        item.responseClassification = rec.Response_Classification__c;
        item.external = FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c);
        return item;
    }

    private static AuraHandledException auraError(Exception e) {
        String message = e instanceof FollowUpException ? e.getMessage() : 'Follow-up action failed: ' + e.getMessage();
        if (e instanceof DmlException) {
            message = ((DmlException) e).getDmlMessage(0);
        }
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
