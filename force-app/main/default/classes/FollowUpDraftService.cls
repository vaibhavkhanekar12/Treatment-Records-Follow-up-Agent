/**
 * Draft generation for saved recommendations: template baseline (always) refined by the configured
 * AI generator (optional). AI output passes FollowUpDraftGuard before it can replace a template draft.
 * Nothing here sends a message or changes approval state except resetting to Pending Review.
 */
public with sharing class FollowUpDraftService {
    @TestVisible
    private static IFollowUpDraftGenerator generatorOverride;

    /** The configured AI generator, or null when AI drafting is not configured/available. */
    public static IFollowUpDraftGenerator resolveAiGenerator() {
        if (generatorOverride != null) {
            return generatorOverride;
        }
        String className = FollowUpConfig.getSetting().AI_Draft_Generator_Class__c;
        if (String.isBlank(className)) {
            return null;
        }
        Type generatorType = Type.forName(className.trim());
        if (generatorType == null) {
            return null;
        }
        Object instance = generatorType.newInstance();
        return instance instanceof IFollowUpDraftGenerator ? (IFollowUpDraftGenerator) instance : null;
    }

    /**
     * Rebuilds the template draft from current facts and, when useAi is true and a generator is configured,
     * refines it with AI. Records are modified in memory only; the caller persists them.
     * Order matters: queries and AI callouts happen here, before any DML by the caller.
     */
    public static List<Follow_Up_Recommendation__c> regenerate(List<Follow_Up_Recommendation__c> recs, Boolean useAi) {
        Set<Id> matterIds = new Set<Id>();
        for (Follow_Up_Recommendation__c rec : recs) {
            matterIds.add(rec.Matter__c);
        }
        Map<Id, FollowUpMatterContext> contexts = new Map<Id, FollowUpMatterContext>();
        for (FollowUpMatterContext ctx : FollowUpMatterSelector.loadContexts(matterIds, Date.today())) {
            contexts.put(ctx.matter.Id, ctx);
        }
        for (Follow_Up_Recommendation__c rec : recs) {
            FollowUpDraftBuilder.applyTemplate(rec, contexts.get(rec.Matter__c));
            rec.AI_Rationale__c = Label.FollowUp_Template_Rationale;
        }
        if (useAi == true) {
            IFollowUpDraftGenerator generator = resolveAiGenerator();
            if (generator != null) {
                applyAiResults(generator.generate(recs), new Map<Id, Follow_Up_Recommendation__c>(recs));
            }
        }
        for (Follow_Up_Recommendation__c rec : recs) {
            resetApprovalIfNeeded(rec);
        }
        return recs;
    }

    /**
     * Applies generator output to the in-memory records. Returns the Ids whose AI draft was accepted.
     * Failed or unsafe results leave the template draft untouched.
     */
    public static Set<Id> applyAiResults(List<FollowUpDraftResult> results, Map<Id, Follow_Up_Recommendation__c> recsById) {
        Set<Id> accepted = new Set<Id>();
        if (results == null) {
            return accepted;
        }
        for (FollowUpDraftResult result : results) {
            Follow_Up_Recommendation__c rec = recsById.get(result.recommendationId);
            if (rec == null || result.success != true) {
                continue;
            }
            if (!FollowUpDraftGuard.isSafe(result.subject, result.message, result.rationale)) {
                rec.AI_Rationale__c = Label.FollowUp_AI_Draft_Withheld;
                continue;
            }
            Boolean external = FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c);
            if (external && String.isNotBlank(result.message)) {
                rec.Draft_Message__c = result.message.left(10000);
                if (String.isNotBlank(result.subject)) {
                    rec.Draft_Subject__c = result.subject.left(255);
                }
                rec.Draft_Source__c = FollowUpConstants.DRAFT_AI;
            }
            if (String.isNotBlank(result.rationale)) {
                rec.AI_Rationale__c = result.rationale.left(5000);
            }
            accepted.add(rec.Id);
        }
        restorePlaceholders(recsById.values());
        return accepted;
    }

    /** Puts the client's date of birth back where the LLM kept FollowUpFactsBuilder.DOB_PLACEHOLDER. */
    // Same facts the template builder already used (selector context); the value never leaves Salesforce.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static void restorePlaceholders(List<Follow_Up_Recommendation__c> recs) {
        Set<Id> matterIds = new Set<Id>();
        for (Follow_Up_Recommendation__c rec : recs) {
            if (rec.Draft_Message__c != null && rec.Draft_Message__c.contains(FollowUpFactsBuilder.DOB_PLACEHOLDER)) {
                matterIds.add(rec.Matter__c);
            }
        }
        if (matterIds.isEmpty()) {
            return;
        }
        Map<Id, Matter__c> matters = new Map<Id, Matter__c>([SELECT Id, Client__r.Birthdate FROM Matter__c WHERE Id IN :matterIds]);
        for (Follow_Up_Recommendation__c rec : recs) {
            Matter__c matter = matters.get(rec.Matter__c);
            if (matter == null || rec.Draft_Message__c == null) {
                continue;
            }
            Date birthdate = matter.Client__r == null ? null : matter.Client__r.Birthdate;
            rec.Draft_Message__c = rec.Draft_Message__c.replace(
                FollowUpFactsBuilder.DOB_PLACEHOLDER,
                birthdate == null ? Label.FollowUp_Not_Recorded : birthdate.format()
            );
        }
    }

    /** Any draft change on an approved recommendation re-opens approval. */
    public static void resetApprovalIfNeeded(Follow_Up_Recommendation__c rec) {
        if (rec.Status__c == FollowUpConstants.STATUS_APPROVED || rec.Status__c == FollowUpConstants.STATUS_SEND_FAILED) {
            rec.Status__c = FollowUpConstants.STATUS_PENDING_REVIEW;
            rec.Approved_By__c = null;
            rec.Approved_Date__c = null;
        }
    }
}
