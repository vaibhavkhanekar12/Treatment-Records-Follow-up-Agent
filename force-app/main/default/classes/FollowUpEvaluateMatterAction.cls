/**
 * Agentforce action: runs the deterministic follow-up rules for a matter now and returns the open
 * recommendations. Idempotent: an existing open recommendation is never duplicated. Never sends anything.
 */
public with sharing class FollowUpEvaluateMatterAction {
    public class Request {
        @InvocableVariable(label='Matter Record Id' description='Record Id of the Matter. Use the current record when available.')
        public Id matterId;
        @InvocableVariable(label='Matter Name' description='Exact matter name or number, used when the record Id is not known.')
        public String matterName;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the rules were evaluated.')
        public Boolean success = false;
        @InvocableVariable(label='Message' description='Error or informational message for the user.')
        public String message;
        @InvocableVariable(label='New Recommendations' description='Number of new follow-up recommendations created by this evaluation.')
        public Integer createdCount;
        @InvocableVariable(
            label='Open Recommendations'
            description='Open recommendations after evaluation: number | type | priority | verified reason. All require case-manager review in the Follow-up Work Queue.'
        )
        public String openRecommendations;
    }

    @InvocableMethod(
        label='Create Follow-up Recommendations'
        description='Evaluates a matter against the firm configured treatment-gap, records follow-up, escalation, missing-bills and stalled-matter rules, creates any missing follow-up recommendations for case-manager review, and lists open recommendations. Does not send any communication.'
        category='Treatment & Records Follow-up'
    )
    public static List<Response> evaluate(List<Request> requests) {
        List<Response> responses = new List<Response>();
        try {
            List<Id> ids = new List<Id>();
            List<String> names = new List<String>();
            for (Request request : requests) {
                ids.add(request.matterId);
                names.add(request.matterName);
            }
            Map<Id, Matter__c> readable = FollowUpAgentSupport.readableMatters(ids, names);
            Map<Integer, Matter__c> matterByIndex = new Map<Integer, Matter__c>();
            Set<Id> toEvaluate = new Set<Id>();
            for (Integer i = 0; i < requests.size(); i++) {
                Matter__c matter = FollowUpAgentSupport.findMatter(readable, requests[i].matterId, requests[i].matterName);
                if (matter != null) {
                    matterByIndex.put(i, matter);
                    toEvaluate.add(matter.Id);
                }
            }
            Set<Id> createdIds = new Set<Id>();
            if (!toEvaluate.isEmpty()) {
                createdIds.addAll(FollowUpAgentSupport.evaluateForUser(toEvaluate, FollowUpConstants.SOURCE_AGENT).createdIds);
            }
            Map<Id, List<Follow_Up_Recommendation__c>> openByMatter = new Map<Id, List<Follow_Up_Recommendation__c>>();
            for (Follow_Up_Recommendation__c rec : [
                SELECT Id, Name, Matter__c, Recommendation_Type__c, Priority__c, Status__c, Reason__c
                FROM Follow_Up_Recommendation__c
                WHERE Matter__c IN :toEvaluate AND Status__c IN :FollowUpConstants.OPEN_STATUSES
                WITH USER_MODE
                ORDER BY Priority__c ASC, CreatedDate ASC
            ]) {
                if (!openByMatter.containsKey(rec.Matter__c)) {
                    openByMatter.put(rec.Matter__c, new List<Follow_Up_Recommendation__c>());
                }
                openByMatter.get(rec.Matter__c).add(rec);
            }
            for (Integer i = 0; i < requests.size(); i++) {
                Response response = new Response();
                Matter__c matter = matterByIndex.get(i);
                if (matter == null) {
                    response.message = Label.FollowUp_Error_Matter_Not_Found;
                    responses.add(response);
                    continue;
                }
                List<String> lines = new List<String>();
                Integer created = 0;
                List<Follow_Up_Recommendation__c> open = openByMatter.containsKey(matter.Id)
                    ? openByMatter.get(matter.Id)
                    : new List<Follow_Up_Recommendation__c>();
                for (Follow_Up_Recommendation__c rec : open) {
                    if (createdIds.contains(rec.Id)) {
                        created++;
                    }
                    lines.add(
                        rec.Name +
                            ' | ' +
                            FollowUpEvaluationService.typeLabel(rec.Recommendation_Type__c) +
                            ' | ' +
                            rec.Priority__c +
                            ' | ' +
                            rec.Reason__c
                    );
                }
                response.success = true;
                response.createdCount = created;
                response.openRecommendations = lines.isEmpty()
                    ? 'No follow-up is currently needed for this matter.'
                    : String.join(lines, '\n');
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
}
