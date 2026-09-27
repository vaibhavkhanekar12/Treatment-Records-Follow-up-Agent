/**
 * Agentforce action: verified follow-up status of a matter (treatment gap, outstanding records,
 * client contact recency, stalled flag, open recommendations). Read-only.
 */
public with sharing class FollowUpGetMatterStatusAction {
    public class Request {
        @InvocableVariable(
            label='Matter Record Id'
            description='Record Id of the Matter. Use the current record when the user is on a matter page.'
        )
        public Id matterId;
        @InvocableVariable(label='Matter Name' description='Exact matter name or number, used when the record Id is not known.')
        public String matterName;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the matter was found and the facts were loaded.')
        public Boolean success = false;
        @InvocableVariable(label='Message' description='Error or informational message for the user.')
        public String message;
        @InvocableVariable(label='Matter Name' description='Matter name/number.')
        public String matterName;
        @InvocableVariable(
            label='Matter Facts'
            description='Verified facts from Salesforce, one per line. Missing data is shown as Not recorded. Use only these facts.'
        )
        public String matterFacts;
        @InvocableVariable(
            label='Treatment Gap Days'
            description='Days since the last recorded treatment (or sign-up when no treatment is recorded).'
        )
        public Integer treatmentGapDays;
        @InvocableVariable(label='Outstanding Records Requests' description='Number of records/bills requests not yet received.')
        public Integer outstandingRequestCount;
        @InvocableVariable(label='Oldest Outstanding Request Days' description='Age in days of the oldest outstanding request.')
        public Integer oldestOutstandingRequestDays;
        @InvocableVariable(
            label='Days Since Client Contact'
            description='Days since the last completed activity with the client; empty when none is recorded.'
        )
        public Integer daysSinceClientContact;
        @InvocableVariable(label='Potentially Stalled' description='True when the nightly rules flagged the matter as potentially stalled.')
        public Boolean isStalled;
        @InvocableVariable(label='Open Recommendations' description='Number of open follow-up recommendations on the matter.')
        public Integer openRecommendationCount;
    }

    @InvocableMethod(
        label='Get Matter Follow-up Status'
        description='Returns verified treatment, medical-records and client-contact follow-up facts for a Personal Injury matter the user can access. Read-only.'
        category='Treatment & Records Follow-up'
    )
    public static List<Response> getStatus(List<Request> requests) {
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
            Date today = Date.today();
            Map<Id, FollowUpMatterContext> contexts = new Map<Id, FollowUpMatterContext>();
            for (FollowUpMatterContext ctx : FollowUpMatterSelector.loadContexts(readable.keySet(), today)) {
                contexts.put(ctx.matter.Id, ctx);
            }
            Set<String> outstandingStatuses = FollowUpConfig.outstandingRequestStatuses();
            for (Request request : requests) {
                Response response = new Response();
                Matter__c matter = FollowUpAgentSupport.findMatter(readable, request.matterId, request.matterName);
                FollowUpMatterContext ctx = matter == null ? null : contexts.get(matter.Id);
                if (ctx == null) {
                    response.message = Label.FollowUp_Error_Matter_Not_Found;
                    responses.add(response);
                    continue;
                }
                response.success = true;
                response.matterName = ctx.matter.Name;
                response.matterFacts = FollowUpFactsBuilder.matterFacts(ctx, today);
                Date anchor = ctx.treatmentAnchor();
                response.treatmentGapDays = anchor == null ? null : anchor.daysBetween(today);
                List<Records_Request__c> outstanding = ctx.outstandingRequests(outstandingStatuses);
                response.outstandingRequestCount = outstanding.size();
                for (Records_Request__c req : outstanding) {
                    if (req.Requested_Date__c != null) {
                        Integer age = req.Requested_Date__c.daysBetween(today);
                        if (response.oldestOutstandingRequestDays == null || age > response.oldestOutstandingRequestDays) {
                            response.oldestOutstandingRequestDays = age;
                        }
                    }
                }
                response.daysSinceClientContact = ctx.lastClientContactDate == null ? null : ctx.lastClientContactDate.daysBetween(today);
                response.isStalled = ctx.matter.Stalled__c == true;
                response.openRecommendationCount = ctx.openRecommendations().size();
                responses.add(response);
            }
        } catch (Exception e) {
            responses = FollowUpGetMatterStatusAction.failAll(requests.size(), FollowUpAgentSupport.errorMessage(e));
        }
        return responses;
    }

    private static List<Response> failAll(Integer size, String message) {
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < size; i++) {
            Response response = new Response();
            response.message = message;
            responses.add(response);
        }
        return responses;
    }
}
