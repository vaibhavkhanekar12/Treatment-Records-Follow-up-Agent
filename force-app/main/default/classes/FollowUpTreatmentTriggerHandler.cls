/**
 * Bulk-safe handler for Treatment Event changes.
 * Re-evaluates affected matters asynchronously so a Treatment Event save can create or supersede
 * follow-up recommendations without adding cross-object evaluation work to the save transaction.
 */
public without sharing class FollowUpTreatmentTriggerHandler {
    @TestVisible
    private static Boolean bypass = false;

    public static void afterSave(List<Treatment_Event__c> newRecords, Map<Id, Treatment_Event__c> oldMap) {
        if (bypass || newRecords == null || newRecords.isEmpty()) {
            return;
        }

        Set<Id> matterIds = new Set<Id>();
        for (Treatment_Event__c eventRecord : newRecords) {
            if (eventRecord.Matter__c == null) {
                continue;
            }

            if (oldMap == null) {
                matterIds.add(eventRecord.Matter__c);
                continue;
            }

            Treatment_Event__c oldRecord = oldMap.get(eventRecord.Id);
            if (oldRecord == null ||
                oldRecord.Matter__c != eventRecord.Matter__c ||
                oldRecord.Treatment_Date__c != eventRecord.Treatment_Date__c ||
                oldRecord.Status__c != eventRecord.Status__c ||
                oldRecord.Medical_Provider__c != eventRecord.Medical_Provider__c) {
                matterIds.add(eventRecord.Matter__c);
                if (oldRecord != null && oldRecord.Matter__c != null) {
                    matterIds.add(oldRecord.Matter__c);
                }
            }
        }

        if (!matterIds.isEmpty()) {
            System.enqueueJob(new FollowUpTreatmentEventEvalQueueable(matterIds));
        }
    }
}
