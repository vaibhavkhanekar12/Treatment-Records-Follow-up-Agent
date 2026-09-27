/**
 * Agentforce action: (re)generates the draft communication and rationale for a recommendation from
 * verified facts (AI via Prompt Builder when configured, otherwise the firm's template).
 * NEVER sends. The draft returns to Pending Review and must be approved in the Follow-up Work Queue.
 */
public with sharing class FollowUpGenerateDraftAction {
    public class Request {
        @InvocableVariable(label='Recommendation Record Id' description='Record Id of the Follow-up Recommendation.')
        public Id recommendationId;
        @InvocableVariable(
            label='Recommendation Number'
            description='Recommendation number such as FUR-000123, used when the record Id is not known.'
        )
        public String recommendationNumber;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the draft was generated and saved for review.')
        public Boolean success = false;
        @InvocableVariable(label='Message' description='Error or informational message for the user.')
        public String message;
        @InvocableVariable(label='Draft Subject' description='Draft subject line (email only).')
        public String draftSubject;
        @InvocableVariable(label='Draft Message' description='Draft communication text. Not sent: requires case-manager approval.')
        public String draftMessage;
        @InvocableVariable(label='Rationale' description='Plain-language explanation of why this follow-up is recommended.')
        public String rationale;
        @InvocableVariable(label='Draft Source' description='Template or AI.')
        public String draftSource;
    }

    @InvocableMethod(
        label='Generate Follow-up Draft'
        description='Generates or refreshes the draft client/provider follow-up message and rationale for a follow-up recommendation using only verified Salesforce facts. Saves it for case-manager approval. Never sends the message.'
        category='Treatment & Records Follow-up'
    )
    public static List<Response> generate(List<Request> requests) {
        List<Response> responses = new List<Response>();
        try {
            FollowUpSecurity.requireSourceDataAccess();
            Map<Integer, Id> idByIndex = resolveIds(requests);
            List<Follow_Up_Recommendation__c> recs = FollowUpRecommendationService.loadForAction(new Set<Id>(idByIndex.values()));
            for (Follow_Up_Recommendation__c rec : recs) {
                FollowUpRecommendationService.requireStatus(rec, FollowUpConstants.OPEN_STATUSES);
            }
            FollowUpDraftService.regenerate(recs, true);
            FollowUpRecommendationService.save(recs);
            Map<Id, Follow_Up_Recommendation__c> byId = new Map<Id, Follow_Up_Recommendation__c>(recs);
            for (Integer i = 0; i < requests.size(); i++) {
                Follow_Up_Recommendation__c rec = byId.get(idByIndex.get(i));
                Response response = new Response();
                response.success = true;
                response.draftSubject = rec.Draft_Subject__c;
                response.draftMessage = rec.Draft_Message__c;
                response.rationale = rec.AI_Rationale__c;
                response.draftSource = rec.Draft_Source__c;
                response.message = 'Draft saved for case-manager review. It has not been sent.';
                responses.add(response);
            }
        } catch (Exception e) {
            responses.clear();
            for (Integer i = 0; i < requests.size(); i++) {
                Response response = new Response();
                response.message = FollowUpAgentSupport.errorMessage(e);
                responses.add(response);
            }
        }
        return responses;
    }

    private static Map<Integer, Id> resolveIds(List<Request> requests) {
        Set<String> numbers = new Set<String>();
        for (Request request : requests) {
            if (request.recommendationId == null && String.isNotBlank(request.recommendationNumber)) {
                numbers.add(request.recommendationNumber.trim());
            }
        }
        Map<String, Id> idByNumber = new Map<String, Id>();
        if (!numbers.isEmpty()) {
            for (Follow_Up_Recommendation__c rec : [
                SELECT Id, Name
                FROM Follow_Up_Recommendation__c
                WHERE Name IN :numbers
                WITH USER_MODE
            ]) {
                idByNumber.put(rec.Name, rec.Id);
            }
        }
        Map<Integer, Id> idByIndex = new Map<Integer, Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            Id recId = request.recommendationId != null
                ? request.recommendationId
                : idByNumber.get(request.recommendationNumber == null ? null : request.recommendationNumber.trim());
            if (recId == null) {
                throw new FollowUpException(Label.FollowUp_Error_No_Access);
            }
            idByIndex.put(i, recId);
        }
        return idByIndex;
    }
}
