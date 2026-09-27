/**
 * Native Salesforce email delivery (Messaging.SingleEmailMessage), one bulk sendEmail call per invocation.
 * Sender: org-wide address from Follow_Up_Setting__mdt.Org_Wide_Email_Address__c when configured.
 * Activity logging is done by FollowUpSendService so every channel produces the same audit trail.
 */
@SuppressWarnings('PMD.ApexCRUDViolation') // OrgWideEmailAddress is setup data used only to pick the configured sender.
public with sharing class FollowUpEmailChannel implements IFollowUpChannel {
    public List<FollowUpDeliveryResult> deliver(List<Follow_Up_Recommendation__c> recommendations) {
        List<FollowUpDeliveryResult> results = new List<FollowUpDeliveryResult>();
        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        List<Follow_Up_Recommendation__c> queued = new List<Follow_Up_Recommendation__c>();
        Id orgWideAddressId = resolveOrgWideAddress();

        for (Follow_Up_Recommendation__c rec : recommendations) {
            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            if (rec.Audience__c == FollowUpConstants.AUDIENCE_CLIENT) {
                Contact client = rec.Recipient_Contact__r;
                if (client == null || String.isBlank(client.Email)) {
                    results.add(failure(rec, Label.FollowUp_Error_No_Recipient));
                    continue;
                }
                if (client.HasOptedOutOfEmail == true) {
                    results.add(new FollowUpDeliveryResult(rec.Id, false, Label.FollowUp_Error_Email_Opt_Out));
                    continue;
                }
                message.setTargetObjectId(client.Id);
            } else {
                String address = rec.Medical_Provider__r == null ? null : rec.Medical_Provider__r.Email__c;
                if (String.isBlank(address)) {
                    results.add(failure(rec, Label.FollowUp_Error_No_Recipient));
                    continue;
                }
                message.setToAddresses(new List<String>{ address });
            }
            message.setSubject(String.isBlank(rec.Draft_Subject__c) ? FollowUpConfig.firmName() : rec.Draft_Subject__c);
            message.setPlainTextBody(rec.Draft_Message__c);
            message.setSaveAsActivity(false);
            message.setUseSignature(false);
            if (orgWideAddressId != null) {
                message.setOrgWideEmailAddressId(orgWideAddressId);
            }
            messages.add(message);
            queued.add(rec);
        }
        if (messages.isEmpty()) {
            return results;
        }
        try {
            List<Messaging.SendEmailResult> sendResults = Messaging.sendEmail(messages, false);
            for (Integer i = 0; i < sendResults.size(); i++) {
                if (sendResults[i].isSuccess()) {
                    results.add(new FollowUpDeliveryResult(queued[i].Id, true, 'Email sent.'));
                } else {
                    String error = sendResults[i].getErrors().isEmpty() ? 'Email not sent.' : sendResults[i].getErrors()[0].getMessage();
                    results.add(new FollowUpDeliveryResult(queued[i].Id, false, error));
                }
            }
        } catch (EmailException e) {
            // e.g. deliverability disabled or daily limit reached: nothing was sent.
            for (Follow_Up_Recommendation__c rec : queued) {
                results.add(new FollowUpDeliveryResult(rec.Id, false, e.getMessage()));
            }
        }
        return results;
    }

    private static FollowUpDeliveryResult failure(Follow_Up_Recommendation__c rec, String template) {
        return new FollowUpDeliveryResult(rec.Id, false, String.format(template, new List<String>{ rec.Name }));
    }

    private static Id resolveOrgWideAddress() {
        String address = FollowUpConfig.getSetting().Org_Wide_Email_Address__c;
        if (String.isBlank(address)) {
            return null;
        }
        List<OrgWideEmailAddress> matches = [SELECT Id FROM OrgWideEmailAddress WHERE Address = :address.trim() LIMIT 1];
        return matches.isEmpty() ? null : matches[0].Id;
    }
}
