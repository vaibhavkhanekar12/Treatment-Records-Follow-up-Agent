/**
 * IFollowUpResponseClassifier backed by the Follow_Up_Inbound_Classification prompt template, which returns
 * {"category": "<one configured category>", "confidence": 0-1, "summary": "<neutral sentence>"}.
 * Register via Follow_Up_Setting__mdt.Default.Response_Classifier_Class__c = FollowUpEinsteinClassifier.
 * Runs inside FollowUpAiClassificationQueueable; invalid output is discarded there and the keyword
 * classifier is used instead. The next action is always deterministic (Response_Classification_Rule__mdt).
 */
public with sharing class FollowUpEinsteinClassifier implements IFollowUpResponseClassifier {
    public static final String TEMPLATE = 'Follow_Up_Inbound_Classification';

    public List<FollowUpClassification> classify(List<FollowUpClassification.Request> requests) {
        List<FollowUpClassification> results = new List<FollowUpClassification>();
        for (FollowUpClassification.Request request : requests) {
            try {
                FollowUpClassification result = parse(
                    request.recommendationId,
                    FollowUpEinsteinDraftGenerator.invoke(TEMPLATE, request.recommendationId)
                );
                if (result != null) {
                    results.add(result);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'AI classification failed for ' + request.recommendationId + ': ' + e.getMessage());
            }
        }
        return results;
    }

    @TestVisible
    private static FollowUpClassification parse(Id recommendationId, String raw) {
        Map<String, Object> payload = FollowUpEinsteinDraftGenerator.parseJsonObject(raw);
        if (payload == null || !(payload.get('category') instanceof String)) {
            return null;
        }
        Decimal confidence;
        Object rawConfidence = payload.get('confidence');
        if (rawConfidence instanceof Decimal) {
            confidence = (Decimal) rawConfidence;
        } else if (rawConfidence instanceof Integer) {
            confidence = (Integer) rawConfidence;
        } else if (rawConfidence instanceof Double) {
            confidence = Decimal.valueOf((Double) rawConfidence);
        }
        FollowUpClassification result = new FollowUpClassification(recommendationId, (String) payload.get('category'), confidence, 'AI');
        result.summary = payload.get('summary') instanceof String ? (String) payload.get('summary') : null;
        return result;
    }
}
