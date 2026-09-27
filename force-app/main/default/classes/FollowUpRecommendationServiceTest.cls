/**
 * Approval workflow: approve, edit-after-approval, bulk approve, reject, override/snooze, complete,
 * permission and record-access enforcement. Runs as real users with the solution's permission sets.
 */
@IsTest
private class FollowUpRecommendationServiceTest {
    private static final Date TODAY = Date.today();

    @TestSetup
    static void setup() {
        User caseManager;
        User supervisor;
        User otherCaseManager;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            caseManager = FollowUpTestDataFactory.createUser('fucm', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
            supervisor = FollowUpTestDataFactory.createUser('fusup', new List<String>{ FollowUpTestDataFactory.PS_SUPERVISOR });
            otherCaseManager = FollowUpTestDataFactory.createUser('fucm2', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
        }
        Contact client = FollowUpTestDataFactory.client(caseManager.Id, 'jamie@client.example', '5550001');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Metro PT', 'records@metropt.example', '5550199');
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('M-2001', client.Id, caseManager.Id, TODAY.addDays(-90));
        insert matter;
        Follow_Up_Recommendation__c template = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Client', 'Email', client.Id, null);
        template.Dedupe_Key__c = 'TEST|TEMPLATE';
        Follow_Up_Recommendation__c ai = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Provider', 'Email', null, provider.Id);
        ai.Draft_Source__c = FollowUpConstants.DRAFT_AI;
        ai.Dedupe_Key__c = 'TEST|AI';
        Follow_Up_Recommendation__c internal = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Internal', 'Task', null, null);
        internal.Recommendation_Type__c = FollowUpConstants.TYPE_STALLED_MATTER;
        internal.Draft_Message__c = null;
        internal.Draft_Source__c = null;
        internal.Dedupe_Key__c = 'TEST|INTERNAL';
        insert new List<Follow_Up_Recommendation__c>{ template, ai, internal };
    }

    private static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Email LIKE '%@followup.example.com' LIMIT 1];
    }

    private static Follow_Up_Recommendation__c rec(String key) {
        return [
            SELECT
                Id,
                Name,
                Status__c,
                Approved_By__c,
                Approved_Date__c,
                Draft_Message__c,
                Draft_Source__c,
                Priority__c,
                Rejection_Reason__c,
                Closed_Date__c,
                Next_Follow_Up_Date__c,
                Case_Manager_Override__c,
                Override_Reason__c,
                Active_Key__c
            FROM Follow_Up_Recommendation__c
            WHERE Dedupe_Key__c = :key
        ];
    }

    private static String errorOf(Exception e) {
        return e == null ? null : e.getMessage();
    }

    @IsTest
    static void caseManagerApprovesWithEdits() {
        User caseManager = user('fucm');
        Id recId = rec('TEST|TEMPLATE').Id;

        Test.startTest();
        System.runAs(caseManager) {
            FollowUpRecommendationService.approve(recId, 'Checking in', 'Edited neutral message.');
        }
        Test.stopTest();

        Follow_Up_Recommendation__c approved = rec('TEST|TEMPLATE');
        Assert.areEqual(FollowUpConstants.STATUS_APPROVED, approved.Status__c, 'Approved');
        Assert.areEqual(caseManager.Id, approved.Approved_By__c, 'Approval stamped with the approver');
        Assert.isNotNull(approved.Approved_Date__c, 'Approval date stamped');
        Assert.areEqual('Edited neutral message.', approved.Draft_Message__c, 'Edit saved');
        Assert.areEqual(FollowUpConstants.DRAFT_MANUAL, approved.Draft_Source__c, 'Edited drafts are marked manual');
        Assert.isNotNull(approved.Active_Key__c, 'Approved items are still open');
    }

    @IsTest
    static void editingAnApprovedDraftReopensApproval() {
        User caseManager = user('fucm');
        Id recId = rec('TEST|TEMPLATE').Id;

        Test.startTest();
        System.runAs(caseManager) {
            FollowUpRecommendationService.approve(recId, null, null);
            FollowUpRecommendationService.saveDraft(recId, null, 'Changed after approval.');
        }
        Test.stopTest();

        Follow_Up_Recommendation__c reopened = rec('TEST|TEMPLATE');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, reopened.Status__c, 'Approval re-opened');
        Assert.isNull(reopened.Approved_By__c, 'Approval stamp cleared');
    }

    @IsTest
    static void userWithoutApprovePermissionIsBlocked() {
        Id recId = rec('TEST|TEMPLATE').Id;
        Exception caught;

        Test.startTest();
        System.runAs(user('fusup')) {
            try {
                FollowUpRecommendationService.approve(recId, null, null);
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.areEqual(Label.FollowUp_Error_No_Approve_Permission, errorOf(caught), 'Server-side permission enforcement');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, rec('TEST|TEMPLATE').Status__c, 'Unchanged');
    }

    @IsTest
    static void caseManagerWithoutMatterAccessIsBlocked() {
        Id recId = rec('TEST|TEMPLATE').Id;
        Exception caught;

        Test.startTest();
        System.runAs(user('fucm2')) {
            try {
                FollowUpRecommendationService.approve(recId, null, null);
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.areEqual(Label.FollowUp_Error_No_Access, errorOf(caught), 'Matter sharing is inherited by recommendations');
    }

    @IsTest
    static void bulkApproveOnlyAllowsTemplateDrafts() {
        User caseManager = user('fucm');
        Id templateId = rec('TEST|TEMPLATE').Id;
        Id aiId = rec('TEST|AI').Id;
        Exception caught;

        Test.startTest();
        System.runAs(caseManager) {
            try {
                FollowUpRecommendationService.bulkApprove(new List<Id>{ templateId, aiId });
            } catch (FollowUpException e) {
                caught = e;
            }
            FollowUpRecommendationService.bulkApprove(new List<Id>{ templateId });
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'AI draft in the selection blocks the bulk approval');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, rec('TEST|AI').Status__c, 'AI draft needs individual review');
        Assert.areEqual(FollowUpConstants.STATUS_APPROVED, rec('TEST|TEMPLATE').Status__c, 'Template bulk-approved');
    }

    @IsTest
    static void rejectRequiresReasonAndClosesRecommendation() {
        User caseManager = user('fucm');
        Id recId = rec('TEST|TEMPLATE').Id;
        Exception caught;

        Test.startTest();
        System.runAs(caseManager) {
            try {
                FollowUpRecommendationService.reject(recId, ' ');
            } catch (FollowUpException e) {
                caught = e;
            }
            FollowUpRecommendationService.reject(recId, 'Spoke to client yesterday.');
        }
        Test.stopTest();

        Assert.areEqual(Label.FollowUp_Error_Reason_Required, errorOf(caught), 'Reason is mandatory');
        Follow_Up_Recommendation__c rejected = rec('TEST|TEMPLATE');
        Assert.areEqual(FollowUpConstants.STATUS_REJECTED, rejected.Status__c, 'Rejected');
        Assert.areEqual('Spoke to client yesterday.', rejected.Rejection_Reason__c, 'Reason stored');
        Assert.isNotNull(rejected.Closed_Date__c, 'Closed date stamped (drives cadence suppression)');
        Assert.isNull(rejected.Active_Key__c, 'Released for future evaluations');
    }

    @IsTest
    static void overrideSnoozesAndChangesPriority() {
        User caseManager = user('fucm');
        Id templateId = rec('TEST|TEMPLATE').Id;
        Id aiId = rec('TEST|AI').Id;
        Exception caught;

        Test.startTest();
        System.runAs(caseManager) {
            FollowUpRecommendationService.overrideRecommendation(aiId, 'Provider promised records Friday', null, 'High');
            FollowUpRecommendationService.overrideRecommendation(templateId, 'Client on vacation', TODAY.addDays(14), null);
            try {
                FollowUpRecommendationService.overrideRecommendation(aiId, 'Past date', TODAY, null);
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Follow_Up_Recommendation__c reprioritised = rec('TEST|AI');
        Assert.areEqual('High', reprioritised.Priority__c, 'Priority overridden');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, reprioritised.Status__c, 'Priority change keeps it open');
        Assert.isTrue(reprioritised.Case_Manager_Override__c, 'Override audited');
        Follow_Up_Recommendation__c snoozed = rec('TEST|TEMPLATE');
        Assert.areEqual(FollowUpConstants.STATUS_OVERRIDDEN, snoozed.Status__c, 'Snoozed items close');
        Assert.areEqual(TODAY.addDays(14), snoozed.Next_Follow_Up_Date__c, 'Snooze date stored');
        Assert.areEqual(Label.FollowUp_Error_Snooze_Date, errorOf(caught), 'Snooze must be in the future');
    }

    @IsTest
    static void supervisorCanOverrideButNotApprove() {
        // Supervisor has override permission but no matter access here -> access error after the permission check.
        Id recId = rec('TEST|AI').Id;
        Exception caught;
        Test.startTest();
        System.runAs(user('fusup')) {
            try {
                FollowUpRecommendationService.overrideRecommendation(recId, 'Reason', null, 'Low');
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();
        Assert.areEqual(Label.FollowUp_Error_No_Access, errorOf(caught), 'Permission alone does not grant record access');
    }

    @IsTest
    static void completeInternalRecommendation() {
        User caseManager = user('fucm');
        Id recId = rec('TEST|INTERNAL').Id;

        Test.startTest();
        System.runAs(caseManager) {
            FollowUpRecommendationService.complete(recId);
        }
        Test.stopTest();

        Assert.areEqual(FollowUpConstants.STATUS_COMPLETED, rec('TEST|INTERNAL').Status__c, 'Completed');
    }

    @IsTest
    static void approvingEmptyExternalDraftIsBlocked() {
        Follow_Up_Recommendation__c empty = rec('TEST|TEMPLATE');
        empty.Draft_Message__c = null;
        update empty;
        Exception caught;

        Test.startTest();
        System.runAs(user('fucm')) {
            try {
                FollowUpRecommendationService.approve(empty.Id, null, null);
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'Nothing to approve');
        Assert.isTrue(caught.getMessage().contains(empty.Name), 'Message names the record');
    }

    @IsTest
    static void cannotApproveClosedRecommendation() {
        Follow_Up_Recommendation__c closed = rec('TEST|TEMPLATE');
        closed.Status__c = FollowUpConstants.STATUS_REJECTED;
        closed.Rejection_Reason__c = 'Not needed';
        update closed;
        Exception caught;

        Test.startTest();
        System.runAs(user('fucm')) {
            try {
                FollowUpRecommendationService.approve(closed.Id, null, null);
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'Status transition validated');
    }
}
