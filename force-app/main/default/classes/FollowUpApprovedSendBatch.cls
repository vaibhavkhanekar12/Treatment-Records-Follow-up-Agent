/**
 * Sends already-approved external follow-ups whose Recommended Date is due.
 * This does not approve, edit, or create recommendations. FollowUpSendService remains the only delivery path.
 */
public with sharing class FollowUpApprovedSendBatch implements Database.Batchable<SObject>, Database.Stateful {
    private Integer sentCount = 0;
    private Integer failedCount = 0;

    public Database.QueryLocator start(Database.BatchableContext context) {
        Date today = Date.today();
        return Database.getQueryLocator([
            SELECT Id, Draft_Message__c
            FROM Follow_Up_Recommendation__c
            WHERE Status__c = :FollowUpConstants.STATUS_APPROVED
              AND Audience__c IN :FollowUpConstants.EXTERNAL_AUDIENCES
              AND Recommended_Date__c <= :today
            ORDER BY Recommended_Date__c ASC, Id ASC
        ]);
    }

    public void execute(Database.BatchableContext context, List<Follow_Up_Recommendation__c> scope) {
        List<Id> ids = new List<Id>();
        for (Follow_Up_Recommendation__c rec : scope) {
            if (String.isNotBlank(rec.Draft_Message__c)) ids.add(rec.Id);
        }
        if (ids.isEmpty()) return;

        try {
            FollowUpSendService.SendOutcome outcome = FollowUpSendService.send(ids);
            sentCount += outcome.sent;
            failedCount += outcome.failed;
        } catch (Exception e) {
            failedCount += ids.size();
            System.debug(LoggingLevel.ERROR, 'Scheduled follow-up send failed: ' + e.getMessage());
        }
    }

    public void finish(Database.BatchableContext context) {
        System.debug(LoggingLevel.INFO,
            'Scheduled approved follow-up send completed. Sent=' + sentCount + ', Failed=' + failedCount);
    }
}
