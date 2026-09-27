/**
 * Work-queue controller: filtering, detail facts, permissions, error mapping.
 */
@IsTest
private class FollowUpWorkQueueControllerTest {
    @TestSetup
    static void setup() {
        User caseManager;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            caseManager = FollowUpTestDataFactory.createUser('fuqueue', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
        }
        Contact client = FollowUpTestDataFactory.client(caseManager.Id, 'jamie@client.example', '5550001');
        insert client;
        Matter__c matter = FollowUpTestDataFactory.matter('M-6001', client.Id, caseManager.Id, Date.today().addDays(-60));
        insert matter;
        Follow_Up_Recommendation__c high = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Client', 'Email', client.Id, null);
        high.Priority__c = 'High';
        high.Assigned_To__c = caseManager.Id;
        high.Dedupe_Key__c = 'Q|HIGH';
        Follow_Up_Recommendation__c low = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Client', 'Email', client.Id, null);
        low.Priority__c = 'Low';
        low.Recommendation_Type__c = FollowUpConstants.TYPE_CLIENT_STATUS_UPDATE;
        low.Dedupe_Key__c = 'Q|LOW';
        insert new List<Follow_Up_Recommendation__c>{ high, low };
    }

    private static User caseManager() {
        return [SELECT Id FROM User WHERE Alias = 'fuqueue' AND Email LIKE '%@followup.example.com' LIMIT 1];
    }

    @IsTest
    static void queueIsFilteredAndPrioritised() {
        FollowUpTestDataFactory.useDefaultConfig();
        List<FollowUpWorkQueueController.QueueItem> open;
        List<FollowUpWorkQueueController.QueueItem> mine;
        List<FollowUpWorkQueueController.QueueItem> updates;
        List<FollowUpWorkQueueController.QueueItem> closed;
        FollowUpWorkQueueController.Permissions perms;

        Test.startTest();
        System.runAs(caseManager()) {
            open = FollowUpWorkQueueController.getQueue('Open', null, null, false, null);
            mine = FollowUpWorkQueueController.getQueue('Open', null, null, true, null);
            updates = FollowUpWorkQueueController.getQueue('Open', null, FollowUpConstants.TYPE_CLIENT_STATUS_UPDATE, false, null);
            closed = FollowUpWorkQueueController.getQueue('Closed', null, null, false, null);
            perms = FollowUpWorkQueueController.getPermissions();
        }
        Test.stopTest();

        Assert.areEqual(2, open.size(), 'Both open');
        Assert.areEqual('High', open[0].priority, 'High priority first');
        Assert.areEqual(1, mine.size(), 'Only assigned to me');
        Assert.areEqual(1, updates.size(), 'Type filter');
        Assert.areEqual(0, closed.size(), 'None closed');
        Assert.isTrue(open[0].external, 'Client items flagged external');
        Assert.isTrue(perms.canApprove && perms.canSend && perms.canBulkApprove && perms.canOverride, 'Case manager permissions');
    }

    @IsTest
    static void detailIncludesFactsAndHistory() {
        FollowUpTestDataFactory.useDefaultConfig();
        Id recId = [SELECT Id FROM Follow_Up_Recommendation__c WHERE Dedupe_Key__c = 'Q|HIGH'].Id;
        FollowUpWorkQueueController.Detail detail;

        Test.startTest();
        System.runAs(caseManager()) {
            detail = FollowUpWorkQueueController.getDetail(recId);
        }
        Test.stopTest();

        Assert.areEqual('Hello, this is a neutral administrative check-in.', detail.draftMessage, 'Draft');
        Assert.isTrue(detail.matterFacts.contains('Matter: M-6001'), 'Matter facts');
        Assert.isTrue(detail.history.contains('Client_Check_In'), 'History');
    }

    @IsTest
    static void approveSendAndLogThroughController() {
        FollowUpTestDataFactory.useDefaultConfig();
        Id recId = [SELECT Id FROM Follow_Up_Recommendation__c WHERE Dedupe_Key__c = 'Q|HIGH'].Id;
        FollowUpSendService.SendOutcome outcome;
        FollowUpResponseService.ResponseResult logged;
        FollowUpWorkQueueController.Suggestion suggestion;

        Test.startTest();
        System.runAs(caseManager()) {
            FollowUpWorkQueueController.saveDraft(recId, 'Subject', 'Edited');
            FollowUpWorkQueueController.approve(recId, null, null);
            outcome = FollowUpWorkQueueController.send(new List<Id>{ recId });
            suggestion = FollowUpWorkQueueController.suggestClassification('I am still going to therapy', 'Client');
            logged = FollowUpWorkQueueController.logResponse(recId, 'I am still going to therapy', suggestion.category, 'Phone');
        }
        Test.stopTest();

        Assert.areEqual(1, outcome.sent + outcome.failed, 'Send attempted through the real email channel');
        Assert.areEqual('Treatment_Continuing', suggestion.category, 'Keyword suggestion for the person to confirm');
        Assert.areEqual('Treatment_Continuing', logged.category, 'Logged');
    }

    @IsTest
    static void errorsAreReturnedAsAuraHandledExceptions() {
        FollowUpTestDataFactory.useDefaultConfig();
        Id recId = [SELECT Id FROM Follow_Up_Recommendation__c WHERE Dedupe_Key__c = 'Q|HIGH'].Id;
        AuraHandledException caught;

        Test.startTest();
        System.runAs(caseManager()) {
            try {
                FollowUpWorkQueueController.send(new List<Id>{ recId });
            } catch (AuraHandledException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'Unapproved send rejected');
        Assert.isTrue(caught.getMessage().contains('has not been approved'), caught.getMessage());
    }

    @IsTest
    static void rejectOverrideCompleteRegenerateAndEvaluate() {
        FollowUpTestDataFactory.useDefaultConfig();
        Id highId = [SELECT Id FROM Follow_Up_Recommendation__c WHERE Dedupe_Key__c = 'Q|HIGH'].Id;
        Id lowId = [SELECT Id FROM Follow_Up_Recommendation__c WHERE Dedupe_Key__c = 'Q|LOW'].Id;
        Id matterId = [SELECT Id FROM Matter__c WHERE Name = 'M-6001'].Id;
        Integer created;

        Test.startTest();
        System.runAs(caseManager()) {
            FollowUpWorkQueueController.regenerateDraft(lowId);
            FollowUpWorkQueueController.bulkApprove(new List<Id>{ lowId });
            FollowUpWorkQueueController.overrideRecommendation(highId, 'Client travelling', Date.today().addDays(10), null);
            created = FollowUpWorkQueueController.evaluateMatter(matterId);
        }
        Test.stopTest();

        Follow_Up_Recommendation__c low = [SELECT Status__c, Draft_Message__c FROM Follow_Up_Recommendation__c WHERE Id = :lowId];
        Assert.areEqual(FollowUpConstants.STATUS_APPROVED, low.Status__c, 'Regenerated template draft bulk-approved');
        Assert.isTrue(low.Draft_Message__c.contains('monthly update'), 'Status update template');
        Assert.areEqual(
            FollowUpConstants.STATUS_OVERRIDDEN,
            [SELECT Status__c FROM Follow_Up_Recommendation__c WHERE Id = :highId].Status__c,
            'Snoozed'
        );
        Assert.isNotNull(created, 'Evaluation ran');
    }
}
