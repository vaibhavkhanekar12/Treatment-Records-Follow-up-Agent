/**
 * Trigger handler for the existing Treatment Visits object.
 * Re-evaluates affected Matters asynchronously after visit changes.
 */
public without sharing class FollowUpTreatmentVisitTriggerHandler {
    @TestVisible
    private static Boolean bypass = false;

    public static void afterSave(List<Treatment_Visits__c> newRecords, Map<Id, Treatment_Visits__c> oldMap) {
        if (bypass || newRecords == null || newRecords.isEmpty()) {
            return;
        }

        Set<Id> matterIds = new Set<Id>();
        for (Treatment_Visits__c visitRecord : newRecords) {
            if (visitRecord.Matter__c == null) {
                continue;
            }

            if (oldMap == null) {
                matterIds.add(visitRecord.Matter__c);
                continue;
            }

            Treatment_Visits__c oldRecord = oldMap.get(visitRecord.Id);
            if (
                oldRecord == null ||
                oldRecord.Matter__c != visitRecord.Matter__c ||
                oldRecord.Visit_Start__c != visitRecord.Visit_Start__c ||
                oldRecord.Visit_End__c != visitRecord.Visit_End__c ||
                oldRecord.Provider__c != visitRecord.Provider__c ||
                oldRecord.Visit_Attended__c != visitRecord.Visit_Attended__c ||
                oldRecord.Visit_Type__c != visitRecord.Visit_Type__c
            ) {
                matterIds.add(visitRecord.Matter__c);
                if (oldRecord != null && oldRecord.Matter__c != null) {
                    matterIds.add(oldRecord.Matter__c);
                }
            }
        }

        if (!matterIds.isEmpty()) {
            System.enqueueJob(new FollowUpTreatmentVisitEvalQueueable(matterIds));
        }
    }
}
