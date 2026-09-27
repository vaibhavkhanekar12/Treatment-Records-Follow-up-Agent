/**
 * Tests for the Agentforce / Prompt Builder adapters. LLM calls cannot run in unit tests, so these tests
 * cover grounding content, output parsing, template routing and graceful failure.
 */
@IsTest
private class FollowUpEinsteinTest {
    @TestSetup
    static void setup() {
        Contact client = new Contact(
            FirstName = 'Jamie',
            LastName = 'Client',
            Email = 'jamie@client.example',
            Birthdate = Date.newInstance(1985, 4, 12)
        );
        insert client;
        Matter__c matter = new Matter__c(
            Name = 'M-7001',
            Status__c = 'Treating',
            Practice_Area__c = 'Personal Injury',
            Client__c = client.Id,
            Case_Manager__c = UserInfo.getUserId(),
            Sign_Up_Date__c = Date.today().addDays(-60)
        );
        insert matter;
        insert new Follow_Up_Recommendation__c(
            Matter__c = matter.Id,
            Recommendation_Type__c = FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            Status__c = FollowUpConstants.STATUS_PENDING_REVIEW,
            Audience__c = FollowUpConstants.AUDIENCE_PROVIDER,
            Channel__c = FollowUpConstants.CHANNEL_EMAIL,
            Reason__c = 'Records request outstanding 20 days.',
            Draft_Message__c = 'Patient Jamie Client, date of birth ' + Date.newInstance(1985, 4, 12).format() + '.',
            Draft_Source__c = FollowUpConstants.DRAFT_TEMPLATE,
            Dedupe_Key__c = 'EINSTEIN|TEST'
        );
    }

    private static Follow_Up_Recommendation__c rec() {
        return [SELECT Id, Matter__c, Audience__c, Recommendation_Type__c FROM Follow_Up_Recommendation__c LIMIT 1];
    }

    @IsTest
    static void groundingContainsVerifiedFactsOnly() {
        FollowUpPromptFacts.Request request = new FollowUpPromptFacts.Request();
        request.recommendation = rec();

        List<FollowUpPromptFacts.Response> responses = FollowUpPromptFacts.getFacts(new List<FollowUpPromptFacts.Request>{ request });

        String prompt = responses[0].Prompt;
        Assert.isTrue(prompt.contains('Matter: M-7001'), 'Matter facts included');
        Assert.isTrue(prompt.contains('Records request outstanding 20 days.'), 'Deterministic reason included');
        Assert.isTrue(prompt.contains(FollowUpFactsBuilder.DOB_PLACEHOLDER), 'Date of birth replaced by placeholder');
        Assert.isFalse(prompt.contains('1985'), 'Date of birth never sent to the LLM');
        Assert.isFalse(prompt.contains(String.valueOf(request.recommendation.Id)), 'No record Ids');
        Assert.isFalse(prompt.contains(String.valueOf(request.recommendation.Matter__c)), 'No record Ids');
    }

    @IsTest
    static void groundingWithoutAccessibleRecordReturnsNoFacts() {
        FollowUpPromptFacts.Request request = new FollowUpPromptFacts.Request();
        request.recommendation = new Follow_Up_Recommendation__c();
        List<FollowUpPromptFacts.Response> responses = FollowUpPromptFacts.getFacts(new List<FollowUpPromptFacts.Request>{ request });
        Assert.isTrue(responses[0].Prompt.startsWith('No verified facts'), 'Model told not to generate');
    }

    @IsTest
    static void draftParsingToleratesFencesAndRejectsGarbage() {
        Id recId = rec().Id;
        FollowUpDraftResult ok = FollowUpEinsteinDraftGenerator.parse(
            recId,
            '```json\n{"subject":"Checking in","message":"Hi Jamie","rationale":"Gap of 30 days"}\n```'
        );
        Assert.isTrue(ok.success, 'Parsed');
        Assert.areEqual('Hi Jamie', ok.message, 'Message');
        Assert.areEqual(FollowUpConstants.DRAFT_AI, ok.source, 'AI source');

        Assert.isFalse(FollowUpEinsteinDraftGenerator.parse(recId, 'Sure! Here is a message.').success, 'Not JSON');
        Assert.isFalse(FollowUpEinsteinDraftGenerator.parse(recId, '{"message":""}').success, 'Empty');
        Assert.isFalse(FollowUpEinsteinDraftGenerator.parse(recId, null).success, 'Null');
    }

    @IsTest
    static void templateRouting() {
        Assert.areEqual(FollowUpEinsteinDraftGenerator.PROVIDER_TEMPLATE, FollowUpEinsteinDraftGenerator.templateFor(rec()), 'Provider');
        Assert.areEqual(
            FollowUpEinsteinDraftGenerator.CLIENT_TEMPLATE,
            FollowUpEinsteinDraftGenerator.templateFor(new Follow_Up_Recommendation__c(Audience__c = 'Client')),
            'Client'
        );
        Assert.areEqual(
            FollowUpEinsteinDraftGenerator.STALLED_TEMPLATE,
            FollowUpEinsteinDraftGenerator.templateFor(
                new Follow_Up_Recommendation__c(Audience__c = 'Internal', Recommendation_Type__c = FollowUpConstants.TYPE_STALLED_MATTER)
            ),
            'Stalled'
        );
        Assert.isNull(
            FollowUpEinsteinDraftGenerator.templateFor(new Follow_Up_Recommendation__c(Audience__c = 'Internal')),
            'Other internal: no AI'
        );
    }

    @IsTest
    static void generationFailureIsReportedNotThrown() {
        // ConnectApi generation is unavailable in unit tests: the generator must degrade gracefully.
        List<FollowUpDraftResult> results = new FollowUpEinsteinDraftGenerator().generate(new List<Follow_Up_Recommendation__c>{ rec() });
        Assert.areEqual(1, results.size(), 'One result per recommendation');
        Assert.isFalse(results[0].success, 'Failure reported');
        Assert.isNotNull(results[0].error, 'Error message kept');

        List<FollowUpClassification> classifications = new FollowUpEinsteinClassifier()
            .classify(new List<FollowUpClassification.Request>{ new FollowUpClassification.Request(rec().Id, 'We sent it', 'Provider') });
        Assert.isTrue(classifications.isEmpty(), 'Failed classifications are dropped so the keyword fallback applies');
    }

    @IsTest
    static void classificationParsing() {
        Id recId = rec().Id;
        FollowUpClassification parsed = FollowUpEinsteinClassifier.parse(
            recId,
            '{"category":"Records_Sent","confidence":0.92,"summary":"Provider sent records."}'
        );
        Assert.areEqual('Records_Sent', parsed.category, 'Category');
        Assert.areEqual(0.92, parsed.confidence, 'Confidence');
        Assert.areEqual('AI', parsed.source, 'Source');
        Assert.isNull(FollowUpEinsteinClassifier.parse(recId, '{"confidence":1}'), 'Missing category rejected');
        Assert.isNull(FollowUpEinsteinClassifier.parse(recId, 'Records_Sent'), 'Non-JSON rejected');
    }
}
