/**
 * Creates an in-app Salesforce notification for newly-created follow-up recommendations.
 * Communication to clients/providers remains behind the existing human approval and send controls.
 */
public with sharing class FollowUpNotificationService {
    public static void notifyCaseManagers(List<Follow_Up_Recommendation__c> recommendations) {
        if (recommendations == null || recommendations.isEmpty()) return;
        Set<Id> recipients = new Set<Id>();
        for (Follow_Up_Recommendation__c rec : recommendations) {
            if (rec.Assigned_To__c != null) recipients.add(rec.Assigned_To__c);
        }
        if (recipients.isEmpty()) return;
        List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'Follow_Up_Recommendation_Notification' LIMIT 1];
        if (types.isEmpty()) return;
        for (Id userId : recipients) {
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle('Follow-up recommendation needs review');
            n.setBody('A new treatment or records follow-up recommendation is waiting in the Work Queue.');
            n.setTargetId(recommendations[0].Matter__c);
            n.send(new Set<String>{ String.valueOf(userId) });
        }
    }
}
