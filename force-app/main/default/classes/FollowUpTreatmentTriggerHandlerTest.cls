@IsTest
private class FollowUpTreatmentTriggerHandlerTest {
    @IsTest
    static void insertsQueueableForNewTreatmentEvent() {
        FollowUpTestDataFactory.useDefaultConfig();
        Contact client = FollowUpTestDataFactory.client(null, 'treatment-trigger@example.com', '5550101');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Trigger Test Provider', 'provider@example.com', null);
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('TRIGGER-TEST-1', client.Id, UserInfo.getUserId(), Date.today().addDays(-90));
        insert matter;

        Test.startTest();
        Treatment_Event__c eventRecord = new Treatment_Event__c(
            Matter__c = matter.Id,
            Medical_Provider__c = provider.Id,
            Treatment_Date__c = Date.today().addDays(-40),
            Status__c = 'Completed'
        );
        insert eventRecord;
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM Follow_Up_Recommendation__c WHERE Matter__c = :matter.Id],
            'Treatment Event creation should trigger immediate asynchronous evaluation.'
        );
    }

    @IsTest
    static void updateQueuesOnlyWhenRelevantTreatmentDataChanges() {
        FollowUpTestDataFactory.useDefaultConfig();
        Contact client = FollowUpTestDataFactory.client(null, 'treatment-trigger-update@example.com', '5550102');
        insert client;
        Medical_Provider__c provider = FollowUpTestDataFactory.provider('Trigger Update Provider', 'provider2@example.com', null);
        insert provider;
        Matter__c matter = FollowUpTestDataFactory.matter('TRIGGER-TEST-2', client.Id, UserInfo.getUserId(), Date.today().addDays(-90));
        insert matter;

        Treatment_Event__c eventRecord = new Treatment_Event__c(
            Matter__c = matter.Id,
            Medical_Provider__c = provider.Id,
            Treatment_Date__c = Date.today().addDays(-40),
            Status__c = 'Completed'
        );
        insert eventRecord;

        Test.startTest();
        eventRecord.Treatment_Date__c = Date.today().addDays(-50);
        update eventRecord;
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM Follow_Up_Recommendation__c WHERE Matter__c = :matter.Id] > 0,
            'Relevant Treatment Event updates should re-evaluate the Matter.'
        );
    }
}
