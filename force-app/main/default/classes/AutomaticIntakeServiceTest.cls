@IsTest
private class AutomaticIntakeServiceTest {
    @IsTest
    static void lowConfidencePayloadIsRoutedToReview() {
        Contact client = FollowUpTestDataFactory.client(null, 'intake-client@example.com', '5550199');
        insert client;
        Matter__c matter = FollowUpTestDataFactory.matter(
            'INTAKE-LOW-CONFIDENCE', client.Id, UserInfo.getUserId(), Date.today().addDays(-60)
        );
        insert matter;
        Automatic_Intake__c intake = new Automatic_Intake__c(
            Email_Message_Id__c = 'low-confidence-test',
            Status__c = 'Needs Review',
            Classification__c = 'Treatment',
            Review_Reason__c = 'Awaiting extraction'
        );
        insert intake;

        AutomaticIntakeService.ExtractedPayload payload = new AutomaticIntakeService.ExtractedPayload();
        payload.intakeId = intake.Id;
        payload.documentType = 'Treatment';
        payload.confidence = 0.62;
        payload.matterId = matter.Id;
        payload.matterMatchUnambiguous = true;
        payload.treatmentDate = Date.today().addDays(-2);
        payload.treatmentStatus = 'Completed';

        AutomaticIntakeService.ApplyResult result =
            AutomaticIntakeService.applyValidatedPayload(payload);
        Automatic_Intake__c saved = [
            SELECT Status__c, Review_Reason__c
            FROM Automatic_Intake__c WHERE Id = :intake.Id
        ];
        System.assertEquals(false, result.applied);
        System.assertEquals(true, result.needsReview);
        System.assertEquals('Needs Review', saved.Status__c);
        System.assert(saved.Review_Reason__c.contains('confidence'));
        System.assertEquals(0, [SELECT COUNT() FROM Treatment_Event__c WHERE Matter__c = :matter.Id]);
    }

    @IsTest
    static void highConfidenceTreatmentCreatesExistingTreatmentEvent() {
        FollowUpTestDataFactory.useDefaultConfig();
        Contact client = FollowUpTestDataFactory.client(null, 'intake-client2@example.com', '5550188');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider(
            'Intake Test Clinic', 'intake-provider@example.com', '5550108'
        );
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter(
            'INTAKE-HIGH-CONFIDENCE', client.Id, UserInfo.getUserId(), Date.today().addDays(-60)
        );
        insert matter;
        Automatic_Intake__c intake = new Automatic_Intake__c(
            Email_Message_Id__c = 'high-confidence-test',
            Status__c = 'Needs Review',
            Classification__c = 'Treatment'
        );
        insert intake;

        AutomaticIntakeService.ExtractedPayload payload = new AutomaticIntakeService.ExtractedPayload();
        payload.intakeId = intake.Id;
        payload.documentType = 'Treatment';
        payload.confidence = 0.97;
        payload.matterId = matter.Id;
        payload.matterMatchUnambiguous = true;
        payload.providerId = provider.Id;
        payload.treatmentDate = Date.today().addDays(-3);
        payload.treatmentStatus = 'Completed';

        Test.startTest();
        AutomaticIntakeService.ApplyResult result =
            AutomaticIntakeService.applyValidatedPayload(payload);
        Test.stopTest();

        System.assertEquals(true, result.applied, result.message);
        System.assertEquals(1, [
            SELECT COUNT() FROM Treatment_Event__c
            WHERE Matter__c = :matter.Id AND Medical_Provider__c = :provider.Id
        ]);
        Automatic_Intake__c saved = [
            SELECT Status__c, Matched_Matter__c, Matched_Provider__c
            FROM Automatic_Intake__c WHERE Id = :intake.Id
        ];
        System.assertEquals('Applied', saved.Status__c);
        System.assertEquals(matter.Id, saved.Matched_Matter__c);
        System.assertEquals(provider.Id, saved.Matched_Provider__c);
    }
}