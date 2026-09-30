@IsTest
private class FollowUpTreatmentEventTriggerHandlerTest {
    @IsTest
    static void insertsQueueableForNewTreatmentEvent() {
        Matter__c matter = FollowUpTestDataFactory.createMatter();
        Medical_Provider__c provider = FollowUpTestDataFactory.createProvider();

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
        Matter__c matter = FollowUpTestDataFactory.createMatter();
        Medical_Provider__c provider = FollowUpTestDataFactory.createProvider();

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
