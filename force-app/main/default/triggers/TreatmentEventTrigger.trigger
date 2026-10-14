/**
 * Legacy trigger retained as a no-op for transition purposes.
 * TreatmentVisitsTrigger on Treatment_Visits__c is the active implementation.
 */
trigger TreatmentEventTrigger on Treatment_Event__c (after insert, after update) {
    // Intentionally no-op.
}