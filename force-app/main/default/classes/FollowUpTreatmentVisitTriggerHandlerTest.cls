@IsTest
private class FollowUpTreatmentVisitTriggerHandlerTest {
    private static final String VISIT_TYPE = 'Initial';

    private static Id fakeId(Schema.SObjectType objectType, Integer sequence) {
        String prefix = objectType.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(sequence).leftPad(12, '0');
        return (Id) (prefix + suffix);
    }

    @IsTest
    static void insertsQueueableForNewTreatmentVisit() {
        Treatment_Visits__c visitRecord = new Treatment_Visits__c(
            Matter__c = fakeId(Matter__c.SObjectType, 1),
            Medical__c = fakeId(Medical_Provider__c.SObjectType, 1),
            Visit_Start__c = Datetime.now().addDays(-40),
            Visit_End__c = Datetime.now().addDays(-40).addHours(1),
            Visit_Attended__c = true,
            Visit_Type__c = VISIT_TYPE
        );

        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ visitRecord },
            null
        );
        System.assertEquals(1, Limits.getQueueableJobs());
        Test.stopTest();
    }

    @IsTest
    static void doesNotQueueWhenRelevantFieldsDidNotChange() {
        Id recordId = fakeId(Treatment_Visits__c.SObjectType, 1);
        Datetime visitStart = Datetime.now().addDays(-40);
        Treatment_Visits__c oldVisit = new Treatment_Visits__c(
            Id = recordId,
            Matter__c = fakeId(Matter__c.SObjectType, 1),
            Medical__c = fakeId(Medical_Provider__c.SObjectType, 1),
            Visit_Start__c = visitStart,
            Visit_End__c = visitStart.addHours(1),
            Visit_Attended__c = true,
            Visit_Type__c = VISIT_TYPE
        );
        Treatment_Visits__c newVisit = oldVisit.clone(true, false, false, false);

        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ newVisit },
            new Map<Id, Treatment_Visits__c>{ oldVisit.Id => oldVisit }
        );
        System.assertEquals(0, Limits.getQueueableJobs());
        Test.stopTest();
    }

    @IsTest
    static void queuesWhenTreatmentVisitChanges() {
        Id recordId = fakeId(Treatment_Visits__c.SObjectType, 2);
        Datetime visitStart = Datetime.now().addDays(-40);
        Treatment_Visits__c oldVisit = new Treatment_Visits__c(
            Id = recordId,
            Matter__c = fakeId(Matter__c.SObjectType, 1),
            Medical__c = fakeId(Medical_Provider__c.SObjectType, 1),
            Visit_Start__c = visitStart,
            Visit_End__c = visitStart.addHours(1),
            Visit_Attended__c = true,
            Visit_Type__c = VISIT_TYPE
        );
        Treatment_Visits__c newVisit = oldVisit.clone(true, false, false, false);
        newVisit.Visit_Start__c = visitStart.addDays(1);

        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ newVisit },
            new Map<Id, Treatment_Visits__c>{ oldVisit.Id => oldVisit }
        );
        System.assertEquals(1, Limits.getQueueableJobs());
        Test.stopTest();
    }

    @IsTest
    static void bypassPreventsQueueing() {
        Treatment_Visits__c visitRecord = new Treatment_Visits__c(
            Matter__c = fakeId(Matter__c.SObjectType, 1),
            Medical__c = fakeId(Medical_Provider__c.SObjectType, 1),
            Visit_Start__c = Datetime.now().addDays(-40)
        );

        FollowUpTreatmentVisitTriggerHandler.bypass = true;
        Test.startTest();
        FollowUpTreatmentVisitTriggerHandler.afterSave(
            new List<Treatment_Visits__c>{ visitRecord },
            null
        );
        System.assertEquals(0, Limits.getQueueableJobs());
        Test.stopTest();
        FollowUpTreatmentVisitTriggerHandler.bypass = false;
    }
}
