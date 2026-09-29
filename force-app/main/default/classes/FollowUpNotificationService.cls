/**
 * Internal Salesforce notification for newly-created recommendations.
 * Notifications never contact a client/provider and do not bypass approval/send controls.
 */
public with sharing class FollowUpNotificationService {
    private static final String NOTIFICATION_DEVELOPER_NAME = 'Follow_Up_Recommendation_Notification';
    private static final Integer MAX_NOTIFICATIONS_PER_RUN = 500;

    public static void notifyCaseManagers(List<Follow_Up_Recommendation__c> recommendations) {
        if (recommendations == null || recommendations.isEmpty()) return;
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_DEVELOPER_NAME
            LIMIT 1
        ];
        if (types.isEmpty()) return;
        Integer sent = 0;
        for (Follow_Up_Recommendation__c rec : recommendations) {
            if (sent >= MAX_NOTIFICATIONS_PER_RUN) break;
            if (rec == null || rec.Assigned_To__c == null || rec.Matter__c == null) continue;
            try {
                Messaging.CustomNotification n = new Messaging.CustomNotification();
                n.setNotificationTypeId(types[0].Id);
                n.setTitle('Follow-up recommendation needs review');
                n.setBody((rec.Name == null ? 'A new follow-up recommendation' : rec.Name) + ' is waiting in the Work Queue.');
                n.setTargetId(rec.Matter__c);
                n.send(new Set<String>{ String.valueOf(rec.Assigned_To__c) });
                sent++;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Follow-up notification failed for ' + rec.Id + ': ' + e.getMessage());
            }
        }
    }
}
