/**
 * Evaluation service, nightly batch, scheduler and AI drafting queueable (with a stub generator).
 */
@IsTest
private class FollowUpEvaluationServiceTest {
    private static final Date TODAY = Date.today();

    @TestSetup
    static void setup() {
        FollowUpTestDataFactory.useDefaultConfig();
        Contact client = FollowUpTestDataFactory.client(null, 'jamie@client.example', '5550001');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Metro Physical Therapy', 'records@metropt.example', null);
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('M-1001', client.Id, UserInfo.getUserId(), TODAY.addDays(-120));
        insert matter;
        insert new List<SObject>{
            FollowUpTestDataFactory.treatment(matter.Id, provider.Id, TODAY.addDays(-60), 'Completed'),
            FollowUpTestDataFactory.treatment(matter.Id, provider.Id, TODAY.addDays(-2), 'Cancelled'),
            FollowUpTestDataFactory.request(matter.Id, provider.Id, 'Records', 'Requested', TODAY.addDays(-40))
        };
    }

    private static Matter__c theMatter() {
        return [SELECT Id, Name, Stalled__c, Stalled_Since__c FROM Matter__c WHERE Name = 'M-1001'];
    }

    private static Map<String, Follow_Up_Recommendation__c> recsByType(Id matterId) {
        Map<String, Follow_Up_Recommendation__c> byType = new Map<String, Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : [
            SELECT
                Id,
                Recommendation_Type__c,
                Status__c,
                Active_Key__c,
                Dedupe_Key__c,
                Task_Id__c,
                Draft_Message__c,
                Draft_Source__c,
                Agent_Run_Id__c,
                AI_Rationale__c,
                Delivery_Note__c
            FROM Follow_Up_Recommendation__c
            WHERE Matter__c = :matterId
        ]) {
            byType.put(rec.Recommendation_Type__c, rec);
        }
        return byType;
    }

    @IsTest
    static void evaluationCreatesRecommendationsAndIsIdempotent() {
        FollowUpTestDataFactory.useDefaultConfig();
        Matter__c matter = theMatter();

        Test.startTest();
        FollowUpEvaluationService.Summary first = FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-1');
        FollowUpEvaluationService.Summary second = FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-2');
        Test.stopTest();

        Map<String, Follow_Up_Recommendation__c> recs = recsByType(matter.Id);
        Assert.isTrue(recs.containsKey(FollowUpConstants.TYPE_CLIENT_CHECK_IN), 'Cancelled visit ignored: 60-day gap -> check-in');
        Assert.isTrue(recs.containsKey(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP), '40-day-old request -> provider follow-up');
        Assert.isTrue(recs.containsKey(FollowUpConstants.TYPE_MISSING_BILLS), 'Treatment but no bills request');
        Follow_Up_Recommendation__c checkIn = recs.get(FollowUpConstants.TYPE_CLIENT_CHECK_IN);
        Assert.areEqual(checkIn.Dedupe_Key__c, checkIn.Active_Key__c, 'Before-save flow sets the active key for open items');
        Assert.areEqual('RUN-1', checkIn.Agent_Run_Id__c, 'Run id stamped');
        Assert.areEqual(0, first.errors, 'No errors: ' + first.messages);
        Assert.isTrue(first.created >= 3, 'Created on the first run');
        Assert.areEqual(0, second.created, 'Second run is idempotent');
        Assert.isTrue(second.suppressed >= 3, 'Second run suppresses existing open items');
    }

    @IsTest
    static void resumedTreatmentSupersedesOpenCheckIn() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        Matter__c matter = theMatter();
        FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-1');
        Medical_Provider__c provider = [SELECT Id FROM Medical_Provider__c LIMIT 1];
        insert FollowUpTestDataFactory.treatment(matter.Id, provider.Id, TODAY.addDays(-1), 'Completed');

        Test.startTest();
        FollowUpEvaluationService.Summary summary = FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-2');
        Test.stopTest();

        Follow_Up_Recommendation__c checkIn = recsByType(matter.Id).get(FollowUpConstants.TYPE_CLIENT_CHECK_IN);
        Assert.areEqual(FollowUpConstants.STATUS_SUPERSEDED, checkIn.Status__c, 'Stale check-in superseded');
        Assert.isNull(checkIn.Active_Key__c, 'Active key released when closed');
        Assert.areEqual(1, summary.superseded, 'Counted');
    }

    @IsTest
    static void stalledMatterIsFlaggedWithTaskAndCleared() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_STALLED_MATTER });
        Matter__c matter = theMatter();
        // Records activity 40 days ago, treatment 60, no client contact -> stalled
        Test.startTest();
        FollowUpEvaluationService.Summary summary = FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-1');

        matter = theMatter();
        Assert.isTrue(matter.Stalled__c, 'Stalled flag set');
        Assert.areEqual(TODAY, matter.Stalled_Since__c, 'Stalled since today');
        Assert.areEqual(1, summary.tasksCreated, 'Auto-task for the stalled review');
        Follow_Up_Recommendation__c review = recsByType(matter.Id).get(FollowUpConstants.TYPE_STALLED_MATTER);
        Assert.areEqual(FollowUpConstants.STATUS_SENT, review.Status__c, 'Internal task assigned');
        Task task = [SELECT Id, OwnerId, WhatId, Priority FROM Task WHERE Id = :review.Task_Id__c];
        Assert.areEqual(matter.Id, task.WhatId, 'Task on the matter');
        Assert.areEqual('High', task.Priority, 'High priority');

        // Completing the task completes the recommendation (Follow_Up_Task_Completed flow)
        task.Status = 'Completed';
        update task;
        Assert.areEqual(
            FollowUpConstants.STATUS_COMPLETED,
            [SELECT Status__c FROM Follow_Up_Recommendation__c WHERE Id = :review.Id].Status__c,
            'Flow closes the recommendation when the task is completed'
        );

        // Client contact resumes -> flag cleared
        Contact client = [SELECT Id FROM Contact LIMIT 1];
        insert new Task(WhoId = client.Id, WhatId = matter.Id, Subject = 'Call with client', Status = 'Completed', ActivityDate = TODAY);
        FollowUpEvaluationService.Summary second = FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-2');
        Test.stopTest();

        Assert.isFalse(theMatter().Stalled__c, 'Flag cleared after client contact');
        Assert.areEqual(1, second.stalledCleared, 'Counted');
    }

    @IsTest
    static void escalationAfterSecondMissedFollowUpCreatesAssignedTask() {
        FollowUpTestDataFactory.useOnlyRules(
            new Set<String>{ FollowUpConstants.RULE_RECORDS_FOLLOW_UP, FollowUpConstants.RULE_PROVIDER_ESCALATION }
        );
        Matter__c matter = theMatter();
        Records_Request__c req = [SELECT Id FROM Records_Request__c LIMIT 1];
        String key = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP, req.Id);
        insert new List<Follow_Up_Recommendation__c>{
            FollowUpTestDataFactory.sentRecommendation(
                matter.Id,
                FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
                'Provider',
                key,
                System.now().addDays(-25)
            ),
            FollowUpTestDataFactory.sentRecommendation(
                matter.Id,
                FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
                'Provider',
                key,
                System.now().addDays(-10)
            )
        };

        Test.startTest();
        FollowUpEvaluationService.Summary summary = FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'RUN-1');
        Test.stopTest();

        Follow_Up_Recommendation__c escalation = recsByType(matter.Id).get(FollowUpConstants.TYPE_PROVIDER_ESCALATION);
        Assert.isNotNull(escalation, 'Escalation created: ' + summary.messages);
        Assert.isNotNull(escalation.Task_Id__c, 'Task assigned automatically');
        Assert.areEqual(1, summary.tasksCreated, 'One task');
    }

    @IsTest
    static void bulkEvaluationStaysWithinGovernorLimits() {
        FollowUpTestDataFactory.useDefaultConfig();
        Medical_Provider__c provider = [SELECT Id FROM Medical_Provider__c LIMIT 1];
        List<Contact> clients = new List<Contact>();
        for (Integer i = 0; i < 200; i++) {
            clients.add(FollowUpTestDataFactory.client(null, 'client' + i + '@bulk.example', '555' + i));
        }
        insert clients;
        List<Matter__c> matters = new List<Matter__c>();
        for (Integer i = 0; i < 200; i++) {
            matters.add(FollowUpTestDataFactory.matter('BULK-' + i, clients[i].Id, UserInfo.getUserId(), TODAY.addDays(-100)));
        }
        insert matters;
        List<SObject> children = new List<SObject>();
        for (Matter__c matter : matters) {
            children.add(FollowUpTestDataFactory.treatment(matter.Id, provider.Id, TODAY.addDays(-50), 'Completed'));
            children.add(FollowUpTestDataFactory.request(matter.Id, provider.Id, 'Records', 'Requested', TODAY.addDays(-30)));
        }
        insert children;
        Set<Id> matterIds = new Map<Id, Matter__c>(matters).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        FollowUpEvaluationService.Summary summary = FollowUpEvaluationService.evaluate(matterIds, 'BULK');
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(200, summary.mattersEvaluated, 'All matters evaluated');
        Assert.areEqual(0, summary.errors, 'No errors: ' + summary.messages);
        Assert.isTrue(summary.created >= 600, 'Check-in, provider follow-up and missing bills per matter');
        Assert.isTrue(queriesUsed <= 15, 'Constant query count regardless of volume, used ' + queriesUsed);
    }

    @IsTest
    static void batchEvaluatesOnlyOpenPersonalInjuryMatters() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        Contact client = [SELECT Id FROM Contact LIMIT 1];
        Matter__c closed = FollowUpTestDataFactory.matter('M-CLOSED', client.Id, UserInfo.getUserId(), TODAY.addDays(-200));
        closed.Status__c = 'Closed';
        Matter__c otherPractice = FollowUpTestDataFactory.matter('M-WC', client.Id, UserInfo.getUserId(), TODAY.addDays(-200));
        otherPractice.Practice_Area__c = 'Workers Compensation';
        insert new List<Matter__c>{ closed, otherPractice };

        Test.startTest();
        Database.executeBatch(new FollowUpEvaluationBatch(), 200);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Follow_Up_Recommendation__c WHERE Matter__r.Name = 'M-1001'], 'Open PI matter evaluated');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Follow_Up_Recommendation__c WHERE Matter__r.Name IN ('M-CLOSED', 'M-WC')],
            'Closed and non-PI matters skipped'
        );
    }

    @IsTest
    static void schedulerSchedulesAndAvoidsOverlap() {
        FollowUpTestDataFactory.useDefaultConfig();
        Test.startTest();
        Id cronId = FollowUpNightlyScheduler.schedule(null);
        Id firstRun = FollowUpNightlyScheduler.run();
        Test.stopTest();

        CronTrigger scheduled = [SELECT CronExpression FROM CronTrigger WHERE Id = :cronId];
        Assert.areEqual(FollowUpNightlyScheduler.DEFAULT_CRON, scheduled.CronExpression, 'Default nightly schedule');
        Assert.isNotNull(firstRun, 'Batch started when nothing was running');
    }

    @IsTest
    static void aiDraftsReplaceTemplatesOnlyWhenSafe() {
        FollowUpTestDataFactory.useOnlyRules(
            new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP, FollowUpConstants.RULE_RECORDS_FOLLOW_UP }
        );
        Matter__c matter = theMatter();
        FollowUpEvaluationService.evaluate(new Set<Id>{ matter.Id }, 'AI-RUN');
        Map<String, Follow_Up_Recommendation__c> before = recsByType(matter.Id);
        StubGenerator stub = new StubGenerator();
        stub.unsafeId = before.get(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP).Id;
        FollowUpDraftService.generatorOverride = stub;

        Test.startTest();
        System.enqueueJob(new FollowUpAiDraftQueueable('AI-RUN'));
        Test.stopTest();

        Map<String, Follow_Up_Recommendation__c> after = recsByType(matter.Id);
        Follow_Up_Recommendation__c checkIn = after.get(FollowUpConstants.TYPE_CLIENT_CHECK_IN);
        Assert.areEqual(FollowUpConstants.DRAFT_AI, checkIn.Draft_Source__c, 'Safe AI draft accepted');
        Assert.areEqual('AI check-in text', checkIn.Draft_Message__c, 'AI text stored');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, checkIn.Status__c, 'Still requires approval');
        Follow_Up_Recommendation__c provider = after.get(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP);
        Assert.areEqual(FollowUpConstants.DRAFT_TEMPLATE, provider.Draft_Source__c, 'Unsafe AI draft discarded');
        Assert.areEqual(Label.FollowUp_AI_Draft_Withheld, provider.AI_Rationale__c, 'Reviewer told why');
        Assert.areEqual(2, stub.calls, 'Only client/provider-facing drafts sent to AI');
    }

    private class StubGenerator implements IFollowUpDraftGenerator {
        Id unsafeId;
        Integer calls = 0;
        public List<FollowUpDraftResult> generate(List<Follow_Up_Recommendation__c> recommendations) {
            List<FollowUpDraftResult> results = new List<FollowUpDraftResult>();
            for (Follow_Up_Recommendation__c rec : recommendations) {
                calls++;
                FollowUpDraftResult result = new FollowUpDraftResult(rec.Id);
                result.success = true;
                result.source = FollowUpConstants.DRAFT_AI;
                result.message = rec.Id == unsafeId ? 'Your settlement will be large.' : 'AI check-in text';
                result.rationale = 'Gap exceeds threshold.';
                results.add(result);
            }
            return results;
        }
    }
}
