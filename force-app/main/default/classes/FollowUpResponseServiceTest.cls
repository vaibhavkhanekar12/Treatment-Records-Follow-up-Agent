/**
 * Inbound response classification (keyword, human/agent-supplied, asynchronous AI) and next actions.
 */
@IsTest
private class FollowUpResponseServiceTest {
    @TestSetup
    static void setup() {
        User caseManager;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            caseManager = FollowUpTestDataFactory.createUser('furesp', new List<String>{ FollowUpTestDataFactory.PS_CASE_MANAGER });
        }
        Contact client = FollowUpTestDataFactory.client(caseManager.Id, 'jamie@client.example', '5550001');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Metro PT', 'records@metropt.example', null);
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('M-4001', client.Id, caseManager.Id, Date.today().addDays(-90));
        Matter__c quiet = FollowUpTestDataFactory.matter('M-4002', client.Id, caseManager.Id, Date.today().addDays(-90));
        insert new List<Matter__c>{ matter, quiet };
        Follow_Up_Recommendation__c checkIn = FollowUpTestDataFactory.sentRecommendation(
            matter.Id,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            'Client',
            'RESP|CLIENT',
            System.now().addDays(-3)
        );
        checkIn.Recipient_Contact__c = client.Id;
        Follow_Up_Recommendation__c providerFollowUp = FollowUpTestDataFactory.sentRecommendation(
            matter.Id,
            FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            'Provider',
            'RESP|PROVIDER',
            System.now().addDays(-1)
        );
        providerFollowUp.Medical_Provider__c = provider.Id;
        insert new List<Follow_Up_Recommendation__c>{ checkIn, providerFollowUp };
    }

    private static User caseManager() {
        return [SELECT Id FROM User WHERE Alias = 'furesp' AND Email LIKE '%@followup.example.com' LIMIT 1];
    }

    private static Follow_Up_Recommendation__c rec(String key) {
        return [
            SELECT
                Id,
                Name,
                Status__c,
                Response_Received__c,
                Response_Text__c,
                Response_Classification__c,
                Classification_Confidence__c,
                Next_Follow_Up_Date__c,
                Matter__c
            FROM Follow_Up_Recommendation__c
            WHERE Dedupe_Key__c = :key
        ];
    }

    private static FollowUpResponseService.ResponseInput input(Id recId, String text, String category, Decimal confidence) {
        FollowUpResponseService.ResponseInput input = new FollowUpResponseService.ResponseInput();
        input.recommendationId = recId;
        input.responseText = text;
        input.category = category;
        input.confidence = confidence;
        input.source = 'SMS';
        return input;
    }

    private static List<FollowUpResponseService.ResponseResult> logAsCaseManager(List<FollowUpResponseService.ResponseInput> inputs) {
        List<FollowUpResponseService.ResponseResult> results;
        System.runAs(caseManager()) {
            results = FollowUpResponseService.logResponses(inputs);
        }
        return results;
    }

    @IsTest
    static void keywordClassifierHandlesSpecExamples() {
        FollowUpTestDataFactory.useDefaultConfig();
        Assert.areEqual(
            'Treatment_Continuing',
            FollowUpResponseService.suggest('I am still going to physical therapy.', 'Client').category,
            'Continuing'
        );
        Assert.areEqual(
            'Treatment_Stopped',
            FollowUpResponseService.suggest('I stopped treatment last month.', 'Client').category,
            'Stopped'
        );
        Assert.areEqual(
            'Records_Sent',
            FollowUpResponseService.suggest('We sent the records yesterday.', 'Provider').category,
            'Records sent'
        );
        Assert.areEqual(
            'Provider_Action_Required',
            FollowUpResponseService.suggest('We need another authorization.', 'Provider').category,
            'Action required'
        );
        Assert.areEqual('Opt_Out', FollowUpResponseService.suggest('STOP', 'Client').category, 'Opt-out (exact message)');
        FollowUpClassification unclear = FollowUpResponseService.suggest('Thanks!', 'Client');
        Assert.areEqual(FollowUpConstants.CATEGORY_UNCLEAR, unclear.category, 'No match');
        Assert.areEqual(0, unclear.confidence, 'Zero confidence forces review');
    }

    @IsTest
    static void treatmentStoppedRoutesToCaseManagerReview() {
        FollowUpTestDataFactory.useDefaultConfig();
        Follow_Up_Recommendation__c checkIn = rec('RESP|CLIENT');

        Test.startTest();
        List<FollowUpResponseService.ResponseResult> results = logAsCaseManager(
            new List<FollowUpResponseService.ResponseInput>{ input(checkIn.Id, 'I stopped treatment last month.', null, null) }
        );
        Test.stopTest();

        Assert.areEqual('Treatment_Stopped', results[0].category, 'Classified');
        Assert.areEqual(FollowUpConstants.ACTION_CASE_MANAGER_REVIEW, results[0].nextAction, 'Human review');
        Assert.isTrue(results[0].reviewCreated, 'Review item created');
        Follow_Up_Recommendation__c answered = rec('RESP|CLIENT');
        Assert.areEqual(FollowUpConstants.STATUS_COMPLETED, answered.Status__c, 'Original follow-up completed');
        Assert.isTrue(answered.Response_Received__c, 'Response recorded');
        Assert.areEqual(80, answered.Classification_Confidence__c, 'Keyword confidence stored as a percentage');
        Assert.areEqual(Date.today().addDays(14), answered.Next_Follow_Up_Date__c, 'Check-ins paused while the case manager reviews');
        Follow_Up_Recommendation__c review = [
            SELECT Priority__c, Audience__c, Related_Recommendation__c, Response_Text__c
            FROM Follow_Up_Recommendation__c
            WHERE Recommendation_Type__c = :FollowUpConstants.TYPE_INBOUND_REVIEW
        ];
        Assert.areEqual(checkIn.Id, review.Related_Recommendation__c, 'Linked to the original');
        Assert.areEqual(FollowUpConstants.AUDIENCE_INTERNAL, review.Audience__c, 'Internal');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Inbound response (SMS)%'], 'Inbound activity logged');
    }

    @IsTest
    static void recordsSentCompletesAndSchedulesRecheck() {
        FollowUpTestDataFactory.useDefaultConfig();
        Test.startTest();
        List<FollowUpResponseService.ResponseResult> results = logAsCaseManager(
            new List<FollowUpResponseService.ResponseInput>{
                input(rec('RESP|PROVIDER').Id, 'We faxed the records this morning.', null, null)
            }
        );
        Test.stopTest();

        Follow_Up_Recommendation__c providerFollowUp = rec('RESP|PROVIDER');
        Assert.areEqual(FollowUpConstants.ACTION_COMPLETE_AND_RECHECK, results[0].nextAction, 'Configured action');
        Assert.areEqual(FollowUpConstants.STATUS_COMPLETED, providerFollowUp.Status__c, 'Completed');
        Assert.areEqual(Date.today().addDays(7), providerFollowUp.Next_Follow_Up_Date__c, 'Re-check date from CMDT');
        Assert.isFalse(results[0].reviewCreated, 'No review needed');
    }

    @IsTest
    static void lowConfidenceAlwaysGoesToReview() {
        FollowUpTestDataFactory.useDefaultConfig();
        Test.startTest();
        List<FollowUpResponseService.ResponseResult> results = logAsCaseManager(
            new List<FollowUpResponseService.ResponseInput>{ input(rec('RESP|CLIENT').Id, 'maybe', 'Treatment_Continuing', 0.4) }
        );
        Test.stopTest();
        Assert.areEqual(FollowUpConstants.ACTION_CASE_MANAGER_REVIEW, results[0].nextAction, 'Below 0.7 threshold');
        Assert.isTrue(results[0].reviewCreated, 'Review created');
        Assert.isNull(rec('RESP|CLIENT').Next_Follow_Up_Date__c, 'Low confidence never pauses follow-ups');
    }

    @IsTest
    static void humanConfirmedCategoryIsApplied() {
        FollowUpTestDataFactory.useDefaultConfig();
        Test.startTest();
        List<FollowUpResponseService.ResponseResult> results = logAsCaseManager(
            new List<FollowUpResponseService.ResponseInput>{
                input(rec('RESP|CLIENT').Id, 'Yes, going twice a week', 'Treatment_Continuing', null)
            }
        );
        Test.stopTest();
        Assert.areEqual(1, results[0].confidence, 'Human confirmation = full confidence');
        Assert.areEqual(Date.today().addDays(14), rec('RESP|CLIENT').Next_Follow_Up_Date__c, 'Check-ins paused for 14 days');
    }

    @IsTest
    static void invalidCategoryIsRejected() {
        FollowUpTestDataFactory.useDefaultConfig();
        Exception caught;
        Test.startTest();
        try {
            logAsCaseManager(
                new List<FollowUpResponseService.ResponseInput>{ input(rec('RESP|CLIENT').Id, 'text', 'Settlement_Offer', null) }
            );
        } catch (FollowUpException e) {
            caught = e;
        }
        Test.stopTest();
        Assert.isNotNull(caught, 'Only configured operational categories are accepted');
        Assert.isFalse(rec('RESP|CLIENT').Response_Received__c, 'Nothing saved');
    }

    @IsTest
    static void matterOnlyInputAttachesToLatestSentFollowUp() {
        FollowUpTestDataFactory.useDefaultConfig();
        Follow_Up_Recommendation__c providerFollowUp = rec('RESP|PROVIDER');
        FollowUpResponseService.ResponseInput byMatter = input(
            null,
            'We need another authorization before we can release records.',
            null,
            null
        );
        byMatter.matterId = providerFollowUp.Matter__c;
        byMatter.audience = 'Provider';

        Test.startTest();
        logAsCaseManager(new List<FollowUpResponseService.ResponseInput>{ byMatter });
        Test.stopTest();

        Assert.areEqual('Provider_Action_Required', rec('RESP|PROVIDER').Response_Classification__c, 'Attached to the provider follow-up');
    }

    @IsTest
    static void unmatchedResponseIsHeldForReview() {
        FollowUpTestDataFactory.useDefaultConfig();
        Matter__c quiet = [SELECT Id FROM Matter__c WHERE Name = 'M-4002'];
        FollowUpResponseService.ResponseInput byMatter = input(null, 'Can someone call me?', null, null);
        byMatter.matterId = quiet.Id;

        Test.startTest();
        logAsCaseManager(new List<FollowUpResponseService.ResponseInput>{ byMatter });
        Test.stopTest();

        Follow_Up_Recommendation__c holder = [
            SELECT Recommendation_Type__c, Response_Text__c, Response_Classification__c, Status__c
            FROM Follow_Up_Recommendation__c
            WHERE Matter__c = :quiet.Id
        ];
        Assert.areEqual(FollowUpConstants.TYPE_INBOUND_REVIEW, holder.Recommendation_Type__c, 'Held as a review item');
        Assert.areEqual('Callback_Requested', holder.Response_Classification__c, 'Still classified');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, holder.Status__c, 'Open for the case manager');
    }

    @IsTest
    static void aiClassificationRunsAsynchronously() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpResponseService.aiClassifierOverride = new StubClassifier(false);
        Id recId = rec('RESP|PROVIDER').Id;

        Test.startTest();
        List<FollowUpResponseService.ResponseResult> results = logAsCaseManager(
            new List<FollowUpResponseService.ResponseInput>{ input(recId, 'The chart is on its way', null, null) }
        );
        Assert.isTrue(results[0].pendingAiClassification, 'Deferred to the queueable');
        Assert.areEqual(FollowUpConstants.CATEGORY_PENDING, rec('RESP|PROVIDER').Response_Classification__c, 'Pending until classified');
        Test.stopTest();

        Follow_Up_Recommendation__c classified = rec('RESP|PROVIDER');
        Assert.areEqual('Records_Sent', classified.Response_Classification__c, 'AI category applied');
        Assert.areEqual(95, classified.Classification_Confidence__c, 'AI confidence stored');
        Assert.areEqual(FollowUpConstants.STATUS_COMPLETED, classified.Status__c, 'Deterministic next action applied');
    }

    @IsTest
    static void aiFailureFallsBackToKeywords() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpResponseService.aiClassifierOverride = new StubClassifier(true);

        Test.startTest();
        logAsCaseManager(
            new List<FollowUpResponseService.ResponseInput>{ input(rec('RESP|PROVIDER').Id, 'We sent the records yesterday.', null, null) }
        );
        Test.stopTest();

        Assert.areEqual('Records_Sent', rec('RESP|PROVIDER').Response_Classification__c, 'Keyword fallback');
        Assert.areEqual(80, rec('RESP|PROVIDER').Classification_Confidence__c, 'Keyword confidence');
    }

    private class StubClassifier implements IFollowUpResponseClassifier {
        private Boolean fail;
        StubClassifier(Boolean fail) {
            this.fail = fail;
        }
        public List<FollowUpClassification> classify(List<FollowUpClassification.Request> requests) {
            if (fail) {
                throw new CalloutException('LLM unavailable (stub)');
            }
            List<FollowUpClassification> results = new List<FollowUpClassification>();
            for (FollowUpClassification.Request request : requests) {
                results.add(new FollowUpClassification(request.recommendationId, 'Records_Sent', 0.95, 'AI'));
            }
            return results;
        }
    }
}
