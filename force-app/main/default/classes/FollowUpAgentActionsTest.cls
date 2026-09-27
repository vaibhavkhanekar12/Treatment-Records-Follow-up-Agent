/**
 * Agentforce invocable actions, executed as a case manager (the employee using the agent).
 */
@IsTest
private class FollowUpAgentActionsTest {
    private static final Date TODAY = Date.today();

    @TestSetup
    static void setup() {
        User caseManager;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            caseManager = FollowUpTestDataFactory.createUser('fuagent', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
            FollowUpTestDataFactory.createUser('fuagent2', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
        }
        Contact client = FollowUpTestDataFactory.client(caseManager.Id, 'jamie@client.example', '5550001');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Metro PT', 'records@metropt.example', null);
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('M-5001', client.Id, caseManager.Id, TODAY.addDays(-100));
        insert matter;
        insert new List<SObject>{
            FollowUpTestDataFactory.treatment(matter.Id, provider.Id, TODAY.addDays(-35), 'Completed'),
            FollowUpTestDataFactory.request(matter.Id, provider.Id, 'Records', 'Requested', TODAY.addDays(-20))
        };
    }

    private static User user(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND Email LIKE '%@followup.example.com' LIMIT 1];
    }

    private static Matter__c matter() {
        return [SELECT Id, Name FROM Matter__c WHERE Name = 'M-5001'];
    }

    @IsTest
    static void statusActionReturnsVerifiedFactsWithoutIds() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpGetMatterStatusAction.Request request = new FollowUpGetMatterStatusAction.Request();
        request.matterName = 'M-5001';
        List<FollowUpGetMatterStatusAction.Response> responses;

        Test.startTest();
        System.runAs(user('fuagent')) {
            responses = FollowUpGetMatterStatusAction.getStatus(new List<FollowUpGetMatterStatusAction.Request>{ request });
        }
        Test.stopTest();

        FollowUpGetMatterStatusAction.Response response = responses[0];
        Assert.isTrue(response.success, response.message);
        Assert.areEqual(35, response.treatmentGapDays, 'Gap from last treatment');
        Assert.areEqual(1, response.outstandingRequestCount, 'One outstanding request');
        Assert.areEqual(20, response.oldestOutstandingRequestDays, 'Request age');
        Assert.isNull(response.daysSinceClientContact, 'No contact recorded -> empty, not invented');
        Assert.isTrue(response.matterFacts.contains('Metro PT'), 'Provider named');
        Assert.isFalse(response.matterFacts.contains(String.valueOf(matter().Id)), 'No record Ids in grounding text');
        Assert.isTrue(response.matterFacts.contains('Last client contact: ' + Label.FollowUp_Not_Recorded), 'Missing data explicit');
    }

    @IsTest
    static void actionsReturnNotFoundForInaccessibleMatter() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpGetMatterStatusAction.Request request = new FollowUpGetMatterStatusAction.Request();
        request.matterId = matter().Id;
        FollowUpEvaluateMatterAction.Request evalRequest = new FollowUpEvaluateMatterAction.Request();
        evalRequest.matterId = matter().Id;
        List<FollowUpGetMatterStatusAction.Response> statusResponses;
        List<FollowUpEvaluateMatterAction.Response> evalResponses;

        Test.startTest();
        System.runAs(user('fuagent2')) {
            statusResponses = FollowUpGetMatterStatusAction.getStatus(new List<FollowUpGetMatterStatusAction.Request>{ request });
            evalResponses = FollowUpEvaluateMatterAction.evaluate(new List<FollowUpEvaluateMatterAction.Request>{ evalRequest });
        }
        Test.stopTest();

        Assert.isFalse(statusResponses[0].success, 'Other case manager cannot see the matter');
        Assert.areEqual(Label.FollowUp_Error_Matter_Not_Found, statusResponses[0].message, 'Neutral message, no data leaked');
        Assert.isFalse(evalResponses[0].success, 'Cannot evaluate an inaccessible matter');
        Assert.areEqual(0, [SELECT COUNT() FROM Follow_Up_Recommendation__c], 'Nothing created');
    }

    @IsTest
    static void evaluateThenDraftThenHistory() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpEvaluateMatterAction.Request evalRequest = new FollowUpEvaluateMatterAction.Request();
        evalRequest.matterId = matter().Id;
        List<FollowUpEvaluateMatterAction.Response> evalResponses;
        List<FollowUpGenerateDraftAction.Response> draftResponses;
        List<FollowUpGetHistoryAction.Response> historyResponses;

        Test.startTest();
        System.runAs(user('fuagent')) {
            evalResponses = FollowUpEvaluateMatterAction.evaluate(new List<FollowUpEvaluateMatterAction.Request>{ evalRequest });
            Follow_Up_Recommendation__c checkIn = [
                SELECT Id, Name
                FROM Follow_Up_Recommendation__c
                WHERE Recommendation_Type__c = :FollowUpConstants.TYPE_CLIENT_CHECK_IN
            ];
            FollowUpGenerateDraftAction.Request draftRequest = new FollowUpGenerateDraftAction.Request();
            draftRequest.recommendationNumber = checkIn.Name;
            draftResponses = FollowUpGenerateDraftAction.generate(new List<FollowUpGenerateDraftAction.Request>{ draftRequest });
            FollowUpGetHistoryAction.Request historyRequest = new FollowUpGetHistoryAction.Request();
            historyRequest.matterName = 'M-5001';
            historyResponses = FollowUpGetHistoryAction.getHistory(new List<FollowUpGetHistoryAction.Request>{ historyRequest });
        }
        Test.stopTest();

        Assert.isTrue(evalResponses[0].success, evalResponses[0].message);
        Assert.isTrue(evalResponses[0].createdCount >= 2, 'Check-in and provider follow-up created');
        Assert.isTrue(evalResponses[0].openRecommendations.contains('Client Check-In'), 'Listed with labels');
        Assert.isTrue(draftResponses[0].success, draftResponses[0].message);
        Assert.areEqual(FollowUpConstants.DRAFT_TEMPLATE, draftResponses[0].draftSource, 'Template when AI is not configured');
        Assert.isTrue(draftResponses[0].draftMessage.contains('Jamie'), 'Draft uses verified facts');
        Assert.areEqual(
            FollowUpConstants.STATUS_PENDING_REVIEW,
            [SELECT Status__c FROM Follow_Up_Recommendation__c WHERE Recommendation_Type__c = :FollowUpConstants.TYPE_CLIENT_CHECK_IN]
            .Status__c,
            'Agent never approves or sends'
        );
        Assert.isTrue(historyResponses[0].success, historyResponses[0].message);
        Assert.isTrue(historyResponses[0].followUpCount >= 2, 'History returned');
    }

    @IsTest
    static void logResponseActionAcceptsAgentCategory() {
        FollowUpTestDataFactory.useDefaultConfig();
        Matter__c matter = matter();
        Follow_Up_Recommendation__c sent = FollowUpTestDataFactory.sentRecommendation(
            matter.Id,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            'Client',
            'AGENT|CLIENT',
            System.now().addDays(-2)
        );
        insert sent;
        FollowUpLogResponseAction.Request request = new FollowUpLogResponseAction.Request();
        request.recommendationId = sent.Id;
        request.responseText = 'I quit going, it was too far away.';
        request.category = 'Treatment_Stopped';
        request.confidence = 0.9;
        request.source = 'SMS';
        List<FollowUpLogResponseAction.Response> responses;

        Test.startTest();
        System.runAs(user('fuagent')) {
            responses = FollowUpLogResponseAction.logResponses(new List<FollowUpLogResponseAction.Request>{ request });
        }
        Test.stopTest();

        Assert.isTrue(responses[0].success, responses[0].message);
        Assert.areEqual('Treatment_Stopped', responses[0].category, 'Agent category accepted');
        Assert.isTrue(responses[0].reviewCreated, 'Routed to the case manager');
    }

    @IsTest
    static void escalationIsIdempotentWhileOpen() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpEscalateMatterAction.Request request = new FollowUpEscalateMatterAction.Request();
        request.matterName = 'M-5001';
        request.reason = 'Provider has not responded to three phone calls.';
        List<FollowUpEscalateMatterAction.Response> first;
        List<FollowUpEscalateMatterAction.Response> second;

        Test.startTest();
        System.runAs(user('fuagent')) {
            first = FollowUpEscalateMatterAction.escalate(new List<FollowUpEscalateMatterAction.Request>{ request });
            second = FollowUpEscalateMatterAction.escalate(new List<FollowUpEscalateMatterAction.Request>{ request });
        }
        Test.stopTest();

        Assert.isTrue(first[0].success, first[0].message);
        Assert.isNotNull(first[0].recommendationNumber, 'Number returned, not an Id');
        Assert.isTrue(second[0].success, second[0].message);
        Assert.areEqual(first[0].recommendationNumber, second[0].recommendationNumber, 'Same open escalation');
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM Follow_Up_Recommendation__c
                WHERE Recommendation_Type__c = :FollowUpConstants.TYPE_CASE_MANAGER_ESCALATION
            ],
            'No duplicate'
        );
        Assert.areEqual(1, [SELECT COUNT() FROM Task], 'One assigned task');
    }

    @IsTest
    static void escalationRequiresReason() {
        FollowUpEscalateMatterAction.Request request = new FollowUpEscalateMatterAction.Request();
        request.matterName = 'M-5001';
        List<FollowUpEscalateMatterAction.Response> responses;
        Test.startTest();
        System.runAs(user('fuagent')) {
            responses = FollowUpEscalateMatterAction.escalate(new List<FollowUpEscalateMatterAction.Request>{ request });
        }
        Test.stopTest();
        Assert.isFalse(responses[0].success, 'Rejected');
        Assert.areEqual(Label.FollowUp_Error_Reason_Required, responses[0].message, 'Reason required');
    }
}
