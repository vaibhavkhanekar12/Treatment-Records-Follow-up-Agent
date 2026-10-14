@IsTest
private class FollowUpTreatmentVisitTriggerHandlerTest {
    @IsTest
    static void ignoresNullOrEmptyInput() {
        FollowUpTreatmentVisitTriggerHandler.afterSave(null, null);
        FollowUpTreatmentVisitTriggerHandler.afterSave(new List<Treatment_Visits__c>(), null);
        System.assertEquals(0, Limits.getQueueableJobs());
    }

    @IsTest
    static void enqueuesEvaluationForInsertedVisit() {
        // Only the lookup is needed to exercise handler change detection; no record is persisted.
        Treatment_Visits__c visitRecord = new Treatment_Visits__c(
            Matter__c = (Id) 'a02000000000001AAA',
            Visit_Start__c = Datetime.newInstance(2026, 1, 1, 10, 0, 0),
            Provider__c = (Id) 'a03000000000001AAA'
        );

        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ visitRecord },
            null
        );
        System.assertEquals(1, Limits.getQueueableJobs(), 'An inserted visit should schedule matter evaluation.');
        Test.stopTest();
    }

    @IsTest
    static void bypassPreventsQueueing() {
        Treatment_Visits__c visitRecord = new Treatment_Visits__c(
            Matter__c = (Id) 'a02000000000001AAA',
            Visit_Start__c = Datetime.newInstance(2026, 1, 1, 10, 0, 0),
            Provider__c = (Id) 'a03000000000001AAA'
        );
        FollowUpTreatmentVisitTriggerHandler.bypass = true;
        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ visitRecord },
            null
        );
        System.assertEquals(0, Limits.getQueueableJobs(), 'Bypass should suppress queueing.');
        Test.stopTest();
        FollowUpTreatmentVisitTriggerHandler.bypass = false;
    }
}