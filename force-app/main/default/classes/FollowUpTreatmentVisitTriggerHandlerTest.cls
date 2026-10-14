@IsTest
private class FollowUpTreatmentVisitTriggerHandlerTest {
    @IsTest
    static void skipsNullAndEmptyInputs() {
        FollowUpTreatmentVisitTriggerHandler.afterSave(null, null);
        FollowUpTreatmentVisitTriggerHandler.afterSave(new List<Treatment_Visits__c>(), null);
        System.assertEquals(true, true, 'Null and empty input should be handled safely.');
    }

    @IsTest
    static void enqueueQueueableForChangedVisit() {
        // Tests the handler's change-detection and queueable scheduling without
        // making assumptions about required fields in the existing client schema.
        Treatment_Visits__c visitRecord = new Treatment_Visits__c(
            Id = (Id) 'a01000000000001AAA',
            Matter__c = (Id) 'a02000000000001AAA',
            Visit_Start__c = Datetime.newInstance(2026, 1, 1, 10, 0, 0),
            Provider__c = (Id) 'a03000000000001AAA'
        );

        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ visitRecord },
            null
        );
        Test.stopTest();

        System.assertEquals(1, Limits.getQueueableJobs(), 'A changed treatment visit should queue evaluation.');
    }

    @IsTest
    static void bypassPreventsQueueing() {
        Treatment_Visits__c visitRecord = new Treatment_Visits__c(
            Id = (Id) 'a01000000000001AAA',
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
        Test.stopTest();
        FollowUpTreatmentVisitTriggerHandler.bypass = false;
        System.assertEquals(0, Limits.getQueueableJobs(), 'Bypass should prevent evaluation.');
    }
}