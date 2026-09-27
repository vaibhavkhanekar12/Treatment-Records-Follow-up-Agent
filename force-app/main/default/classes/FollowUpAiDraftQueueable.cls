/**
 * Refines template drafts with the configured AI generator for recommendations created in one run.
 * Only client/provider-facing drafts and stalled-matter summaries are sent to AI, and only up to
 * Follow_Up_Setting__mdt.Max_AI_Drafts_Per_Run__c per run (cost and exposure control).
 * Callouts happen before DML in every execution; results are persisted in SYSTEM_MODE.
 */
public with sharing class FollowUpAiDraftQueueable implements Queueable, Database.AllowsCallouts {
    /** Records per execution: keeps LLM callouts and CPU time well inside one transaction's limits. */
    @TestVisible
    private static final Integer CHUNK_SIZE = 10;

    private final String runId;
    private final Id afterId;
    private final Integer processedSoFar;

    public FollowUpAiDraftQueueable(String runId) {
        this(runId, null, 0);
    }

    private FollowUpAiDraftQueueable(String runId, Id afterId, Integer processedSoFar) {
        this.runId = runId;
        this.afterId = afterId;
        this.processedSoFar = processedSoFar;
    }

    public void execute(QueueableContext context) {
        IFollowUpDraftGenerator generator = FollowUpDraftService.resolveAiGenerator();
        Integer remaining = FollowUpConfig.maxAiDraftsPerRun() - processedSoFar;
        if (generator == null || remaining <= 0) {
            return;
        }
        Integer limitSize = Math.min(CHUNK_SIZE, remaining);
        List<Follow_Up_Recommendation__c> recs = selectBatch(limitSize);
        if (recs.isEmpty()) {
            return;
        }
        List<FollowUpDraftResult> results;
        try {
            results = generator.generate(recs);
        } catch (Exception e) {
            // AI is optional: template drafts remain in place.
            System.debug(LoggingLevel.WARN, 'AI draft generation failed: ' + e.getMessage());
            results = new List<FollowUpDraftResult>();
        }
        Map<Id, Follow_Up_Recommendation__c> byId = new Map<Id, Follow_Up_Recommendation__c>(recs);
        Set<Id> changed = FollowUpDraftService.applyAiResults(results, byId);
        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        for (Follow_Up_Recommendation__c rec : recs) {
            // Withheld drafts only changed the rationale; persist that too so reviewers see why.
            if (changed.contains(rec.Id) || rec.AI_Rationale__c == Label.FollowUp_AI_Draft_Withheld) {
                updates.add(rec);
            }
        }
        if (!updates.isEmpty()) {
            Database.update(updates, false, AccessLevel.SYSTEM_MODE);
        }
        Id lastId = recs[recs.size() - 1].Id;
        if (recs.size() == limitSize && !Test.isRunningTest()) {
            System.enqueueJob(new FollowUpAiDraftQueueable(runId, lastId, processedSoFar + recs.size()));
        }
    }

    private List<Follow_Up_Recommendation__c> selectBatch(Integer limitSize) {
        Set<String> audiences = FollowUpConstants.EXTERNAL_AUDIENCES;
        String stalledType = FollowUpConstants.TYPE_STALLED_MATTER;
        String pending = FollowUpConstants.STATUS_PENDING_REVIEW;
        // Stalled reviews usually have their Task auto-assigned already (status Sent); still worth a summary.
        Set<String> stalledStatuses = new Set<String>{ FollowUpConstants.STATUS_PENDING_REVIEW, FollowUpConstants.STATUS_SENT };
        String templateSource = FollowUpConstants.DRAFT_TEMPLATE;
        Id cursor = afterId;
        String query =
            'SELECT Id, Name, Matter__c, Recommendation_Type__c, Status__c, Audience__c, Channel__c, Priority__c, ' +
            'Reason__c, Draft_Subject__c, Draft_Message__c, Draft_Source__c, AI_Rationale__c, Medical_Provider__c, ' +
            'Records_Request__c, Recipient_Contact__c, Response_Text__c ' +
            'FROM Follow_Up_Recommendation__c ' +
            'WHERE Agent_Run_Id__c = :runId ' +
            'AND ((Status__c = :pending AND Audience__c IN :audiences AND Draft_Source__c = :templateSource) ' +
            'OR (Recommendation_Type__c = :stalledType AND Status__c IN :stalledStatuses))' +
            (cursor == null ? '' : ' AND Id > :cursor') +
            ' ORDER BY Id LIMIT :limitSize';
        return Database.queryWithBinds(
            query,
            new Map<String, Object>{
                'runId' => runId,
                'pending' => pending,
                'audiences' => audiences,
                'templateSource' => templateSource,
                'stalledType' => stalledType,
                'stalledStatuses' => stalledStatuses,
                'cursor' => cursor,
                'limitSize' => limitSize
            },
            AccessLevel.SYSTEM_MODE
        );
    }
}
