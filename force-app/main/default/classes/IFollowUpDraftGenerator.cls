/**
 * Generates client/provider drafts and rationale for saved recommendations.
 * Core ships no AI implementation; the agentforce package provides FollowUpEinsteinDraftGenerator.
 * Register an implementation in Follow_Up_Setting__mdt.AI_Draft_Generator_Class__c.
 * Implementations may perform callouts and MUST NOT perform DML (the caller persists results).
 */
public interface IFollowUpDraftGenerator {
    List<FollowUpDraftResult> generate(List<Follow_Up_Recommendation__c> recommendations);
}
