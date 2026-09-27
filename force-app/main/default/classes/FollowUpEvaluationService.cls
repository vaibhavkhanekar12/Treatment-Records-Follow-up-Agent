/**
 * Orchestrates one evaluation pass for a set of matters (nightly batch scope, agent request or UI refresh):
 * load facts -> run rules -> insert recommendations (idempotent) -> auto-assign escalation Tasks ->
 * supersede open recommendations whose condition no longer holds -> maintain Matter__c.Stalled__c.
 *
 * DML runs in SYSTEM_MODE because recommendation workflow fields are read-only to users (see
 * docs/security.md). Callers that act on behalf of a user must first verify the user can read the
 * matters (FollowUpSecurity.readableMatters) - the agent action does this.
 */
public with sharing class FollowUpEvaluationService {
    public class Summary {
        public Integer mattersEvaluated = 0;
        public Integer created = 0;
        public Integer suppressed = 0;
        public Integer superseded = 0;
        public Integer tasksCreated = 0;
        public Integer stalledFlagged = 0;
        public Integer stalledCleared = 0;
        public Integer errors = 0;
        public List<Id> createdIds = new List<Id>();
        public List<String> messages = new List<String>();

        public void add(Summary other) {
            mattersEvaluated += other.mattersEvaluated;
            created += other.created;
            suppressed += other.suppressed;
            superseded += other.superseded;
            tasksCreated += other.tasksCreated;
            stalledFlagged += other.stalledFlagged;
            stalledCleared += other.stalledCleared;
            errors += other.errors;
            // keep bounded in stateful batches
            for (String message : other.messages) {
                if (messages.size() < 100) {
                    messages.add(message);
                }
            }
        }
    }

    public static Summary evaluate(Set<Id> matterIds, String runId) {
        Date today = Date.today();
        Summary summary = new Summary();
        List<FollowUpMatterContext> contexts = FollowUpMatterSelector.loadContexts(matterIds, today);
        summary.mattersEvaluated = contexts.size();
        if (contexts.isEmpty()) {
            return summary;
        }
        FollowUpRuleEngine.Result result = new FollowUpRuleEngine(today).evaluate(contexts);
        summary.suppressed = result.suppressedCount;
        summary.messages.addAll(result.warnings);

        List<Follow_Up_Recommendation__c> toSupersede = findSuperseded(contexts, result.activeConditionKeys);
        supersede(toSupersede, summary);
        insertCandidates(result.candidates, runId, summary);
        updateStalledFlags(contexts, result.stalledByMatter, today, summary);
        return summary;
    }

    /** Open, rule-generated recommendations whose rule condition no longer holds (e.g. treatment resumed). */
    @TestVisible
    private static List<Follow_Up_Recommendation__c> findSuperseded(List<FollowUpMatterContext> contexts, Set<String> activeKeys) {
        List<Follow_Up_Recommendation__c> stale = new List<Follow_Up_Recommendation__c>();
        for (FollowUpMatterContext ctx : contexts) {
            for (Follow_Up_Recommendation__c rec : ctx.openRecommendations()) {
                if (FollowUpConstants.AUTOMATED_RULES.contains(rec.Rule__c) && !activeKeys.contains(rec.Dedupe_Key__c)) {
                    stale.add(rec);
                }
            }
        }
        return stale;
    }

    private static void supersede(List<Follow_Up_Recommendation__c> stale, Summary summary) {
        if (stale.isEmpty()) {
            return;
        }
        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : stale) {
            updates.add(
                new Follow_Up_Recommendation__c(
                    Id = rec.Id,
                    Status__c = FollowUpConstants.STATUS_SUPERSEDED,
                    Closed_Date__c = System.now(),
                    Delivery_Note__c = 'Superseded: the rule condition no longer applies.'
                )
            );
            rec.Status__c = FollowUpConstants.STATUS_SUPERSEDED;
        }
        List<Database.SaveResult> results = Database.update(updates, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                summary.superseded++;
            } else {
                summary.errors++;
                summary.messages.add('Supersede failed for ' + stale[i].Name + ': ' + firstError(results[i]));
            }
        }
    }

    private static void insertCandidates(List<FollowUpRuleEngine.Candidate> candidates, String runId, Summary summary) {
        if (candidates.isEmpty()) {
            return;
        }
        List<Follow_Up_Recommendation__c> recs = new List<Follow_Up_Recommendation__c>();
        for (FollowUpRuleEngine.Candidate candidate : candidates) {
            candidate.recommendation.Agent_Run_Id__c = runId == null ? null : runId.left(40);
            recs.add(candidate.recommendation);
        }
        List<Database.SaveResult> results = Database.insert(recs, false, AccessLevel.SYSTEM_MODE);
        List<FollowUpRuleEngine.Candidate> needTasks = new List<FollowUpRuleEngine.Candidate>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                summary.created++;
                summary.createdIds.add(results[i].getId());
                if (candidates[i].autoCreateTask) {
                    needTasks.add(candidates[i]);
                }
            } else if (isDuplicate(results[i])) {
                // Another open recommendation already holds this Active_Key__c: idempotent no-op.
                summary.suppressed++;
            } else {
                summary.errors++;
                summary.messages.add('Insert failed (' + recs[i].Dedupe_Key__c + '): ' + firstError(results[i]));
            }
        }
        createAssignedTasks(needTasks, summary);
    }

    /** Internal escalations configured with Auto_Create_Task__c are assigned immediately (no approval needed). */
    private static void createAssignedTasks(List<FollowUpRuleEngine.Candidate> candidates, Summary summary) {
        if (candidates.isEmpty()) {
            return;
        }
        List<Task> tasks = new List<Task>();
        for (FollowUpRuleEngine.Candidate candidate : candidates) {
            tasks.add(buildTask(candidate.recommendation, candidate.context.matter.Name));
        }
        List<Database.SaveResult> taskResults = Database.insert(tasks, false, AccessLevel.SYSTEM_MODE);
        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        for (Integer i = 0; i < taskResults.size(); i++) {
            Follow_Up_Recommendation__c rec = candidates[i].recommendation;
            if (taskResults[i].isSuccess()) {
                summary.tasksCreated++;
                updates.add(
                    new Follow_Up_Recommendation__c(
                        Id = rec.Id,
                        Status__c = FollowUpConstants.STATUS_SENT,
                        Sent_Date__c = System.now(),
                        Task_Id__c = taskResults[i].getId(),
                        Delivery_Note__c = 'Task assigned to case manager.'
                    )
                );
            } else {
                summary.errors++;
                summary.messages.add('Task creation failed for ' + rec.Dedupe_Key__c + ': ' + firstError(taskResults[i]));
            }
        }
        if (!updates.isEmpty()) {
            List<Database.SaveResult> updateResults = Database.update(updates, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < updateResults.size(); i++) {
                if (!updateResults[i].isSuccess()) {
                    summary.errors++;
                    summary.messages.add(
                        'Task created but status update failed for ' + updates[i].Id + ': ' + firstError(updateResults[i])
                    );
                }
            }
        }
    }

    public static Task buildTask(Follow_Up_Recommendation__c rec, String matterName) {
        Task task = new Task(
            WhatId = rec.Matter__c,
            Subject = ('Follow-up ' + typeLabel(rec.Recommendation_Type__c) + ': ' + matterName).left(255),
            Description = rec.Reason__c,
            ActivityDate = Date.today(),
            Priority = rec.Priority__c == FollowUpConstants.PRIORITY_HIGH ? 'High' : 'Normal'
        );
        if (rec.Assigned_To__c != null) {
            task.OwnerId = rec.Assigned_To__c;
        }
        return task;
    }

    private static void updateStalledFlags(
        List<FollowUpMatterContext> contexts,
        Map<Id, Boolean> stalledByMatter,
        Date today,
        Summary summary
    ) {
        List<Matter__c> updates = new List<Matter__c>();
        for (FollowUpMatterContext ctx : contexts) {
            if (!stalledByMatter.containsKey(ctx.matter.Id)) {
                continue;
            }
            Boolean stalled = stalledByMatter.get(ctx.matter.Id);
            Boolean wasStalled = ctx.matter.Stalled__c == true;
            if (stalled && !wasStalled) {
                updates.add(new Matter__c(Id = ctx.matter.Id, Stalled__c = true, Stalled_Since__c = today));
                summary.stalledFlagged++;
            } else if (!stalled && wasStalled) {
                updates.add(new Matter__c(Id = ctx.matter.Id, Stalled__c = false, Stalled_Since__c = null));
                summary.stalledCleared++;
            }
        }
        if (updates.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = new StalledFlagWriter().write(updates);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                summary.errors++;
                summary.messages.add('Stalled flag update failed for matter ' + updates[i].Id + ': ' + firstError(results[i]));
            }
        }
    }

    /**
     * The ONLY `without sharing` code in the solution, deliberately narrow: it writes the two
     * solution-owned, system-computed fields Matter__c.Stalled__c / Stalled_Since__c. The evaluator can
     * read every open matter (View All) but must not need edit access to matters it does not own, and
     * granting Modify All on Matter__c to the automation user would be far broader than this.
     * Callers pass records built by updateStalledFlags() only (Id + the two fields).
     */
    private without sharing class StalledFlagWriter {
        List<Database.SaveResult> write(List<Matter__c> flags) {
            List<Matter__c> safe = new List<Matter__c>();
            for (Matter__c flag : flags) {
                safe.add(new Matter__c(Id = flag.Id, Stalled__c = flag.Stalled__c, Stalled_Since__c = flag.Stalled_Since__c));
            }
            return Database.update(safe, false, AccessLevel.SYSTEM_MODE);
        }
    }

    public static String typeLabel(String typeValue) {
        for (Schema.PicklistEntry entry : Follow_Up_Recommendation__c.Recommendation_Type__c.getDescribe().getPicklistValues()) {
            if (entry.getValue() == typeValue) {
                return entry.getLabel();
            }
        }
        return typeValue;
    }

    private static Boolean isDuplicate(Database.SaveResult result) {
        for (Database.Error error : result.getErrors()) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return true;
            }
        }
        return false;
    }

    private static String firstError(Database.SaveResult result) {
        return result.getErrors().isEmpty() ? 'unknown error' : result.getErrors()[0].getMessage();
    }
}
