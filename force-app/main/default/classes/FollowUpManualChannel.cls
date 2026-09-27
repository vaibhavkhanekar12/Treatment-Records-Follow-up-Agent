/**
 * Default channel for internal recommendations, phone calls, and SMS/fax when no integration is registered.
 * Creates one Task per recommendation assigned to the case manager, containing the approved text and the
 * recipient's phoneNumber from the Contact / Medical Provider record, so the message is delivered through the
 * firm's existing tool. The recommendation is marked Sent with a delivery note saying it was queued for
 * manual delivery, and completes automatically when the Task is completed (Follow_Up_Task_Completed flow).
 */
public with sharing class FollowUpManualChannel implements IFollowUpChannel {
    public List<FollowUpDeliveryResult> deliver(List<Follow_Up_Recommendation__c> recommendations) {
        List<Task> tasks = new List<Task>();
        for (Follow_Up_Recommendation__c rec : recommendations) {
            Task task = FollowUpEvaluationService.buildTask(rec, rec.Matter__r == null ? '' : rec.Matter__r.Name);
            if (rec.Audience__c != FollowUpConstants.AUDIENCE_INTERNAL) {
                // Outbound prefix: completing this delivery Task is not "client contact" for the stalled rule.
                task.Subject = (FollowUpMatterSelector.OUTBOUND_TASK_PREFIX +
                    ' deliver approved ' +
                    rec.Channel__c +
                    ' - ' +
                    rec.Name)
                    .left(255);
                task.Description =
                    recipientLine(rec) +
                    '\n\n' +
                    (String.isBlank(rec.Draft_Subject__c) ? '' : rec.Draft_Subject__c + '\n\n') +
                    rec.Draft_Message__c;
                if (rec.Audience__c == FollowUpConstants.AUDIENCE_CLIENT) {
                    task.WhoId = rec.Recipient_Contact__c;
                }
            }
            if (task.OwnerId == null) {
                task.OwnerId = UserInfo.getUserId();
            }
            tasks.add(task);
        }
        List<Database.SaveResult> saveResults = Database.insert(tasks, false, AccessLevel.SYSTEM_MODE);
        List<FollowUpDeliveryResult> results = new List<FollowUpDeliveryResult>();
        for (Integer i = 0; i < saveResults.size(); i++) {
            Follow_Up_Recommendation__c rec = recommendations[i];
            if (saveResults[i].isSuccess()) {
                FollowUpDeliveryResult result = new FollowUpDeliveryResult(
                    rec.Id,
                    true,
                    rec.Audience__c == FollowUpConstants.AUDIENCE_INTERNAL ? 'Task assigned.' : 'Queued for manual delivery (Task created).'
                );
                result.taskId = saveResults[i].getId();
                results.add(result);
            } else {
                results.add(new FollowUpDeliveryResult(rec.Id, false, saveResults[i].getErrors()[0].getMessage()));
            }
        }
        return results;
    }

    private static String recipientLine(Follow_Up_Recommendation__c rec) {
        if (rec.Audience__c == FollowUpConstants.AUDIENCE_CLIENT && rec.Recipient_Contact__r != null) {
            Contact client = rec.Recipient_Contact__r;
            String phoneNumber = rec.Channel__c == FollowUpConstants.CHANNEL_SMS ? client.MobilePhone : client.Phone;
            return 'Recipient: ' + client.Name + ' (' + (String.isBlank(phoneNumber) ? Label.FollowUp_Not_Recorded : phoneNumber) + ')';
        }
        if (rec.Medical_Provider__r != null) {
            Medical_Provider__c provider = rec.Medical_Provider__r;
            String phoneNumber = rec.Channel__c == FollowUpConstants.CHANNEL_FAX ? provider.Fax__c : provider.Phone__c;
            return 'Recipient: ' + provider.Name + ' (' + (String.isBlank(phoneNumber) ? Label.FollowUp_Not_Recorded : phoneNumber) + ')';
        }
        return 'Recipient: ' + Label.FollowUp_Not_Recorded;
    }
}
