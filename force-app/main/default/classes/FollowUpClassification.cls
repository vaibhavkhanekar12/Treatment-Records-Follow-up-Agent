/**
 * Classification of an inbound client/provider response. Categories are operational, never legal.
 */
public with sharing class FollowUpClassification {
    public Id recommendationId;
    /** Response_Classification__c API value. */
    public String category;
    /** 0..1 */
    public Decimal confidence;
    /** Short neutral summary of the response (optional). */
    public String summary;
    /** Keyword, AI or Human. */
    public String source;

    public FollowUpClassification(Id recommendationId, String category, Decimal confidence, String source) {
        this.recommendationId = recommendationId;
        this.category = category;
        this.confidence = confidence;
        this.source = source;
    }

    /** Input to a classifier. */
    public class Request {
        public Id recommendationId;
        public String text;
        /** Client or Provider (blank = unknown). */
        public String audience;

        public Request(Id recommendationId, String text, String audience) {
            this.recommendationId = recommendationId;
            this.text = text;
            this.audience = audience;
        }
    }
}
