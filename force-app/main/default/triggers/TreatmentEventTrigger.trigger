trigger TreatmentEventTrigger on Treatment_Event__c (after insert, after update) {
    FollowUpTreatmentTriggerHandler.afterSave(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}
