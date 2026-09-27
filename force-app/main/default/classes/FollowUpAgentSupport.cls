/**
 * Shared helpers for the Agentforce invocable actions: matter resolution in the running user's context
 * and user-initiated evaluation. Agent actions run as the employee using the agent, so every lookup is
 * WITH USER_MODE and nothing is returned for matters the user cannot see.
 */
public with sharing class FollowUpAgentSupport {
    public static final String CATEGORY = 'Treatment & Records Follow-up';

    public static Map<Id, Matter__c> readableMatters(List<Id> matterIds, List<String> matterNames) {
        Set<Id> ids = new Set<Id>();
        Set<String> names = new Set<String>();
        for (Id matterId : matterIds) {
            if (matterId != null) {
                ids.add(matterId);
            }
        }
        for (String name : matterNames) {
            if (String.isNotBlank(name)) {
                names.add(name.trim());
            }
        }
        return FollowUpSecurity.readableMatters(ids, names);
    }

    /** Finds the matter by Id, else by exact name. Returns null when not found or not accessible. */
    public static Matter__c findMatter(Map<Id, Matter__c> readable, Id matterId, String matterName) {
        if (matterId != null) {
            return readable.get(matterId);
        }
        if (String.isNotBlank(matterName)) {
            for (Matter__c matter : readable.values()) {
                if (matter.Name == matterName.trim()) {
                    return matter;
                }
            }
        }
        return null;
    }

    /** Runs the deterministic rules for matters the user can read, on the user's behalf. */
    public static FollowUpEvaluationService.Summary evaluateForUser(Set<Id> matterIds, String source) {
        FollowUpSecurity.requireSourceDataAccess();
        if (!Schema.SObjectType.Follow_Up_Recommendation__c.isCreateable()) {
            throw new FollowUpException(Label.FollowUp_Error_No_Access);
        }
        if (!FollowUpSecurity.readableMatters(matterIds, null).keySet().containsAll(matterIds)) {
            throw new FollowUpException(Label.FollowUp_Error_Matter_Not_Found);
        }
        return FollowUpEvaluationService.evaluate(matterIds, source + '-' + UserInfo.getUserId());
    }

    public static String errorMessage(Exception e) {
        if (e instanceof FollowUpException) {
            return e.getMessage();
        }
        if (e instanceof DmlException) {
            return ((DmlException) e).getDmlMessage(0);
        }
        return 'The follow-up action could not be completed: ' + e.getMessage();
    }
}
