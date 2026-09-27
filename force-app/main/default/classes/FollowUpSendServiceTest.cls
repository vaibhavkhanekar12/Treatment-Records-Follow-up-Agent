/**
 * Server-side send enforcement and channel behaviour.
 */
@IsTest
private class FollowUpSendServiceTest {
    @TestSetup
    static void setup() {
        User caseManager;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            caseManager = FollowUpTestDataFactory.createUser('fusend', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
            FollowUpTestDataFactory.createUser('fusendsu', new List<String>{ FollowUpTestDataFactory.PS_SUPERVISOR });
        }
        Contact client = FollowUpTestDataFactory.client(caseManager.Id, 'jamie@client.example', '5550001');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Metro PT', 'records@metropt.example', '5550199');
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('M-3001', client.Id, caseManager.Id, Date.today().addDays(-90));
        insert matter;
        Follow_Up_Recommendation__c email = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Client', 'Email', client.Id, null);
        email.Dedupe_Key__c = 'SEND|EMAIL';
        Follow_Up_Recommendation__c sms = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Client', 'SMS', client.Id, null);
        sms.Dedupe_Key__c = 'SEND|SMS';
        Follow_Up_Recommendation__c fax = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Provider', 'Fax', null, provider.Id);
        fax.Dedupe_Key__c = 'SEND|FAX';
        Follow_Up_Recommendation__c internal = FollowUpTestDataFactory.pendingRecommendation(matter.Id, 'Internal', 'Task', null, null);
        internal.Recommendation_Type__c = FollowUpConstants.TYPE_MISSING_BILLS;
        internal.Dedupe_Key__c = 'SEND|INTERNAL';
        for (Follow_Up_Recommendation__c rec : new List<Follow_Up_Recommendation__c>{ email, sms, fax, internal }) {
            rec.Assigned_To__c = caseManager.Id;
        }
        insert new List<Follow_Up_Recommendation__c>{ email, sms, fax, internal };
    }

    private static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Email LIKE '%@followup.example.com' LIMIT 1];
    }

    private static Follow_Up_Recommendation__c rec(String key) {
        return [
            SELECT Id, Name, Status__c, Sent_Date__c, Sent_By__c, Task_Id__c, Delivery_Note__c, Approved_By__c
            FROM Follow_Up_Recommendation__c
            WHERE Dedupe_Key__c = :key
        ];
    }

    private static void approveAs(User approver, String key) {
        System.runAs(approver) {
            FollowUpRecommendationService.approve(rec(key).Id, null, null);
        }
    }

    @IsTest
    static void unapprovedExternalMessageCannotBeSent() {
        Exception caught;
        Test.startTest();
        System.runAs(user('fusend')) {
            try {
                FollowUpSendService.send(new List<Id>{ rec('SEND|EMAIL').Id });
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'Blocked server-side');
        Assert.isTrue(caught.getMessage().contains('has not been approved'), caught.getMessage());
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, rec('SEND|EMAIL').Status__c, 'Nothing sent');
        Assert.areEqual(0, [SELECT COUNT() FROM Task], 'No activity logged');
    }

    @IsTest
    static void validationRuleBlocksDirectSentWithoutApproval() {
        Follow_Up_Recommendation__c target = rec('SEND|EMAIL');
        target.Status__c = FollowUpConstants.STATUS_SENT;
        DmlException caught;
        Test.startTest();
        try {
            update target; // even as an administrator / integration
        } catch (DmlException e) {
            caught = e;
        }
        Test.stopTest();
        Assert.isNotNull(caught, 'Validation rule is the last line of defence');
    }

    @IsTest
    static void approvedEmailIsSentAndLogged() {
        User caseManager = user('fusend');
        approveAs(caseManager, 'SEND|EMAIL');
        StubChannel stub = new StubChannel(true);
        FollowUpSendService.channelOverrides.put(FollowUpConstants.CHANNEL_EMAIL, stub);
        FollowUpSendService.SendOutcome outcome;

        Test.startTest();
        System.runAs(caseManager) {
            outcome = FollowUpSendService.send(new List<Id>{ rec('SEND|EMAIL').Id });
        }
        Test.stopTest();

        Follow_Up_Recommendation__c sent = rec('SEND|EMAIL');
        Assert.areEqual(1, outcome.sent, 'Sent');
        Assert.areEqual(FollowUpConstants.STATUS_SENT, sent.Status__c, 'Status Sent');
        Assert.areEqual(caseManager.Id, sent.Sent_By__c, 'Sender audited');
        Assert.isNotNull(sent.Sent_Date__c, 'Sent date stamped');
        Task log = [SELECT Subject, Status, WhoId FROM Task LIMIT 1];
        Assert.isTrue(log.Subject.startsWith(FollowUpMatterSelector.OUTBOUND_TASK_PREFIX), 'Outbound activity logged');
        Assert.areEqual('Completed', log.Status, 'Log is a completed activity');
    }

    @IsTest
    static void smsWithoutIntegrationCreatesManualDeliveryTaskThatCompletes() {
        User caseManager = user('fusend');
        approveAs(caseManager, 'SEND|SMS');

        Test.startTest();
        System.runAs(caseManager) {
            FollowUpSendService.send(new List<Id>{ rec('SEND|SMS').Id });
        }
        Follow_Up_Recommendation__c queued = rec('SEND|SMS');
        Task task = [SELECT Id, Subject, Description, OwnerId FROM Task WHERE Id = :queued.Task_Id__c];
        Assert.isTrue(task.Description.contains('5550001'), 'Task carries the client mobile number from the Contact record');
        Assert.areEqual(caseManager.Id, task.OwnerId, 'Assigned to the case manager');
        Assert.areEqual(FollowUpConstants.STATUS_SENT, queued.Status__c, 'Queued for manual delivery');

        task.Status = 'Completed';
        update task;
        Test.stopTest();

        Assert.areEqual(FollowUpConstants.STATUS_COMPLETED, rec('SEND|SMS').Status__c, 'Flow completes it when the task is done');
    }

    @IsTest
    static void registeredIntegrationChannelIsUsed() {
        User caseManager = user('fusend');
        approveAs(caseManager, 'SEND|FAX');
        StubChannel stub = new StubChannel(true);
        FollowUpSendService.channelOverrides.put(FollowUpConstants.CHANNEL_FAX, stub);

        Test.startTest();
        System.runAs(caseManager) {
            FollowUpSendService.send(new List<Id>{ rec('SEND|FAX').Id });
        }
        Test.stopTest();

        Assert.areEqual(1, stub.delivered, 'Fax integration invoked');
        Assert.areEqual(FollowUpConstants.STATUS_SENT, rec('SEND|FAX').Status__c, 'Sent');
    }

    @IsTest
    static void internalRecommendationSendsWithoutApproval() {
        User caseManager = user('fusend');
        Test.startTest();
        System.runAs(caseManager) {
            FollowUpSendService.send(new List<Id>{ rec('SEND|INTERNAL').Id });
        }
        Test.stopTest();

        Follow_Up_Recommendation__c sent = rec('SEND|INTERNAL');
        Assert.areEqual(FollowUpConstants.STATUS_SENT, sent.Status__c, 'Internal tasks need no approval');
        Assert.isNotNull(sent.Task_Id__c, 'Task created');
    }

    @IsTest
    static void deliveryFailureIsRetryable() {
        User caseManager = user('fusend');
        approveAs(caseManager, 'SEND|EMAIL');
        FollowUpSendService.channelOverrides.put(FollowUpConstants.CHANNEL_EMAIL, new StubChannel(false));
        FollowUpSendService.SendOutcome outcome;

        Test.startTest();
        System.runAs(caseManager) {
            outcome = FollowUpSendService.send(new List<Id>{ rec('SEND|EMAIL').Id });
            Assert.areEqual(FollowUpConstants.STATUS_SEND_FAILED, rec('SEND|EMAIL').Status__c, 'Failure recorded');
            FollowUpSendService.channelOverrides.put(FollowUpConstants.CHANNEL_EMAIL, new StubChannel(true));
            FollowUpSendService.send(new List<Id>{ rec('SEND|EMAIL').Id });
        }
        Test.stopTest();

        Assert.areEqual(1, outcome.failed, 'Failure reported to the user');
        Assert.areEqual(FollowUpConstants.STATUS_SENT, rec('SEND|EMAIL').Status__c, 'Retry succeeds without re-approval');
    }

    @IsTest
    static void userWithoutSendPermissionIsBlocked() {
        approveAs(user('fusend'), 'SEND|EMAIL');
        Exception caught;
        Test.startTest();
        System.runAs(user('fusendsu')) {
            try {
                FollowUpSendService.send(new List<Id>{ rec('SEND|EMAIL').Id });
            } catch (FollowUpException e) {
                caught = e;
            }
        }
        Test.stopTest();
        Assert.areEqual(Label.FollowUp_Error_No_Send_Permission, caught == null ? null : caught.getMessage(), 'Blocked');
    }

    @IsTest
    static void emailChannelValidatesRecipients() {
        Set<Id> ids = new Set<Id>{ rec('SEND|EMAIL').Id };
        Follow_Up_Recommendation__c target = FollowUpRecommendationService.query(ids, AccessLevel.SYSTEM_MODE)[0];
        Follow_Up_Recommendation__c optedOut = FollowUpRecommendationService.query(ids, AccessLevel.SYSTEM_MODE)[0];
        optedOut.Recipient_Contact__r.HasOptedOutOfEmail = true;
        Follow_Up_Recommendation__c noAddress = FollowUpRecommendationService.query(ids, AccessLevel.SYSTEM_MODE)[0];
        noAddress.Recipient_Contact__r.Email = null;

        Test.startTest();
        List<FollowUpDeliveryResult> optedOutResult = new FollowUpEmailChannel().deliver(new List<Follow_Up_Recommendation__c>{ optedOut });
        List<FollowUpDeliveryResult> noAddressResult = new FollowUpEmailChannel()
            .deliver(new List<Follow_Up_Recommendation__c>{ noAddress });
        List<FollowUpDeliveryResult> realResult = new FollowUpEmailChannel().deliver(new List<Follow_Up_Recommendation__c>{ target });
        Test.stopTest();

        Assert.isFalse(optedOutResult[0].success, 'Email opt-out honoured');
        Assert.areEqual(Label.FollowUp_Error_Email_Opt_Out, optedOutResult[0].note, 'Reason given');
        Assert.isFalse(noAddressResult[0].success, 'Missing address rejected');
        Assert.areEqual(1, realResult.size(), 'Real send attempted; outcome depends on org deliverability settings');
    }

    private class StubChannel implements IFollowUpChannel {
        private Boolean succeed;
        Integer delivered = 0;
        StubChannel(Boolean succeed) {
            this.succeed = succeed;
        }
        public List<FollowUpDeliveryResult> deliver(List<Follow_Up_Recommendation__c> recommendations) {
            List<FollowUpDeliveryResult> results = new List<FollowUpDeliveryResult>();
            for (Follow_Up_Recommendation__c rec : recommendations) {
                delivered++;
                results.add(new FollowUpDeliveryResult(rec.Id, succeed, succeed ? 'Delivered (stub)' : 'Gateway unavailable (stub)'));
            }
            return results;
        }
    }
}
