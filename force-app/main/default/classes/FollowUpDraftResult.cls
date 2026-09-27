/**
 * Output of an IFollowUpDraftGenerator for one recommendation.
 */
public with sharing class FollowUpDraftResult {
    public Id recommendationId;
    public Boolean success = false;
    public String subject;
    public String message;
    public String rationale;
    /** Template or AI (Follow_Up_Recommendation__c.Draft_Source__c). */
    public String source;
    public String error;

    public FollowUpDraftResult(Id recommendationId) {
        this.recommendationId = recommendationId;
    }
}
