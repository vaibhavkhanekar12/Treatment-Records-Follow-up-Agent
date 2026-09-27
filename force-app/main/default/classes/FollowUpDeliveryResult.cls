/**
 * Outcome of delivering one approved recommendation through an IFollowUpChannel.
 */
public with sharing class FollowUpDeliveryResult {
    public Id recommendationId;
    public Boolean success = false;
    /** Short, user-facing note stored in Delivery_Note__c. */
    public String note;
    /** Task created by the channel itself (manual channels). Null when the send service must log the activity. */
    public Id taskId;

    public FollowUpDeliveryResult(Id recommendationId, Boolean success, String note) {
        this.recommendationId = recommendationId;
        this.success = success;
        this.note = note;
    }
}
