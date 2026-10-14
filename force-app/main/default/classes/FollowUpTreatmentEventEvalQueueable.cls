/**
 * Retired compatibility class for orgs that still have the old Treatment Event metadata.
 * Follow-up evaluation is now triggered from Treatment Visits.
 */
public without sharing class FollowUpTreatmentEventEvalQueueable implements Queueable {
    public void execute(QueueableContext context) {
        // No-op. FollowUpTreatmentVisitEvalQueueable is the active implementation.
    }
}