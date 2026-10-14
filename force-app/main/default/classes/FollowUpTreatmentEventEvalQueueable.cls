/**
 * Compatibility wrapper retained for source compatibility.
 * It delegates directly to the Treatment Visits implementation and does not reference Treatment_Event__c.
 */
public without sharing class FollowUpTreatmentEventEvalQueueable implements Queueable {
    private final Set<Id> matterIds;

    public FollowUpTreatmentEventEvalQueueable(Set<Id> matterIds) {
        this.matterIds = matterIds == null ? new Set<Id>() : new Set<Id>(matterIds);
    }

    public void execute(QueueableContext context) {
        if (!matterIds.isEmpty()) {
            System.enqueueJob(new FollowUpTreatmentVisitEvalQueueable(matterIds));
        }
    }
}
