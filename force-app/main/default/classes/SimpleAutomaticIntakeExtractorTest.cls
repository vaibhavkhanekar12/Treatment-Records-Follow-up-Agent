@IsTest
private class SimpleAutomaticIntakeExtractorTest {
    @IsTest
    static void extractsMedicalRecordsAndMatchesMatterAndProvider() {
        Contact client = FollowUpTestDataFactory.client(null, 'simple-intake-client@example.com', '5550111');
        insert client;

        Medical_Provider__c provider = FollowUpTestDataFactory.provider(
            'QA Test Medical Center', 'qa-provider@example.com', '5550222'
        );
        insert provider;

        Matter__c matter = FollowUpTestDataFactory.matter(
            'QA Test Matter 001', client.Id, UserInfo.getUserId(), Date.today().addDays(-40)
        );
        insert matter;

        Automatic_Intake__c intake = new Automatic_Intake__c(
            Email_Message_Id__c = 'simple-extractor-test',
            Status__c = 'Needs Review',
            Classification__c = 'Medical Records',
            Body_Text__c = 'Hello,\n\nDocument type: Medical Records\nMatter reference: QA Test Matter 001\nProvider: QA Test Medical Center\nProvider Email: qa-provider@example.com\nPlease process this test email for review.'
        );
        insert intake;

        Test.startTest();
        AutomaticIntakeService.ExtractedPayload payload =
            new SimpleAutomaticIntakeExtractor().extract(intake);
        Test.stopTest();

        System.assertEquals('Medical Records', payload.documentType);
        System.assertEquals(0.95, payload.confidence);
        System.assertEquals(matter.Id, payload.matterId);
        System.assertEquals(true, payload.matterMatchUnambiguous);
        System.assertEquals(provider.Id, payload.providerId);
        System.assertEquals('Records', payload.requestType);
    }

    @IsTest
    static void ambiguousMatterDoesNotCreateCandidate() {
        Contact client = FollowUpTestDataFactory.client(null, 'ambiguous-intake-client@example.com', '5550333');
        insert client;

        Matter__c first = FollowUpTestDataFactory.matter(
            'DUPLICATE MATTER', client.Id, UserInfo.getUserId(), Date.today().addDays(-20)
        );
        Matter__c second = FollowUpTestDataFactory.matter(
            'DUPLICATE MATTER', client.Id, UserInfo.getUserId(), Date.today().addDays(-10)
        );
        insert new List<Matter__c>{ first, second };

        Automatic_Intake__c intake = new Automatic_Intake__c(
            Email_Message_Id__c = 'simple-extractor-ambiguous-test',
            Status__c = 'Needs Review',
            Classification__c = 'Medical Records',
            Body_Text__c = 'Document type: Medical Records\nMatter reference: DUPLICATE MATTER\nProvider: QA Test Medical Center'
        );
        insert intake;

        AutomaticIntakeService.ExtractedPayload payload =
            new SimpleAutomaticIntakeExtractor().extract(intake);

        System.assertEquals(false, payload.matterMatchUnambiguous);
        System.assertEquals(null, payload.matterId);
    }
}
