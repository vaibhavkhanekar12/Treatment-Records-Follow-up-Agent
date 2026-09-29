/**
 * Prompt Builder grounding (Apex data provider) for the Treatment & Records Follow-up prompt templates.
 * Every template takes one input, "recommendation" (Follow_Up_Recommendation__c), and merges
 * {!$Apex:FollowUpPromptFacts.Prompt}: verified facts only, no record Ids, no clinical data, client first
 * name only, date of birth replaced by a placeholder (see FollowUpFactsBuilder).
 *
 * Runs as the calling user (agent user / case manager / automation user) WITH USER_MODE, so a prompt can
 * never be grounded with data the user cannot see.
 */
public with sharing class FollowUpPromptFacts {
    public class Request {
        @InvocableVariable(label='Recommendation' description='Follow-up recommendation to ground the prompt with.' required=true)
        public Follow_Up_Recommendation__c recommendation;
    }

    public class Response {
        // Prompt Builder requires the Apex provider output variable to be named exactly "Prompt".
        @SuppressWarnings('PMD.FieldNamingConventions')
        @InvocableVariable(label='Prompt' description='Verified facts text merged into the prompt template.')
        public String Prompt;
    }

    @InvocableMethod(
        label='Follow-up Prompt Facts'
        description='Verified, Id-free matter and recommendation facts for Treatment & Records Follow-up prompt templates.'
        CapabilityType='PromptTemplateType://einstein_gpt__flex'
    )
    public static List<Response> getFacts(List<Request> requests) {
        Set<Id> recIds = new Set<Id>();
        for (Request request : requests) {
            if (request.recommendation != null && request.recommendation.Id != null) {
                recIds.add(request.recommendation.Id);
            }
        }
        Map<Id, Follow_Up_Recommendation__c> recs = new Map<Id, Follow_Up_Recommendation__c>(
            FollowUpRecommendationService.query(recIds, AccessLevel.USER_MODE)
        );
        Set<Id> matterIds = new Set<Id>();
        for (Follow_Up_Recommendation__c rec : recs.values()) {
            matterIds.add(rec.Matter__c);
        }
        Date today = Date.today();
        Map<Id, FollowUpMatterContext> contexts = new Map<Id, FollowUpMatterContext>();
        for (FollowUpMatterContext ctx : FollowUpMatterSelector.loadContexts(matterIds, today)) {
            contexts.put(ctx.matter.Id, ctx);
        }

        List<Response> responses = new List<Response>();
        for (Request request : requests) {
            Response response = new Response();
            Follow_Up_Recommendation__c rec = request.recommendation == null ? null : recs.get(request.recommendation.Id);
            if (rec == null) {
                response.Prompt = 'No verified facts are available. Do not generate content; return an empty message.';
            } else {
                FollowUpMatterContext ctx = contexts.get(rec.Matter__c);
                response.Prompt =
                    'MATTER FACTS\n' +
                    (ctx == null ? Label.FollowUp_Not_Recorded : FollowUpFactsBuilder.matterFacts(ctx, today)) +
                    '\n\nFOLLOW-UP FACTS\n' +
                    FollowUpFactsBuilder.recommendationFacts(rec, ctx);
            }
            responses.add(response);
        }
        return responses;
    }
}
