/**
 * Nightly evaluation of open PI matters. Batch Apex (not a Scheduled Flow) because each matter needs
 * cross-object aggregates, dedupe and supersede logic; see docs/architecture.md ADR-2.
 *
 * Runs as the automation user holding the Follow_Up_Automation permission set (View All on source objects).
 * Database.RaisesPlatformEvents publishes BatchApexErrorEvent for unhandled scope failures (monitoring).
 */
public with sharing class FollowUpEvaluationBatch implements Database.Batchable<SObject>, Database.Stateful, Database.RaisesPlatformEvents {
    private final FollowUpEvaluationService.Summary totals = new FollowUpEvaluationService.Summary();
    private String runId;

    public Database.QueryLocator start(Database.BatchableContext context) {
        runId = context == null ? 'BATCH' : String.valueOf(context.getJobId());
        Map<String, Object> binds = new Map<String, Object>{ 'statuses' => FollowUpConfig.openMatterStatuses() };
        String query = 'SELECT Id FROM Matter__c WHERE Status__c IN :statuses';
        String practiceArea = FollowUpConfig.getSetting().Practice_Area_Filter__c;
        if (String.isNotBlank(practiceArea)) {
            query += ' AND Practice_Area__c = :practiceArea';
            binds.put('practiceArea', practiceArea.trim());
        }
        query += ' ORDER BY Id';
        return Database.getQueryLocatorWithBinds(query, binds, AccessLevel.SYSTEM_MODE);
    }

    public void execute(Database.BatchableContext context, List<Matter__c> scope) {
        Set<Id> matterIds = new Map<Id, Matter__c>(scope).keySet();
        totals.add(FollowUpEvaluationService.evaluate(matterIds, runId));
    }

    public void finish(Database.BatchableContext context) {
        System.debug(LoggingLevel.INFO, 'Treatment & Records Follow-up run ' + runId + ': ' + JSON.serialize(totals));
        if (totals.created > 0 && FollowUpDraftService.resolveAiGenerator() != null && FollowUpConfig.maxAiDraftsPerRun() > 0) {
            System.enqueueJob(new FollowUpAiDraftQueueable(runId));
        }
    }

    @TestVisible
    private FollowUpEvaluationService.Summary getTotals() {
        return totals;
    }
}
