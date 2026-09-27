/**
 * Renders verified matter facts as plain text for the Agentforce actions and Prompt Builder grounding.
 *
 * Grounding rules (enforced here, not left to the LLM):
 *  - only operational facts: dates, day counts, provider names, statuses, counts;
 *  - no Salesforce record Ids, no clinical fields (diagnosis, notes, codes), no amounts;
 *  - client identified by first name only; the date of birth that provider drafts need is replaced by
 *    DOB_PLACEHOLDER before it reaches the LLM and restored server-side afterwards (FollowUpDraftService);
 *  - missing values are rendered as "Not recorded" so the model never has to guess.
 */
public with sharing class FollowUpFactsBuilder {
    public static final String DOB_PLACEHOLDER = '[DATE OF BIRTH]';

    public static String matterFacts(FollowUpMatterContext ctx, Date today) {
        Set<String> outstandingStatuses = FollowUpConfig.outstandingRequestStatuses();
        List<String> lines = new List<String>();
        lines.add('Matter: ' + ctx.matter.Name);
        lines.add('Matter stage: ' + valueOrMissing(ctx.matter.Status__c));
        Contact client = ctx.client();
        lines.add('Client first name: ' + (client == null ? Label.FollowUp_Not_Recorded : valueOrMissing(client.FirstName)));
        lines.add('Sign-up date: ' + FollowUpRuleEngine.formatDate(ctx.matter.Sign_Up_Date__c));
        lines.add('Last recorded treatment: ' + dateWithAge(ctx.lastTreatmentDate, today));
        lines.add('Next scheduled treatment: ' + FollowUpRuleEngine.formatDate(ctx.nextScheduledTreatmentDate));

        List<Records_Request__c> outstanding = ctx.outstandingRequests(outstandingStatuses);
        lines.add('Outstanding records requests: ' + outstanding.size());
        for (Records_Request__c req : outstanding) {
            Medical_Provider__c provider = ctx.providers.get(req.Medical_Provider__c);
            Integer sent = ctx.sentForKey(FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP, req.Id)).size();
            lines.add(
                '  - ' +
                    (provider == null ? Label.FollowUp_Not_Recorded : provider.Name) +
                    ': ' +
                    valueOrMissing(req.Request_Type__c) +
                    ' requested ' +
                    dateWithAge(req.Requested_Date__c, today) +
                    '; status ' +
                    valueOrMissing(req.Status__c) +
                    '; follow-ups sent ' +
                    sent
            );
        }
        lines.add('Providers with records received: ' + ctx.providersReceivedCount() + ' of ' + ctx.providersRequestedCount());
        lines.add('Last records activity: ' + dateWithAge(ctx.lastRecordsActivity(), today));
        lines.add('Last client contact: ' + dateWithAge(ctx.lastClientContactDate, today));
        lines.add('Flagged as potentially stalled: ' + (ctx.matter.Stalled__c == true ? 'Yes' : 'No'));

        List<Follow_Up_Recommendation__c> open = ctx.openRecommendations();
        lines.add('Open follow-up recommendations: ' + open.size());
        for (Follow_Up_Recommendation__c rec : open) {
            lines.add('  - ' + rec.Name + ': ' + rec.Recommendation_Type__c + ' (' + rec.Status__c + ', ' + rec.Priority__c + ' priority)');
        }
        return String.join(lines, '\n');
    }

    /** Recommendation-specific facts appended to the matter facts for drafting/classification prompts. */
    public static String recommendationFacts(Follow_Up_Recommendation__c rec, FollowUpMatterContext ctx) {
        List<String> lines = new List<String>();
        lines.add('Recommendation: ' + rec.Name);
        lines.add('Recommendation type: ' + rec.Recommendation_Type__c);
        lines.add('Audience: ' + valueOrMissing(rec.Audience__c));
        lines.add('Channel: ' + valueOrMissing(rec.Channel__c));
        lines.add('Priority: ' + valueOrMissing(rec.Priority__c));
        lines.add('Reason (verified facts): ' + valueOrMissing(rec.Reason__c));
        if (rec.Medical_Provider__c != null && ctx != null && ctx.providers.containsKey(rec.Medical_Provider__c)) {
            lines.add('Provider: ' + ctx.providers.get(rec.Medical_Provider__c).Name);
        }
        if (ctx != null && ctx.assigneeName() != null) {
            lines.add('Sender (case manager): ' + ctx.assigneeName());
        }
        lines.add('Firm name: ' + FollowUpConfig.firmName());
        lines.add('Current template draft subject: ' + valueOrMissing(redact(rec.Draft_Subject__c, ctx)));
        lines.add('Current template draft message:\n' + valueOrMissing(redact(rec.Draft_Message__c, ctx)));
        if (String.isNotBlank(rec.Response_Text__c)) {
            lines.add('Inbound response text:\n' + rec.Response_Text__c);
        }
        return String.join(lines, '\n');
    }

    /** Follow-up history lines (newest first) without record Ids. */
    public static String historyFacts(List<Follow_Up_Recommendation__c> history, Integer maxRecords) {
        List<String> lines = new List<String>();
        Integer count = 0;
        for (Follow_Up_Recommendation__c rec : history) {
            if (maxRecords != null && count >= maxRecords) {
                break;
            }
            lines.add(
                rec.Name +
                    ' | ' +
                    rec.Recommendation_Type__c +
                    ' | ' +
                    rec.Status__c +
                    ' | created ' +
                    FollowUpRuleEngine.formatDate(rec.CreatedDate == null ? null : rec.CreatedDate.date()) +
                    ' | sent ' +
                    FollowUpRuleEngine.formatDate(rec.Sent_Date__c == null ? null : rec.Sent_Date__c.date()) +
                    ' | response ' +
                    (rec.Response_Received__c == true ? valueOrMissing(rec.Response_Classification__c) : 'none')
            );
            count++;
        }
        return lines.isEmpty() ? 'No follow-up history.' : String.join(lines, '\n');
    }

    /** Replaces the client's date of birth with DOB_PLACEHOLDER (minimum necessary data to the LLM). */
    public static String redact(String text, FollowUpMatterContext ctx) {
        if (String.isBlank(text) || ctx == null || ctx.client() == null || ctx.client().Birthdate == null) {
            return text;
        }
        return text.replace(ctx.client().Birthdate.format(), DOB_PLACEHOLDER);
    }

    private static String dateWithAge(Date value, Date today) {
        if (value == null) {
            return Label.FollowUp_Not_Recorded;
        }
        return value.format() + ' (' + value.daysBetween(today) + ' days ago)';
    }

    private static String valueOrMissing(String value) {
        return String.isBlank(value) ? Label.FollowUp_Not_Recorded : value;
    }
}
