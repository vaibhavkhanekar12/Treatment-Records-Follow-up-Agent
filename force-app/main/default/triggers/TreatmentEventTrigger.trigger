/**
 * Retired trigger for the legacy Treatment Event object.
 * The active implementation is TreatmentVisitsTrigger on Treatment_Visits__c.
 */
trigger TreatmentEventTrigger on Treatment_Event__c (after insert, after update) {
    // Intentionally no-op; do not use this trigger in the production deployment.
}