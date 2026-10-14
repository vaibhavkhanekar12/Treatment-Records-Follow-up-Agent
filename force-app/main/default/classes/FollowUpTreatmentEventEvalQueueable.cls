/**
 * Retired compatibility queueable for the legacy Treatment Event source.
 * Production evaluation is triggered by TreatmentVisitsTrigger on Treatment_Visits__c.
 */
public without sharing class FollowUpTreatmentEventEvalQueueable implements Queueable {
    public void execute(QueueableContext context) {
        // Intentionally no-op. Use FollowUpTreatmentVisitEvalQueueable instead.
    }
}