/**
 * Agentforce action: escalates a matter to its case manager with a stated operational reason.
 * Creates a high-priority internal recommendation and an assigned Task. Idempotent while an escalation
 * is open (until its Task is completed). Internal only - no client or provider communication.
 */
public with sharing class FollowUpEscalateMatterAction {
    public class Request {
        @InvocableVariable(label='Matter Record Id' description='Record Id of the Matter. Use the current record when available.')
        public Id matterId;
        @InvocableVariable(label='Matter Name' description='Exact matter name or number, used when the record Id is not known.')
        public String matterName;
        @InvocableVariable(
            label='Reason'
            description='Operational reason for the escalation, based on verified facts (no legal or medical conclusions).'
            required=true
        )
        public String reason;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the escalation exists (created now or already open).')
        public Boolean success = false;
        @InvocableVariable(label='Message' description='Result message for the user.')
        public String message;
        @InvocableVariable(label='Recommendation Number' description='Number of the escalation recommendation.')
        public String recommendationNumber;
    }

    @InvocableMethod(
        label='Escalate Matter to Case Manager'
        description='Escalates a matter to its assigned case manager by creating a high-priority internal follow-up and an assigned Task with the stated operational reason. Does not contact clients or providers.'
        category='Treatment & Records Follow-up'
    )
    public static List<Response> escalate(List<Request> requests) {
        List<Response> responses = new List<Response>();
        try {
            if (!Schema.SObjectType.Follow_Up_Recommendation__c.isCreateable()) {
                throw new FollowUpException(Label.FollowUp_Error_No_Access);
            }
            List<Id> ids = new List<Id>();
            List<String> names = new List<String>();
            for (Request request : requests) {
                if (String.isBlank(request.reason)) {
                    throw new FollowUpException(Label.FollowUp_Error_Reason_Required);
                }
                ids.add(request.matterId);
                names.add(request.matterName);
            }
            Map<Id, Matter__c> readable = FollowUpAgentSupport.readableMatters(ids, names);
            Map<Id, FollowUpMatterContext> contexts = new Map<Id, FollowUpMatterContext>();
            for (FollowUpMatterContext ctx : FollowUpMatterSelector.loadContexts(readable.keySet(), Date.today())) {
                contexts.put(ctx.matter.Id, ctx);
            }

            Map<String, Follow_Up_Recommendation__c> recByKey = new Map<String, Follow_Up_Recommendation__c>();
            Map<Integer, String> keyByIndex = new Map<Integer, String>();
            for (Integer i = 0; i < requests.size(); i++) {
                Matter__c matter = FollowUpAgentSupport.findMatter(readable, requests[i].matterId, requests[i].matterName);
                if (matter == null) {
                    continue;
                }
                FollowUpMatterContext ctx = contexts.get(matter.Id);
                String key = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_CASE_MANAGER_ESCALATION, matter.Id);
                keyByIndex.put(i, key);
                if (!recByKey.containsKey(key)) {
                    recByKey.put(
                        key,
                        new Follow_Up_Recommendation__c(
                            Matter__c = matter.Id,
                            Recommendation_Type__c = FollowUpConstants.TYPE_CASE_MANAGER_ESCALATION,
                            Rule__c = FollowUpConstants.SOURCE_AGENT,
                            Status__c = FollowUpConstants.STATUS_PENDING_REVIEW,
                            Priority__c = FollowUpConstants.PRIORITY_HIGH,
                            Audience__c = FollowUpConstants.AUDIENCE_INTERNAL,
                            Channel__c = FollowUpConstants.CHANNEL_TASK,
                            Assigned_To__c = ctx.assigneeId(),
                            Recommended_Date__c = Date.today(),
                            Dedupe_Key__c = key,
                            Agent_Run_Id__c = ('AGENT-' + UserInfo.getUserId()).left(40),
                            Reason__c = ('Escalated via the Follow-up Agent by ' +
                                UserInfo.getName() +
                                ': ' +
                                requests[i].reason)
                                .left(5000)
                        )
                    );
                }
            }

            // An escalation is "open" until its Task is completed (Pending/Approved/Send Failed/Sent).
            Set<String> inFlight = new Set<String>(FollowUpConstants.OPEN_STATUSES);
            inFlight.add(FollowUpConstants.STATUS_SENT);
            Map<String, String> nameByKey = new Map<String, String>();
            for (Follow_Up_Recommendation__c existing : [
                SELECT Name, Dedupe_Key__c
                FROM Follow_Up_Recommendation__c
                WHERE Dedupe_Key__c IN :recByKey.keySet() AND Status__c IN :inFlight
                WITH USER_MODE
            ]) {
                nameByKey.put(existing.Dedupe_Key__c, existing.Name);
                recByKey.remove(existing.Dedupe_Key__c);
            }

            List<Follow_Up_Recommendation__c> recs = recByKey.values();
            List<Database.SaveResult> results = Database.insert(recs, false, AccessLevel.SYSTEM_MODE);
            List<Follow_Up_Recommendation__c> created = new List<Follow_Up_Recommendation__c>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    created.add(recs[i]);
                }
            }
            createTasks(created, readable);
            for (Follow_Up_Recommendation__c rec : [
                SELECT Name, Dedupe_Key__c
                FROM Follow_Up_Recommendation__c
                WHERE Id IN :created
                WITH USER_MODE
            ]) {
                nameByKey.put(rec.Dedupe_Key__c, rec.Name);
            }
            Set<Id> createdIds = new Map<Id, Follow_Up_Recommendation__c>(created).keySet();
            for (Integer i = 0; i < requests.size(); i++) {
                Response response = new Response();
                String key = keyByIndex.get(i);
                if (key == null) {
                    response.message = Label.FollowUp_Error_Matter_Not_Found;
                } else {
                    response.success = nameByKey.containsKey(key);
                    response.recommendationNumber = nameByKey.get(key);
                    response.message = recByKey.containsKey(key) && createdIds.contains(recByKey.get(key).Id)
                        ? 'Escalated to the case manager and a Task was assigned.'
                        : 'An escalation for this matter is already open.';
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

    private static void createTasks(List<Follow_Up_Recommendation__c> recs, Map<Id, Matter__c> matters) {
        if (recs.isEmpty()) {
            return;
        }
        List<Task> tasks = new List<Task>();
        for (Follow_Up_Recommendation__c rec : recs) {
            tasks.add(FollowUpEvaluationService.buildTask(rec, matters.get(rec.Matter__c).Name));
        }
        Database.insert(tasks, true, AccessLevel.SYSTEM_MODE);
        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        for (Integer i = 0; i < recs.size(); i++) {
            updates.add(
                new Follow_Up_Recommendation__c(
                    Id = recs[i].Id,
                    Status__c = FollowUpConstants.STATUS_SENT,
                    Sent_Date__c = System.now(),
                    Task_Id__c = tasks[i].Id,
                    Delivery_Note__c = 'Task assigned to case manager.'
                )
            );
        }
        Database.update(updates, true, AccessLevel.SYSTEM_MODE);
    }
}
