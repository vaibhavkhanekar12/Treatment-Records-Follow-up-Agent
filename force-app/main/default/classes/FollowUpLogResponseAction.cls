/**
 * Agentforce action: logs an inbound client or provider reply, records its operational classification
 * and applies the configured next action (complete, re-check later, or case-manager review).
 * The agent may supply the category it inferred; otherwise the configured classifier is used.
 */
public with sharing class FollowUpLogResponseAction {
    public class Request {
        @InvocableVariable(label='Recommendation Record Id' description='Record Id of the follow-up the reply answers, when known.')
        public Id recommendationId;
        @InvocableVariable(
            label='Matter Record Id'
            description='Record Id of the Matter, used when the follow-up is not known (the latest sent follow-up is used).'
        )
        public Id matterId;
        @InvocableVariable(label='Response Text' description='Exact text of the inbound reply, verbatim.' required=true)
        public String responseText;
        @InvocableVariable(label='Source' description='How the reply arrived: Email, SMS, Phone, Fax or Portal.')
        public String source;
        @InvocableVariable(label='Audience' description='Client or Provider.')
        public String audience;
        @InvocableVariable(
            label='Category'
            description='Optional operational category: Treatment_Continuing, Treatment_Stopped, Records_Sent, Provider_Action_Required, Callback_Requested, Status_Question, Opt_Out or Unclear. Leave empty if unsure.'
        )
        public String category;
        @InvocableVariable(label='Confidence' description='Optional confidence between 0 and 1 for the supplied category.')
        public Decimal confidence;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the reply was logged.')
        public Boolean success = false;
        @InvocableVariable(label='Message' description='Error or informational message for the user.')
        public String message;
        @InvocableVariable(
            label='Category'
            description='Operational classification recorded (Pending_Classification when AI classification runs in the background).'
        )
        public String category;
        @InvocableVariable(label='Next Action' description='Complete, Complete_And_Recheck or Case_Manager_Review.')
        public String nextAction;
        @InvocableVariable(label='Review Created' description='True when a case-manager review item was created.')
        public Boolean reviewCreated;
    }

    @InvocableMethod(
        label='Classify Inbound Response'
        description='Logs an inbound client or provider reply to a follow-up, classifies it into an operational category (never legal), and applies the firm configured next action such as case-manager review.'
        category='Treatment & Records Follow-up'
    )
    public static List<Response> logResponses(List<Request> requests) {
        List<Response> responses = new List<Response>();
        try {
            List<FollowUpResponseService.ResponseInput> inputs = new List<FollowUpResponseService.ResponseInput>();
            for (Request request : requests) {
                FollowUpResponseService.ResponseInput input = new FollowUpResponseService.ResponseInput();
                input.recommendationId = request.recommendationId;
                input.matterId = request.matterId;
                input.responseText = request.responseText;
                input.source = request.source;
                input.audience = request.audience;
                input.category = request.category;
                input.confidence = request.confidence;
                inputs.add(input);
            }
            List<FollowUpResponseService.ResponseResult> results = FollowUpResponseService.logResponses(inputs);
            for (Integer i = 0; i < requests.size(); i++) {
                Response response = new Response();
                response.success = true;
                if (i < results.size()) {
                    response.category = results[i].category;
                    response.nextAction = results[i].nextAction;
                    response.reviewCreated = results[i].reviewCreated;
                }
                response.message = 'Response logged.';
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
