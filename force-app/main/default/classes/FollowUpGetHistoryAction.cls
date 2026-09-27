/**
 * Agentforce action: previous follow-ups on a matter (what was recommended, sent, answered). Read-only.
 */
public with sharing class FollowUpGetHistoryAction {
    public class Request {
        @InvocableVariable(label='Matter Record Id' description='Record Id of the Matter. Use the current record when available.')
        public Id matterId;
        @InvocableVariable(label='Matter Name' description='Exact matter name or number, used when the record Id is not known.')
        public String matterName;
        @InvocableVariable(label='Maximum Records' description='Maximum number of history entries to return (default 20).')
        public Integer maxRecords;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the history was loaded.')
        public Boolean success = false;
        @InvocableVariable(label='Message' description='Error or informational message for the user.')
        public String message;
        @InvocableVariable(
            label='Follow-up History'
            description='One line per follow-up, newest first: number | type | status | created | sent | response.'
        )
        public String history;
        @InvocableVariable(label='Follow-up Count' description='Total number of follow-up recommendations on the matter.')
        public Integer followUpCount;
    }

    @InvocableMethod(
        label='Get Previous Follow-up History'
        description='Returns the previous follow-up recommendations for a matter (type, status, sent date, response classification), newest first. Read-only.'
        category='Treatment & Records Follow-up'
    )
    public static List<Response> getHistory(List<Request> requests) {
        List<Response> responses = new List<Response>();
        try {
            FollowUpSecurity.requireSourceDataAccess();
            List<Id> ids = new List<Id>();
            List<String> names = new List<String>();
            for (Request request : requests) {
                ids.add(request.matterId);
                names.add(request.matterName);
            }
            Map<Id, Matter__c> readable = FollowUpAgentSupport.readableMatters(ids, names);
            Map<Id, List<Follow_Up_Recommendation__c>> byMatter = new Map<Id, List<Follow_Up_Recommendation__c>>();
            for (Follow_Up_Recommendation__c rec : [
                SELECT
                    Id,
                    Name,
                    Matter__c,
                    Recommendation_Type__c,
                    Status__c,
                    CreatedDate,
                    Sent_Date__c,
                    Response_Received__c,
                    Response_Classification__c
                FROM Follow_Up_Recommendation__c
                WHERE Matter__c IN :readable.keySet()
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 2000
            ]) {
                if (!byMatter.containsKey(rec.Matter__c)) {
                    byMatter.put(rec.Matter__c, new List<Follow_Up_Recommendation__c>());
                }
                byMatter.get(rec.Matter__c).add(rec);
            }
            for (Request request : requests) {
                Response response = new Response();
                Matter__c matter = FollowUpAgentSupport.findMatter(readable, request.matterId, request.matterName);
                if (matter == null) {
                    response.message = Label.FollowUp_Error_Matter_Not_Found;
                } else {
                    List<Follow_Up_Recommendation__c> history = byMatter.containsKey(matter.Id)
                        ? byMatter.get(matter.Id)
                        : new List<Follow_Up_Recommendation__c>();
                    response.success = true;
                    response.followUpCount = history.size();
                    response.history = FollowUpFactsBuilder.historyFacts(history, request.maxRecords == null ? 20 : request.maxRecords);
                }
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
