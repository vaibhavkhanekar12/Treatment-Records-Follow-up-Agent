/**
 * Read-only data access for the optional inbound-email review list.
 * The core follow-up workflow uses existing Matter, Treatment Event, and Records Request records.
 */
public with sharing class AutomaticIntakeReviewController {
    @AuraEnabled(cacheable=true)
    public static List<Automatic_Intake__c> getOpenIntakes() {
        return [
            SELECT Id, Name, Sender_Email__c, Subject__c, Received_At__c,
                   Status__c, Classification__c, Attachment_Count__c, Review_Reason__c
            FROM Automatic_Intake__c
            WHERE Status__c IN ('Received', 'Needs Review', 'Failed')
            WITH USER_MODE
            ORDER BY Received_At__c DESC NULLS LAST
            LIMIT 100
        ];
    }
}
