/**
 * Deterministic template drafts built only from verified matter facts and Custom Label templates.
 * Always available (no AI dependency) and the baseline that AI drafts may refine.
 * Internal recommendations get no draft message.
 */
public with sharing class FollowUpDraftBuilder {
    public static void applyTemplate(Follow_Up_Recommendation__c rec, FollowUpMatterContext ctx) {
        rec.Draft_Subject__c = null;
        rec.Draft_Message__c = null;
        rec.Draft_Source__c = null;
        if (rec.Audience__c == FollowUpConstants.AUDIENCE_INTERNAL || ctx == null) {
            return;
        }
        String firm = FollowUpConfig.firmName();
        String sender = senderName(ctx, firm);
        if (rec.Recommendation_Type__c == FollowUpConstants.TYPE_CLIENT_CHECK_IN) {
            buildClientCheckIn(rec, ctx, sender, firm);
        } else if (rec.Recommendation_Type__c == FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP) {
            buildProviderFollowUp(rec, ctx, sender, firm);
        } else if (rec.Recommendation_Type__c == FollowUpConstants.TYPE_CLIENT_STATUS_UPDATE) {
            buildStatusUpdate(rec, ctx, sender, firm);
        }
        if (rec.Draft_Message__c != null) {
            rec.Draft_Source__c = FollowUpConstants.DRAFT_TEMPLATE;
        }
    }

    private static void buildClientCheckIn(Follow_Up_Recommendation__c rec, FollowUpMatterContext ctx, String sender, String firm) {
        String firstName = clientFirstName(ctx);
        if (rec.Channel__c == FollowUpConstants.CHANNEL_SMS) {
            rec.Draft_Message__c = FollowUpRuleEngine.format(Label.FollowUp_Draft_CheckIn_SMS, new List<Object>{ firstName, sender, firm });
        } else if (rec.Channel__c == FollowUpConstants.CHANNEL_PHONE) {
            rec.Draft_Message__c = FollowUpRuleEngine.format(
                Label.FollowUp_Draft_CheckIn_Call_Script,
                new List<Object>{ firstName, FollowUpRuleEngine.formatDate(ctx.lastTreatmentDate) }
            );
        } else {
            rec.Draft_Subject__c = Label.FollowUp_Draft_CheckIn_Subject;
            rec.Draft_Message__c = ctx.lastTreatmentDate == null
                ? FollowUpRuleEngine.format(Label.FollowUp_Draft_CheckIn_No_Treatment_Body, new List<Object>{ firstName, sender, firm })
                : FollowUpRuleEngine.format(
                      Label.FollowUp_Draft_CheckIn_Body,
                      new List<Object>{ firstName, sender, firm, FollowUpRuleEngine.formatDate(ctx.lastTreatmentDate) }
                  );
        }
    }

    private static void buildProviderFollowUp(Follow_Up_Recommendation__c rec, FollowUpMatterContext ctx, String sender, String firm) {
        Records_Request__c req = findRequest(ctx, rec.Records_Request__c);
        Medical_Provider__c provider = ctx.providers.get(rec.Medical_Provider__c);
        Contact client = ctx.client();
        String patientName = client == null ? Label.FollowUp_Not_Recorded : client.Name;
        String birthDate = client == null ? Label.FollowUp_Not_Recorded : FollowUpRuleEngine.formatDate(client.Birthdate);
        String requestType = (req == null || String.isBlank(req.Request_Type__c))
            ? Label.FollowUp_Not_Recorded
            : req.Request_Type__c.toLowerCase();
        Integer followUpNumber = (rec.Prior_Follow_Up_Count__c == null ? 0 : rec.Prior_Follow_Up_Count__c.intValue()) + 1;
        rec.Draft_Subject__c = FollowUpRuleEngine.format(
            Label.FollowUp_Draft_Provider_Subject,
            new List<Object>{ patientName, requestType }
        );
        rec.Draft_Message__c = FollowUpRuleEngine.format(
            Label.FollowUp_Draft_Provider_Body,
            new List<Object>{
                provider == null ? Label.FollowUp_Not_Recorded : provider.Name,
                requestType,
                FollowUpRuleEngine.formatDate(req == null ? null : req.Requested_Date__c),
                patientName,
                birthDate,
                followUpNumber,
                sender,
                firm
            }
        );
    }

    private static void buildStatusUpdate(Follow_Up_Recommendation__c rec, FollowUpMatterContext ctx, String sender, String firm) {
        rec.Draft_Subject__c = FollowUpRuleEngine.format(Label.FollowUp_Draft_Status_Update_Subject, new List<Object>{ firm });
        rec.Draft_Message__c = FollowUpRuleEngine.format(
            Label.FollowUp_Draft_Status_Update_Body,
            new List<Object>{
                clientFirstName(ctx),
                firm,
                String.isBlank(ctx.matter.Status__c) ? Label.FollowUp_Not_Recorded : ctx.matter.Status__c,
                ctx.providersReceivedCount(),
                ctx.providersRequestedCount(),
                sender
            }
        );
    }

    private static Records_Request__c findRequest(FollowUpMatterContext ctx, Id requestId) {
        for (Records_Request__c req : ctx.requests) {
            if (req.Id == requestId) {
                return req;
            }
        }
        return null;
    }

    private static String clientFirstName(FollowUpMatterContext ctx) {
        Contact client = ctx.client();
        if (client == null) {
            return Label.FollowUp_Not_Recorded;
        }
        return String.isNotBlank(client.FirstName) ? client.FirstName : client.Name;
    }

    private static String senderName(FollowUpMatterContext ctx, String firm) {
        String name = ctx.assigneeName();
        return String.isBlank(name) ? firm : name;
    }
}
