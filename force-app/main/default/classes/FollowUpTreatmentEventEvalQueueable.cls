/**
 * Evaluates matters asynchronously after Treatment Event changes.
 * Keeps Treatment Event trigger work lightweight and bulk-safe.
 */
public without sharing class FollowUpTreatmentEventEvalQueueable implements Queueable {
    private final Set<Id> matterIds;

    public FollowUpTreatmentEventEvalQueueable(Set<Id> matterIds) {
        this.matterIds = matterIds == null ? new Set<Id>() : new Set<Id>(matterIds);
    }

    public void execute(QueueableContext context) {
        if (matterIds.isEmpty()) {
            return;
        }
        FollowUpEvaluationService.evaluate(
            matterIds,
            'TREATMENT-EVENT-' + String.valueOf(context.getJobId())
        );
    }
}
