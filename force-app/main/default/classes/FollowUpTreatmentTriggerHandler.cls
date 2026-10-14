/**
 * Backward-compatible handler for the old Treatment Event trigger.
 *
 * The production implementation uses Treatment_Visits__c. This handler remains
 * only so existing branches can compile while the old trigger/class are removed
 * from the deployment package in this branch.
 */
public without sharing class FollowUpTreatmentTriggerHandler {
    @TestVisible
    private static Boolean bypass = false;

    public static void afterSave(List<Treatment_Event__c> newRecords, Map<Id, Treatment_Event__c> oldMap) {
        // No-op: all live follow-up evaluation now reads Treatment_Visits__c.
        // The old trigger should not be deployed to the Personal Injury org.
    }
}