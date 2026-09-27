/**
 * Logs inbound client/provider responses, classifies them and applies the deterministic next action.
 *
 * Classification source, in order of preference:
 *  1. a category supplied by a person (work queue) or by the Agentforce agent (validated against the
 *     configured categories);
 *  2. the configured AI classifier, run asynchronously (FollowUpAiClassificationQueueable) because LLM
 *     calls cannot follow uncommitted DML in the same transaction;
 *  3. the keyword classifier (synchronous, deterministic).
 *
 * The next action always comes from Response_Classification_Rule__mdt, and any classification below
 * Classification_Confidence_Threshold__c goes to case-manager review. Classification is operational,
 * never legal: it never changes matter data other than follow-up records and activity history.
 */
public with sharing class FollowUpResponseService {
    public class ResponseInput {
        public Id recommendationId;
        public Id matterId;
        public String responseText;
        /** Email, SMS, Phone, Fax, Portal, ... (free text, used in the activity subject). */
        public String source;
        /** Client or Provider; used to pick the recommendation when only a matter is supplied. */
        public String audience;
        /** Optional pre-classified category (person or agent). */
        public String category;
        /** Optional 0..1 confidence for a supplied category; defaults to 1 (human-confirmed). */
        public Decimal confidence;
    }

    public class ResponseResult {
        public Id recommendationId;
        @AuraEnabled
        public String recommendationName;
        @AuraEnabled
        public String category;
        @AuraEnabled
        public Decimal confidence;
        @AuraEnabled
        public String nextAction;
        @AuraEnabled
        public Boolean reviewCreated = false;
        @AuraEnabled
        public Boolean pendingAiClassification = false;
    }

    @TestVisible
    private static IFollowUpResponseClassifier aiClassifierOverride;

    public static List<ResponseResult> logResponses(List<ResponseInput> inputs) {
        Set<String> allowed = allowedCategories();
        for (ResponseInput input : inputs) {
            // Validate before resolveTargets, which may insert holder records.
            if (input != null && String.isNotBlank(input.category) && !allowed.contains(input.category)) {
                throw new FollowUpException(String.format(Label.FollowUp_Error_Invalid_Category, new List<String>{ input.category }));
            }
        }
        Map<String, Follow_Up_Recommendation__c> targets = resolveTargets(inputs);
        Map<Id, Follow_Up_Recommendation__c> uniqueTargets = new Map<Id, Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : targets.values()) {
            uniqueTargets.put(rec.Id, rec);
        }
        Boolean aiConfigured = resolveAiClassifier() != null;

        Map<Id, FollowUpClassification> classifications = new Map<Id, FollowUpClassification>();
        List<FollowUpClassification.Request> keywordRequests = new List<FollowUpClassification.Request>();
        Set<Id> pendingAi = new Set<Id>();
        Map<Id, String> sources = new Map<Id, String>();

        for (Integer i = 0; i < inputs.size(); i++) {
            ResponseInput input = inputs[i];
            Follow_Up_Recommendation__c rec = targets.get(targetKey(input, i));
            rec.Response_Received__c = true;
            rec.Response_Received_Date__c = System.now();
            rec.Response_Text__c = input.responseText.left(5000);
            sources.put(rec.Id, String.isBlank(input.source) ? 'Response' : input.source.left(40));
            if (String.isNotBlank(input.category)) {
                Decimal confidence = input.confidence == null ? 1 : Math.min(Math.max(input.confidence, 0), 1);
                classifications.put(rec.Id, new FollowUpClassification(rec.Id, input.category, confidence, 'Human'));
            } else if (aiConfigured) {
                pendingAi.add(rec.Id);
                rec.Response_Classification__c = FollowUpConstants.CATEGORY_PENDING;
            } else {
                keywordRequests.add(new FollowUpClassification.Request(rec.Id, input.responseText, rec.Audience__c));
            }
        }
        for (FollowUpClassification classification : new FollowUpKeywordClassifier().classify(keywordRequests)) {
            classifications.put(classification.recommendationId, classification);
        }

        Map<Id, ResponseResult> byRecommendation = new Map<Id, ResponseResult>();
        for (ResponseResult result : applyAndSave(uniqueTargets.values(), classifications, sources)) {
            byRecommendation.put(result.recommendationId, result);
        }
        if (!pendingAi.isEmpty()) {
            System.enqueueJob(new FollowUpAiClassificationQueueable(pendingAi));
            for (Follow_Up_Recommendation__c rec : uniqueTargets.values()) {
                if (pendingAi.contains(rec.Id)) {
                    ResponseResult result = new ResponseResult();
                    result.recommendationId = rec.Id;
                    result.recommendationName = rec.Name;
                    result.category = FollowUpConstants.CATEGORY_PENDING;
                    result.pendingAiClassification = true;
                    byRecommendation.put(rec.Id, result);
                }
            }
        }
        // One result per input, in input order (several inputs may share a recommendation).
        List<ResponseResult> results = new List<ResponseResult>();
        for (Integer i = 0; i < inputs.size(); i++) {
            results.add(byRecommendation.get(targets.get(targetKey(inputs[i], i)).Id));
        }
        return results;
    }

    /** Keyword suggestion for the work-queue "Log response" form (the person confirms or changes it). */
    public static FollowUpClassification suggest(String text, String audience) {
        return new FollowUpKeywordClassifier()
            .classify(new List<FollowUpClassification.Request>{ new FollowUpClassification.Request(null, text, audience) })[0];
    }

    public static IFollowUpResponseClassifier resolveAiClassifier() {
        if (aiClassifierOverride != null) {
            return aiClassifierOverride;
        }
        String className = FollowUpConfig.getSetting().Response_Classifier_Class__c;
        if (String.isBlank(className)) {
            return null;
        }
        Type classifierType = Type.forName(className.trim());
        Object instance = classifierType == null ? null : classifierType.newInstance();
        return instance instanceof IFollowUpResponseClassifier ? (IFollowUpResponseClassifier) instance : null;
    }

    public static Set<String> allowedCategories() {
        Set<String> categories = new Set<String>();
        for (Response_Classification_Rule__mdt rule : FollowUpConfig.getClassificationRules()) {
            categories.add(rule.Category__c);
        }
        categories.add(FollowUpConstants.CATEGORY_UNCLEAR);
        return categories;
    }

    /**
     * Records the classification on each recommendation, applies the configured next action, creates
     * case-manager review recommendations where required, logs the inbound activity, and saves.
     */
    public static List<ResponseResult> applyAndSave(
        List<Follow_Up_Recommendation__c> recs,
        Map<Id, FollowUpClassification> classifications,
        Map<Id, String> sources
    ) {
        return apply(recs, classifications, sources, true);
    }

    /** Used by the asynchronous AI path: the inbound activity was already logged when the response arrived. */
    public static List<ResponseResult> applyClassificationsOnly(
        List<Follow_Up_Recommendation__c> recs,
        Map<Id, FollowUpClassification> classifications
    ) {
        return apply(recs, classifications, null, false);
    }

    private static List<ResponseResult> apply(
        List<Follow_Up_Recommendation__c> recs,
        Map<Id, FollowUpClassification> classifications,
        Map<Id, String> sources,
        Boolean logActivity
    ) {
        Decimal threshold = FollowUpConfig.classificationThreshold();
        List<ResponseResult> results = new List<ResponseResult>();
        List<Follow_Up_Recommendation__c> reviews = new List<Follow_Up_Recommendation__c>();
        List<Task> activities = new List<Task>();

        for (Follow_Up_Recommendation__c rec : recs) {
            FollowUpClassification classification = classifications.get(rec.Id);
            String source = sources == null || !sources.containsKey(rec.Id) ? 'Response' : sources.get(rec.Id);
            if (classification == null) {
                activities.add(inboundActivity(rec, source, FollowUpConstants.CATEGORY_PENDING));
                continue;
            }
            rec.Response_Classification__c = classification.category;
            rec.Classification_Confidence__c = classification.confidence == null ? 0 : (classification.confidence * 100).setScale(2);

            Response_Classification_Rule__mdt rule = FollowUpConfig.getClassificationRule(classification.category);
            String action = rule == null ? FollowUpConstants.ACTION_CASE_MANAGER_REVIEW : rule.Next_Action__c;
            Boolean confident = classification.confidence != null && classification.confidence >= threshold;
            if (!confident) {
                action = FollowUpConstants.ACTION_CASE_MANAGER_REVIEW;
            }

            ResponseResult result = new ResponseResult();
            result.recommendationId = rec.Id;
            result.recommendationName = rec.Name;
            result.category = classification.category;
            result.confidence = classification.confidence;
            result.nextAction = action;

            if (rec.Recommendation_Type__c != FollowUpConstants.TYPE_INBOUND_REVIEW) {
                if (rec.Status__c == FollowUpConstants.STATUS_SENT) {
                    rec.Status__c = FollowUpConstants.STATUS_COMPLETED;
                    rec.Closed_Date__c = System.now();
                }
                // A confident category may pause the same follow-up (e.g. "stopped treatment" while the case manager reviews).
                if (confident && rule != null && rule.Recheck_Days__c != null) {
                    rec.Next_Follow_Up_Date__c = Date.today().addDays(rule.Recheck_Days__c.intValue());
                }
                if (action == FollowUpConstants.ACTION_CASE_MANAGER_REVIEW) {
                    reviews.add(reviewFor(rec, classification));
                    result.reviewCreated = true;
                }
            }
            activities.add(inboundActivity(rec, source, classification.category));
            results.add(result);
        }

        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : recs) {
            updates.add(
                new Follow_Up_Recommendation__c(
                    Id = rec.Id,
                    Status__c = rec.Status__c,
                    Closed_Date__c = rec.Closed_Date__c,
                    Next_Follow_Up_Date__c = rec.Next_Follow_Up_Date__c,
                    Response_Received__c = rec.Response_Received__c,
                    Response_Received_Date__c = rec.Response_Received_Date__c,
                    Response_Text__c = rec.Response_Text__c,
                    Response_Classification__c = rec.Response_Classification__c,
                    Classification_Confidence__c = rec.Classification_Confidence__c
                )
            );
        }
        Database.update(updates, true, AccessLevel.SYSTEM_MODE);
        if (!reviews.isEmpty()) {
            // allOrNone=false: a second response to the same recommendation must not fail on the unique Active_Key__c.
            Database.insert(reviews, false, AccessLevel.SYSTEM_MODE);
        }
        if (logActivity && !activities.isEmpty()) {
            Database.insert(activities, true, AccessLevel.SYSTEM_MODE);
        }
        return results;
    }

    private static Follow_Up_Recommendation__c reviewFor(Follow_Up_Recommendation__c rec, FollowUpClassification classification) {
        return new Follow_Up_Recommendation__c(
            Matter__c = rec.Matter__c,
            Recommendation_Type__c = FollowUpConstants.TYPE_INBOUND_REVIEW,
            Rule__c = FollowUpConstants.SOURCE_INBOUND,
            Status__c = FollowUpConstants.STATUS_PENDING_REVIEW,
            Priority__c = FollowUpConstants.PRIORITY_HIGH,
            Audience__c = FollowUpConstants.AUDIENCE_INTERNAL,
            Channel__c = FollowUpConstants.CHANNEL_TASK,
            Related_Recommendation__c = rec.Id,
            Assigned_To__c = rec.Assigned_To__c,
            Recipient_Contact__c = rec.Recipient_Contact__c,
            Medical_Provider__c = rec.Medical_Provider__c,
            Records_Request__c = rec.Records_Request__c,
            Recommended_Date__c = Date.today(),
            Dedupe_Key__c = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_INBOUND_REVIEW, rec.Id),
            Response_Text__c = rec.Response_Text__c,
            Response_Received__c = true,
            Response_Received_Date__c = rec.Response_Received_Date__c,
            Response_Classification__c = classification.category,
            Classification_Confidence__c = rec.Classification_Confidence__c,
            Reason__c = FollowUpRuleEngine.format(
                Label.FollowUp_Reason_Inbound_Review,
                new List<Object>{ rec.Audience__c, rec.Name, categoryLabel(classification.category), rec.Classification_Confidence__c }
            )
        );
    }

    private static Task inboundActivity(Follow_Up_Recommendation__c rec, String source, String category) {
        return new Task(
            WhatId = rec.Matter__c,
            WhoId = rec.Audience__c == FollowUpConstants.AUDIENCE_CLIENT ? rec.Recipient_Contact__c : null,
            OwnerId = UserInfo.getUserId(),
            Subject = ('Inbound response (' + source + '): ' + categoryLabel(category)).left(255),
            Description = rec.Response_Text__c,
            ActivityDate = Date.today(),
            Status = 'Completed'
        );
    }

    public static String categoryLabel(String category) {
        for (Schema.PicklistEntry entry : Follow_Up_Recommendation__c.Response_Classification__c.getDescribe().getPicklistValues()) {
            if (entry.getValue() == category) {
                return entry.getLabel();
            }
        }
        return category;
    }

    /**
     * Resolves each input to a recommendation the user may edit. Matter-only input attaches to the most
     * recently sent external recommendation for that matter (optionally of the given audience); if none
     * exists an Inbound Response Review recommendation is created to hold the response.
     */
    private static Map<String, Follow_Up_Recommendation__c> resolveTargets(List<ResponseInput> inputs) {
        Set<Id> recIds = new Set<Id>();
        Set<Id> matterIds = new Set<Id>();
        for (ResponseInput input : inputs) {
            if (input == null || String.isBlank(input.responseText)) {
                throw new FollowUpException(Label.FollowUp_Error_Response_Required);
            }
            if (input.recommendationId != null) {
                recIds.add(input.recommendationId);
            } else if (input.matterId != null) {
                matterIds.add(input.matterId);
            } else {
                throw new FollowUpException(Label.FollowUp_Error_Matter_Not_Found);
            }
        }

        Map<Id, Follow_Up_Recommendation__c> byRecId = new Map<Id, Follow_Up_Recommendation__c>();
        if (!recIds.isEmpty()) {
            byRecId.putAll(FollowUpRecommendationService.loadForAction(recIds));
        }
        Map<Id, List<Follow_Up_Recommendation__c>> sentByMatter = new Map<Id, List<Follow_Up_Recommendation__c>>();
        if (!matterIds.isEmpty()) {
            if (!FollowUpSecurity.readableMatters(matterIds, null).keySet().containsAll(matterIds)) {
                throw new FollowUpException(Label.FollowUp_Error_Matter_Not_Found);
            }
            sentByMatter = latestSentByMatter(matterIds);
        }

        Map<String, Follow_Up_Recommendation__c> targets = new Map<String, Follow_Up_Recommendation__c>();
        List<Follow_Up_Recommendation__c> holders = new List<Follow_Up_Recommendation__c>();
        Map<Integer, Follow_Up_Recommendation__c> holderByIndex = new Map<Integer, Follow_Up_Recommendation__c>();
        Set<Id> attachedIds = new Set<Id>();
        for (Integer i = 0; i < inputs.size(); i++) {
            ResponseInput input = inputs[i];
            if (input.recommendationId != null) {
                targets.put(targetKey(input, i), byRecId.get(input.recommendationId));
                continue;
            }
            Follow_Up_Recommendation__c match = null;
            for (
                Follow_Up_Recommendation__c candidate : sentByMatter.containsKey(input.matterId)
                    ? sentByMatter.get(input.matterId)
                    : new List<Follow_Up_Recommendation__c>()
            ) {
                if (String.isBlank(input.audience) || candidate.Audience__c == input.audience) {
                    match = candidate;
                    break;
                }
            }
            if (match != null) {
                targets.put(targetKey(input, i), match);
                attachedIds.add(match.Id);
            } else {
                Follow_Up_Recommendation__c holder = new Follow_Up_Recommendation__c(
                    Matter__c = input.matterId,
                    Recommendation_Type__c = FollowUpConstants.TYPE_INBOUND_REVIEW,
                    Rule__c = FollowUpConstants.SOURCE_INBOUND,
                    Status__c = FollowUpConstants.STATUS_PENDING_REVIEW,
                    Priority__c = FollowUpConstants.PRIORITY_HIGH,
                    Audience__c = FollowUpConstants.AUDIENCE_INTERNAL,
                    Channel__c = FollowUpConstants.CHANNEL_TASK,
                    Recommended_Date__c = Date.today(),
                    Assigned_To__c = UserInfo.getUserId(),
                    Reason__c = Label.FollowUp_Reason_Unmatched_Response
                );
                holders.add(holder);
                holderByIndex.put(i, holder);
            }
        }
        if (!attachedIds.isEmpty()) {
            FollowUpSecurity.requireEditAccess(attachedIds);
        }
        if (!holders.isEmpty()) {
            Database.insert(holders, true, AccessLevel.SYSTEM_MODE);
            Map<Id, Follow_Up_Recommendation__c> reloaded = new Map<Id, Follow_Up_Recommendation__c>(
                FollowUpRecommendationService.query(new Map<Id, Follow_Up_Recommendation__c>(holders).keySet(), AccessLevel.SYSTEM_MODE)
            );
            for (Integer index : holderByIndex.keySet()) {
                targets.put(targetKey(inputs[index], index), reloaded.get(holderByIndex.get(index).Id));
            }
        }
        return targets;
    }

    private static Map<Id, List<Follow_Up_Recommendation__c>> latestSentByMatter(Set<Id> matterIds) {
        Map<Id, List<Follow_Up_Recommendation__c>> byMatter = new Map<Id, List<Follow_Up_Recommendation__c>>();
        List<Follow_Up_Recommendation__c> sent = Database.queryWithBinds(
            'SELECT ' +
                FollowUpRecommendationService.RECOMMENDATION_FIELDS +
                ' FROM Follow_Up_Recommendation__c WHERE Matter__c IN :matterIds AND Status__c IN :sentStatuses' +
                ' AND Sent_Date__c != null AND Response_Received__c = false' +
                ' AND Audience__c IN :audiences ORDER BY Sent_Date__c DESC',
            new Map<String, Object>{
                'matterIds' => matterIds,
                'sentStatuses' => new Set<String>{ FollowUpConstants.STATUS_SENT, FollowUpConstants.STATUS_COMPLETED },
                'audiences' => FollowUpConstants.EXTERNAL_AUDIENCES
            },
            AccessLevel.USER_MODE
        );
        for (Follow_Up_Recommendation__c rec : sent) {
            if (!byMatter.containsKey(rec.Matter__c)) {
                byMatter.put(rec.Matter__c, new List<Follow_Up_Recommendation__c>());
            }
            byMatter.get(rec.Matter__c).add(rec);
        }
        return byMatter;
    }

    /** Several inputs may target the same recommendation; the last response wins. */
    private static String targetKey(ResponseInput input, Integer index) {
        return input.recommendationId != null ? String.valueOf(input.recommendationId) : 'input-' + index;
    }
}
