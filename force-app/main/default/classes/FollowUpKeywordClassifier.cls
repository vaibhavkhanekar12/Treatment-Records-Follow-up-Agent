/**
 * Deterministic fallback classifier driven by Response_Classification_Rule__mdt keywords.
 * Rules are evaluated by Sort_Order__c; the first matching rule wins. Matching is case-insensitive and
 * whole-phrase ("stop" does not match "stopped"). No match -> Unclear with confidence 0, which always
 * routes the response to case-manager review.
 */
public with sharing class FollowUpKeywordClassifier implements IFollowUpResponseClassifier {
    /** Confidence assigned to a keyword match; below-threshold settings force human review. */
    @TestVisible
    private static final Decimal KEYWORD_CONFIDENCE = 0.8;

    public List<FollowUpClassification> classify(List<FollowUpClassification.Request> requests) {
        List<FollowUpClassification> results = new List<FollowUpClassification>();
        List<Response_Classification_Rule__mdt> rules = FollowUpConfig.getClassificationRules();
        for (FollowUpClassification.Request request : requests) {
            results.add(classifyOne(request, rules));
        }
        return results;
    }

    private static FollowUpClassification classifyOne(
        FollowUpClassification.Request request,
        List<Response_Classification_Rule__mdt> rules
    ) {
        String text = normalize(request.text);
        if (String.isNotBlank(text)) {
            for (Response_Classification_Rule__mdt rule : rules) {
                if (!appliesTo(rule, request.audience) || String.isBlank(rule.Keywords__c)) {
                    continue;
                }
                for (String keyword : FollowUpConfig.splitCsv(rule.Keywords__c)) {
                    if (matches(text, normalize(keyword), rule.Match_Type__c == 'Exact')) {
                        return new FollowUpClassification(request.recommendationId, rule.Category__c, KEYWORD_CONFIDENCE, 'Keyword');
                    }
                }
            }
        }
        return new FollowUpClassification(request.recommendationId, FollowUpConstants.CATEGORY_UNCLEAR, 0, 'Keyword');
    }

    private static Boolean appliesTo(Response_Classification_Rule__mdt rule, String audience) {
        return String.isBlank(audience) || String.isBlank(rule.Audience__c) || rule.Audience__c == 'Any' || rule.Audience__c == audience;
    }

    private static Boolean matches(String text, String keyword, Boolean exact) {
        if (String.isBlank(keyword)) {
            return false;
        }
        if (exact) {
            return text == keyword;
        }
        return Pattern.compile('(?<![a-z0-9])' + Pattern.quote(keyword) + '(?![a-z0-9])').matcher(text).find();
    }

    /** Lower-case, typographic apostrophes normalised, trailing punctuation and extra whitespace removed. */
    @TestVisible
    private static String normalize(String value) {
        if (value == null) {
            return null;
        }
        String normalized = value.toLowerCase().replace('’', '\'').normalizeSpace();
        return normalized.replaceAll('[.!?,;:]+$', '').trim();
    }
}
