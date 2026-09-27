/**
 * Sends approved follow-ups. This is the ONLY code path that delivers client/provider communication.
 *
 * Server-side guarantees (the LWC cannot bypass them):
 *  - Follow_Up_Send_Communications custom permission;
 *  - record read (USER_MODE) and edit access;
 *  - external audiences: status must be Approved (or Send_Failed retry) with an approval stamp;
 *  - recipients are resolved from the Contact / Medical Provider records, never from UI input;
 *  - a validation rule independently blocks Sent without approval for any other writer.
 *
 * Channel order: registered integration channels (possible callouts) run first, then email, then
 * manual Task channels (DML), because callouts are not allowed after uncommitted DML.
 */
public with sharing class FollowUpSendService {
    public class SendOutcome {
        @AuraEnabled
        public Integer sent = 0;
        @AuraEnabled
        public Integer failed = 0;
        @AuraEnabled
        public List<String> errors = new List<String>();
    }

    @TestVisible
    private static Map<String, IFollowUpChannel> channelOverrides = new Map<String, IFollowUpChannel>();

    public static SendOutcome send(List<Id> recommendationIds) {
        FollowUpSecurity.requirePermission(FollowUpConstants.PERM_SEND, Label.FollowUp_Error_No_Send_Permission);
        List<Follow_Up_Recommendation__c> recs = FollowUpRecommendationService.loadForAction(new Set<Id>(recommendationIds));
        for (Follow_Up_Recommendation__c rec : recs) {
            validateSendable(rec);
        }

        Map<String, List<Follow_Up_Recommendation__c>> byChannel = groupByChannel(recs);
        List<FollowUpDeliveryResult> results = new List<FollowUpDeliveryResult>();
        // 1. integration channels (callouts), 2. email, 3. manual Tasks (DML)
        for (String channelKey : orderedChannelKeys(byChannel.keySet())) {
            results.addAll(resolveChannel(channelKey).deliver(byChannel.get(channelKey)));
        }
        return applyResults(recs, results);
    }

    private static void validateSendable(Follow_Up_Recommendation__c rec) {
        Boolean external = FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c);
        if (external) {
            Boolean approved =
                (rec.Status__c == FollowUpConstants.STATUS_APPROVED ||
                rec.Status__c == FollowUpConstants.STATUS_SEND_FAILED) &&
                rec.Approved_By__c != null &&
                rec.Approved_Date__c != null;
            if (!approved) {
                throw new FollowUpException(String.format(Label.FollowUp_Error_Not_Approved, new List<String>{ rec.Name }));
            }
            if (String.isBlank(rec.Draft_Message__c)) {
                throw new FollowUpException(String.format(Label.FollowUp_Error_Empty_Draft, new List<String>{ rec.Name }));
            }
        } else {
            FollowUpRecommendationService.requireStatus(rec, FollowUpConstants.OPEN_STATUSES);
        }
    }

    /** Channel key: Email, SMS, Fax or MANUAL (phone call, internal task, or a channel without integration). */
    private static Map<String, List<Follow_Up_Recommendation__c>> groupByChannel(List<Follow_Up_Recommendation__c> recs) {
        Map<String, List<Follow_Up_Recommendation__c>> byChannel = new Map<String, List<Follow_Up_Recommendation__c>>();
        for (Follow_Up_Recommendation__c rec : recs) {
            String key = channelKeyFor(rec);
            if (!byChannel.containsKey(key)) {
                byChannel.put(key, new List<Follow_Up_Recommendation__c>());
            }
            byChannel.get(key).add(rec);
        }
        return byChannel;
    }

    private static String channelKeyFor(Follow_Up_Recommendation__c rec) {
        if (rec.Audience__c == FollowUpConstants.AUDIENCE_INTERNAL) {
            return 'MANUAL';
        }
        if (rec.Channel__c == FollowUpConstants.CHANNEL_EMAIL) {
            return FollowUpConstants.CHANNEL_EMAIL;
        }
        if (rec.Channel__c == FollowUpConstants.CHANNEL_SMS && integrationFor(FollowUpConstants.CHANNEL_SMS) != null) {
            return FollowUpConstants.CHANNEL_SMS;
        }
        if (rec.Channel__c == FollowUpConstants.CHANNEL_FAX && integrationFor(FollowUpConstants.CHANNEL_FAX) != null) {
            return FollowUpConstants.CHANNEL_FAX;
        }
        return 'MANUAL';
    }

    private static List<String> orderedChannelKeys(Set<String> keys) {
        List<String> ordered = new List<String>();
        for (
            String key : new List<String>{
                FollowUpConstants.CHANNEL_SMS,
                FollowUpConstants.CHANNEL_FAX,
                FollowUpConstants.CHANNEL_EMAIL,
                'MANUAL'
            }
        ) {
            if (keys.contains(key)) {
                ordered.add(key);
            }
        }
        return ordered;
    }

    private static IFollowUpChannel resolveChannel(String channelKey) {
        if (channelOverrides.containsKey(channelKey)) {
            return channelOverrides.get(channelKey);
        }
        if (channelKey == FollowUpConstants.CHANNEL_EMAIL) {
            return new FollowUpEmailChannel();
        }
        if (channelKey == 'MANUAL') {
            return new FollowUpManualChannel();
        }
        return integrationFor(channelKey);
    }

    /** Registered integration (Follow_Up_Setting__mdt SMS_Channel_Class__c / Fax_Channel_Class__c) or null. */
    private static IFollowUpChannel integrationFor(String channel) {
        if (channelOverrides.containsKey(channel)) {
            return channelOverrides.get(channel);
        }
        Follow_Up_Setting__mdt setting = FollowUpConfig.getSetting();
        String className = channel == FollowUpConstants.CHANNEL_SMS ? setting.SMS_Channel_Class__c : setting.Fax_Channel_Class__c;
        if (String.isBlank(className)) {
            return null;
        }
        Type channelType = Type.forName(className.trim());
        Object instance = channelType == null ? null : channelType.newInstance();
        return instance instanceof IFollowUpChannel ? (IFollowUpChannel) instance : null;
    }

    private static SendOutcome applyResults(List<Follow_Up_Recommendation__c> recs, List<FollowUpDeliveryResult> results) {
        SendOutcome outcome = new SendOutcome();
        Map<Id, Follow_Up_Recommendation__c> byId = new Map<Id, Follow_Up_Recommendation__c>(recs);
        List<Follow_Up_Recommendation__c> updates = new List<Follow_Up_Recommendation__c>();
        List<Task> activityLog = new List<Task>();
        for (FollowUpDeliveryResult result : results) {
            Follow_Up_Recommendation__c rec = byId.get(result.recommendationId);
            if (rec == null) {
                continue;
            }
            Follow_Up_Recommendation__c patch = new Follow_Up_Recommendation__c(
                Id = rec.Id,
                Delivery_Note__c = result.note == null ? null : result.note.left(255)
            );
            if (result.success) {
                outcome.sent++;
                patch.Status__c = FollowUpConstants.STATUS_SENT;
                patch.Sent_Date__c = System.now();
                patch.Sent_By__c = UserInfo.getUserId();
                patch.Task_Id__c = result.taskId;
                if (result.taskId == null) {
                    activityLog.add(outboundLogTask(rec));
                }
            } else {
                outcome.failed++;
                outcome.errors.add(rec.Name + ': ' + result.note);
                patch.Status__c = FollowUpConstants.EXTERNAL_AUDIENCES.contains(rec.Audience__c)
                    ? FollowUpConstants.STATUS_SEND_FAILED
                    : rec.Status__c;
            }
            updates.add(patch);
        }
        Database.update(updates, true, AccessLevel.SYSTEM_MODE);
        if (!activityLog.isEmpty()) {
            Database.insert(activityLog, true, AccessLevel.SYSTEM_MODE);
        }
        return outcome;
    }

    /** Completed activity recording exactly what was sent, to whom and when (audit trail). */
    private static Task outboundLogTask(Follow_Up_Recommendation__c rec) {
        return new Task(
            WhatId = rec.Matter__c,
            WhoId = rec.Audience__c == FollowUpConstants.AUDIENCE_CLIENT ? rec.Recipient_Contact__c : null,
            OwnerId = UserInfo.getUserId(),
            Subject = (FollowUpMatterSelector.OUTBOUND_TASK_PREFIX +
                ' ' +
                rec.Channel__c +
                ' - ' +
                FollowUpEvaluationService.typeLabel(rec.Recommendation_Type__c))
                .left(255),
            Description = (String.isBlank(rec.Draft_Subject__c) ? '' : rec.Draft_Subject__c + '\n\n') + rec.Draft_Message__c,
            ActivityDate = Date.today(),
            Status = 'Completed'
        );
    }
}
