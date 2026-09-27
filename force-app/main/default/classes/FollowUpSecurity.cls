/**
 * Server-side authorization checks shared by the work queue, the agent actions and the send service.
 * UI restrictions are convenience only; every mutating entry point calls these checks.
 */
public with sharing class FollowUpSecurity {
    private static final Integer USER_RECORD_ACCESS_CHUNK = 200;

    public static Boolean hasPermission(String customPermission) {
        return FeatureManagement.checkPermission(customPermission);
    }

    public static void requirePermission(String customPermission, String errorMessage) {
        if (!hasPermission(customPermission)) {
            throw new FollowUpException(errorMessage);
        }
    }

    /** Verifies the running user can edit every record (sharing + object permission), 200 Ids per query. */
    // UserRecordAccess accepts at most 200 record Ids per query and has no user CRUD; the loop is bounded by that chunking.
    @SuppressWarnings('PMD.ApexCRUDViolation, PMD.OperationWithLimitsInLoop')
    public static void requireEditAccess(Set<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) {
            return;
        }
        List<Id> ids = new List<Id>(recordIds);
        Set<Id> editable = new Set<Id>();
        for (Integer start = 0; start < ids.size(); start += USER_RECORD_ACCESS_CHUNK) {
            List<Id> chunk = new List<Id>();
            for (Integer i = start; i < Math.min(start + USER_RECORD_ACCESS_CHUNK, ids.size()); i++) {
                chunk.add(ids[i]);
            }
            for (UserRecordAccess access : [
                SELECT RecordId, HasEditAccess
                FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId IN :chunk
            ]) {
                if (access.HasEditAccess) {
                    editable.add(access.RecordId);
                }
            }
        }
        if (!editable.containsAll(recordIds)) {
            throw new FollowUpException(Label.FollowUp_Error_No_Access);
        }
    }

    /** Object-level read access to the treatment/records data the agent and work queue summarise. */
    public static void requireSourceDataAccess() {
        if (
            !Schema.SObjectType.Matter__c.isAccessible() ||
            !Schema.SObjectType.Treatment_Event__c.isAccessible() ||
            !Schema.SObjectType.Records_Request__c.isAccessible() ||
            !Schema.SObjectType.Follow_Up_Recommendation__c.isAccessible() ||
            !Schema.SObjectType.Treatment_Event__c.fields.Treatment_Date__c.isAccessible() ||
            !Schema.SObjectType.Records_Request__c.fields.Requested_Date__c.isAccessible()
        ) {
            throw new FollowUpException(Label.FollowUp_Error_No_Access);
        }
    }

    /**
     * Returns the subset of matter Ids the running user can read (WITH USER_MODE enforces sharing, CRUD and FLS).
     * Also accepts matter names so the agent can resolve "matter M-1234" without exposing record Ids.
     */
    public static Map<Id, Matter__c> readableMatters(Set<Id> matterIds, Set<String> matterNames) {
        Set<Id> ids = matterIds == null ? new Set<Id>() : matterIds;
        Set<String> names = matterNames == null ? new Set<String>() : matterNames;
        if (ids.isEmpty() && names.isEmpty()) {
            return new Map<Id, Matter__c>();
        }
        return new Map<Id, Matter__c>(
            [
                SELECT Id, Name
                FROM Matter__c
                WHERE Id IN :ids OR Name IN :names
                WITH USER_MODE
                LIMIT 2000
            ]
        );
    }
}
