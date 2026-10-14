/**
 * Evaluates affected Matters asynchronously after Treatment Visit changes.
 */
public without sharing class FollowUpTreatmentVisitEvalQueueable implements Queueable {
    private final Set<Id> matterIds;

    public FollowUpTreatmentVisitEvalQueueable(Set<Id> matterIds) {
        this.matterIds = matterIds == null ? new Set<Id>() : new Set<Id>(matterIds);
    }

    public void execute(QueueableContext context) {
        if (matterIds.isEmpty()) {
            return;
        }
        FollowUpEvaluationService.evaluate(
            matterIds,
            'TREATMENT-VISIT-' + String.valueOf(context.getJobId())
        );
    }
}
