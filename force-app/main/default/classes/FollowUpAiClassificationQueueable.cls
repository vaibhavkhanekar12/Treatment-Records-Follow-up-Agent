/**
 * Classifies inbound responses with the configured AI classifier after they were saved as
 * Pending_Classification (an LLM call cannot follow uncommitted DML in the logging transaction).
 * Invalid, low-quality or failed AI output falls back to the deterministic keyword classifier, and the
 * next action is always applied from Response_Classification_Rule__mdt.
 */
public with sharing class FollowUpAiClassificationQueueable implements Queueable, Database.AllowsCallouts {
    private final Set<Id> recommendationIds;

    public FollowUpAiClassificationQueueable(Set<Id> recommendationIds) {
        this.recommendationIds = recommendationIds;
    }

    public void execute(QueueableContext context) {
        List<Follow_Up_Recommendation__c> pending = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : FollowUpRecommendationService.query(recommendationIds, AccessLevel.SYSTEM_MODE)) {
            if (rec.Response_Classification__c == FollowUpConstants.CATEGORY_PENDING && String.isNotBlank(rec.Response_Text__c)) {
                pending.add(rec);
            }
        }
        if (pending.isEmpty()) {
            return;
        }
        List<FollowUpClassification.Request> requests = new List<FollowUpClassification.Request>();
        for (Follow_Up_Recommendation__c rec : pending) {
            requests.add(new FollowUpClassification.Request(rec.Id, rec.Response_Text__c, rec.Audience__c));
        }

        Map<Id, FollowUpClassification> accepted = new Map<Id, FollowUpClassification>();
        IFollowUpResponseClassifier classifier = FollowUpResponseService.resolveAiClassifier();
        Set<String> allowed = FollowUpResponseService.allowedCategories();
        if (classifier != null) {
            try {
                for (FollowUpClassification result : classifier.classify(requests)) {
                    if (
                        result != null &&
                        allowed.contains(result.category) &&
                        result.confidence != null &&
                        result.confidence >= 0 &&
                        result.confidence <= 1
                    ) {
                        result.source = 'AI';
                        accepted.put(result.recommendationId, result);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'AI classification failed; using keyword fallback: ' + e.getMessage());
            }
        }
        List<FollowUpClassification.Request> fallback = new List<FollowUpClassification.Request>();
        for (FollowUpClassification.Request request : requests) {
            if (!accepted.containsKey(request.recommendationId)) {
                fallback.add(request);
            }
        }
        for (FollowUpClassification result : new FollowUpKeywordClassifier().classify(fallback)) {
            accepted.put(result.recommendationId, result);
        }
        // Inbound activity was already logged when the response was received; only classify and act here.
        FollowUpResponseService.applyClassificationsOnly(pending, accepted);
    }
}
