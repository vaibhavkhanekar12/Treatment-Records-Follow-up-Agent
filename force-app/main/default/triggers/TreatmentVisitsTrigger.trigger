trigger TreatmentVisitsTrigger on Treatment_Visits__c (after insert, after update) {
    FollowUpTreatmentVisitTriggerHandler.afterSave(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}