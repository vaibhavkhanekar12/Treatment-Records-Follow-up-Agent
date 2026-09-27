/**
 * Deterministic rule engine. Decides WHETHER a follow-up is needed; AI never does.
 *
 * Pure logic: no SOQL, no DML. Input is a list of FollowUpMatterContext (verified facts) and the
 * Follow_Up_Rule__mdt configuration; output is a list of unsaved recommendations plus the set of
 * dedupe keys whose condition currently holds (used to supersede stale open recommendations) and the
 * stalled flag per matter.
 *
 * Idempotency / duplicate prevention:
 *  - each follow-up subject has a stable Dedupe_Key__c (type | matter/request[/provider]);
 *  - an open recommendation with the same key suppresses a new one (also enforced by the unique
 *    Active_Key__c field at the database level);
 *  - a sent/closed recommendation suppresses the same key for Repeat_After_Days;
 *  - a snooze (Next_Follow_Up_Date__c in the future) suppresses the key until that date.
 */
public with sharing class FollowUpRuleEngine {
    public class Candidate {
        public Follow_Up_Recommendation__c recommendation;
        public FollowUpMatterContext context;
        public Boolean autoCreateTask = false;
    }

    public class Result {
        public List<Candidate> candidates = new List<Candidate>();
        /** Dedupe keys whose rule condition holds today (suppressed or not). */
        public Set<String> activeConditionKeys = new Set<String>();
        /** Matter Id -> stalled (only for matters evaluated while the stalled rule is active). */
        public Map<Id, Boolean> stalledByMatter = new Map<Id, Boolean>();
        public Integer suppressedCount = 0;
        public List<String> warnings = new List<String>();
    }

    private final Date today;
    private final Set<String> outstandingStatuses;
    private final Set<String> billTypes;

    public FollowUpRuleEngine(Date today) {
        this.today = today;
        this.outstandingStatuses = FollowUpConfig.outstandingRequestStatuses();
        this.billTypes = FollowUpConfig.billRequestTypes();
    }

    public Result evaluate(List<FollowUpMatterContext> contexts) {
        Result result = new Result();
        for (FollowUpMatterContext ctx : contexts) {
            evaluateTreatmentGap(ctx, result);
            evaluateRecordsRequests(ctx, result);
            evaluateMissingBills(ctx, result);
            evaluateStalledMatter(ctx, result);
            evaluateClientStatusUpdate(ctx, result);
        }
        return result;
    }

    public static String dedupeKey(String recType, Id primaryId) {
        return recType + '|' + primaryId;
    }

    public static String dedupeKey(String recType, Id primaryId, Id secondaryId) {
        return recType + '|' + primaryId + '|' + secondaryId;
    }

    // ---------------------------------------------------------------- Treatment gap / client check-in

    private void evaluateTreatmentGap(FollowUpMatterContext ctx, Result result) {
        Follow_Up_Rule__mdt rule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_TREATMENT_GAP);
        if (rule == null) {
            return;
        }
        Date anchor = ctx.treatmentAnchor();
        if (anchor == null) {
            result.warnings.add(ctx.matter.Name + ': no treatment and no sign-up date; treatment gap not evaluated.');
            return;
        }
        Integer gapDays = anchor.daysBetween(today);
        if (gapDays < rule.Threshold_Days__c || ctx.nextScheduledTreatmentDate != null) {
            // Within threshold, or the client already has an upcoming appointment.
            return;
        }
        Contact client = ctx.client();
        String checkInKey = dedupeKey(FollowUpConstants.TYPE_CLIENT_CHECK_IN, ctx.matter.Id);
        Integer unanswered = ctx.unansweredSince(checkInKey, anchor);
        Integer escalateAfter = FollowUpConfig.toInt(rule.Escalate_After_Count__c);
        Boolean unresponsive = escalateAfter != null && unanswered >= escalateAfter;
        Boolean needsReview = client == null || unresponsive;

        String recType = needsReview ? FollowUpConstants.TYPE_TREATMENT_GAP_REVIEW : FollowUpConstants.TYPE_CLIENT_CHECK_IN;
        String key = needsReview ? dedupeKey(recType, ctx.matter.Id) : checkInKey;
        result.activeConditionKeys.add(key);
        if (isSuppressed(ctx, key, rule)) {
            result.suppressedCount++;
            return;
        }

        String reason = ctx.lastTreatmentDate != null
            ? format(
                  Label.FollowUp_Reason_Treatment_Gap,
                  new List<Object>{ formatDate(ctx.lastTreatmentDate), gapDays, rule.Threshold_Days__c.intValue(), unanswered }
              )
            : format(Label.FollowUp_Reason_No_Treatment, new List<Object>{ gapDays, rule.Threshold_Days__c.intValue() });

        Follow_Up_Recommendation__c rec = newRecommendation(
            ctx,
            recType,
            FollowUpConstants.RULE_TREATMENT_GAP,
            key,
            priorityFor(rule, gapDays)
        );
        rec.Gap_Days__c = gapDays;
        rec.Last_Treatment_Date__c = ctx.lastTreatmentDate;
        rec.Prior_Follow_Up_Count__c = unanswered;
        if (needsReview) {
            rec.Audience__c = FollowUpConstants.AUDIENCE_INTERNAL;
            rec.Channel__c = FollowUpConstants.CHANNEL_TASK;
            rec.Priority__c = FollowUpConstants.PRIORITY_HIGH;
            reason += client == null
                ? Label.FollowUp_Reason_No_Client
                : format(Label.FollowUp_Reason_Unanswered_Check_Ins, new List<Object>{ unanswered, escalateAfter });
        } else {
            rec.Audience__c = FollowUpConstants.AUDIENCE_CLIENT;
            rec.Recipient_Contact__c = client.Id;
            rec.Channel__c = clientChannel(client, rule.Default_Channel__c);
            if (rec.Channel__c == FollowUpConstants.CHANNEL_PHONE) {
                reason += Label.FollowUp_Reason_No_Channel;
            }
        }
        rec.Reason__c = reason;
        addCandidate(result, ctx, rec, rule);
    }

    // ---------------------------------------------------------------- Records follow-up / escalation

    private void evaluateRecordsRequests(FollowUpMatterContext ctx, Result result) {
        Follow_Up_Rule__mdt followUpRule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_RECORDS_FOLLOW_UP);
        Follow_Up_Rule__mdt escalationRule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_PROVIDER_ESCALATION);
        if (followUpRule == null && escalationRule == null) {
            return;
        }
        for (Records_Request__c req : ctx.outstandingRequests(outstandingStatuses)) {
            if (req.Requested_Date__c == null) {
                result.warnings.add(ctx.matter.Name + ': records request ' + req.Name + ' has no requested date; skipped.');
                continue;
            }
            Integer ageDays = req.Requested_Date__c.daysBetween(today);
            String followUpKey = dedupeKey(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP, req.Id);
            List<Follow_Up_Recommendation__c> sent = ctx.sentForKey(followUpKey);
            Integer sentCount = sent.size();
            Date lastFollowUp = sentCount > 0 ? sent[0].Sent_Date__c.date() : null;
            Medical_Provider__c provider = ctx.providers.get(req.Medical_Provider__c);
            String providerName = provider == null ? Label.FollowUp_Not_Recorded : provider.Name;
            String requestType = String.isBlank(req.Request_Type__c) ? Label.FollowUp_Not_Recorded : req.Request_Type__c;

            if (isEscalationDue(escalationRule, sentCount, lastFollowUp)) {
                String key = dedupeKey(FollowUpConstants.TYPE_PROVIDER_ESCALATION, req.Id);
                result.activeConditionKeys.add(key);
                if (isSuppressed(ctx, key, escalationRule)) {
                    result.suppressedCount++;
                    continue;
                }
                Follow_Up_Recommendation__c rec = newRecommendation(
                    ctx,
                    FollowUpConstants.TYPE_PROVIDER_ESCALATION,
                    FollowUpConstants.RULE_PROVIDER_ESCALATION,
                    key,
                    priorityFor(escalationRule, ageDays)
                );
                rec.Audience__c = FollowUpConstants.AUDIENCE_INTERNAL;
                rec.Channel__c = FollowUpConstants.CHANNEL_TASK;
                setRequestFacts(rec, req, ageDays, sentCount);
                rec.Reason__c = format(
                    Label.FollowUp_Reason_Provider_Escalation,
                    new List<Object>{
                        requestType,
                        providerName,
                        formatDate(req.Requested_Date__c),
                        sentCount,
                        escalationRule.Escalate_After_Count__c.intValue(),
                        formatDate(lastFollowUp)
                    }
                );
                addCandidate(result, ctx, rec, escalationRule);
                continue;
            }

            if (followUpRule == null || ageDays < followUpRule.Threshold_Days__c) {
                continue;
            }
            result.activeConditionKeys.add(followUpKey);
            if (isSuppressed(ctx, followUpKey, followUpRule)) {
                result.suppressedCount++;
                continue;
            }
            Follow_Up_Recommendation__c rec = newRecommendation(
                ctx,
                FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
                FollowUpConstants.RULE_RECORDS_FOLLOW_UP,
                followUpKey,
                priorityFor(followUpRule, ageDays)
            );
            rec.Audience__c = FollowUpConstants.AUDIENCE_PROVIDER;
            rec.Channel__c = providerChannel(provider, followUpRule.Default_Channel__c);
            setRequestFacts(rec, req, ageDays, sentCount);
            String reason = format(
                Label.FollowUp_Reason_Records_Outstanding,
                new List<Object>{
                    requestType,
                    providerName,
                    formatDate(req.Requested_Date__c),
                    ageDays,
                    sentCount,
                    followUpRule.Threshold_Days__c.intValue()
                }
            );
            if (rec.Channel__c == FollowUpConstants.CHANNEL_PHONE) {
                reason += Label.FollowUp_Reason_No_Channel;
            }
            rec.Reason__c = reason;
            addCandidate(result, ctx, rec, followUpRule);
        }
    }

    private Boolean isEscalationDue(Follow_Up_Rule__mdt escalationRule, Integer sentCount, Date lastFollowUp) {
        return escalationRule != null &&
            escalationRule.Escalate_After_Count__c != null &&
            sentCount >= escalationRule.Escalate_After_Count__c &&
            lastFollowUp != null &&
            lastFollowUp.daysBetween(today) >= escalationRule.Threshold_Days__c;
    }

    private static void setRequestFacts(Follow_Up_Recommendation__c rec, Records_Request__c req, Integer ageDays, Integer sentCount) {
        rec.Records_Request__c = req.Id;
        rec.Medical_Provider__c = req.Medical_Provider__c;
        rec.Records_Age_Days__c = ageDays;
        rec.Prior_Follow_Up_Count__c = sentCount;
    }

    // ---------------------------------------------------------------- Missing bills

    private void evaluateMissingBills(FollowUpMatterContext ctx, Result result) {
        Follow_Up_Rule__mdt rule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_MISSING_BILLS);
        if (rule == null || billTypes.isEmpty()) {
            return;
        }
        for (Id providerId : ctx.lastTreatmentByProvider.keySet()) {
            Date lastVisit = ctx.lastTreatmentByProvider.get(providerId);
            Integer daysSinceVisit = lastVisit.daysBetween(today);
            if (daysSinceVisit < rule.Threshold_Days__c || ctx.hasBillRequestFor(providerId, billTypes)) {
                continue;
            }
            String key = dedupeKey(FollowUpConstants.TYPE_MISSING_BILLS, ctx.matter.Id, providerId);
            result.activeConditionKeys.add(key);
            if (isSuppressed(ctx, key, rule)) {
                result.suppressedCount++;
                continue;
            }
            Medical_Provider__c provider = ctx.providers.get(providerId);
            Follow_Up_Recommendation__c rec = newRecommendation(
                ctx,
                FollowUpConstants.TYPE_MISSING_BILLS,
                FollowUpConstants.RULE_MISSING_BILLS,
                key,
                priorityFor(rule, daysSinceVisit)
            );
            rec.Audience__c = FollowUpConstants.AUDIENCE_INTERNAL;
            rec.Channel__c = FollowUpConstants.CHANNEL_TASK;
            rec.Medical_Provider__c = providerId;
            rec.Last_Treatment_Date__c = lastVisit;
            rec.Reason__c = format(
                Label.FollowUp_Reason_Missing_Bills,
                new List<Object>{ provider == null ? Label.FollowUp_Not_Recorded : provider.Name, formatDate(lastVisit) }
            );
            addCandidate(result, ctx, rec, rule);
        }
    }

    // ---------------------------------------------------------------- Stalled matter

    private void evaluateStalledMatter(FollowUpMatterContext ctx, Result result) {
        Follow_Up_Rule__mdt rule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_STALLED_MATTER);
        Date anchor = ctx.treatmentAnchor();
        if (rule == null || anchor == null) {
            return;
        }
        Date fallback = ctx.signUpDate() != null ? ctx.signUpDate() : anchor;
        Integer treatmentDays = anchor.daysBetween(today);
        Date recordsActivity = ctx.lastRecordsActivity();
        Integer recordsDays = (recordsActivity != null ? recordsActivity : fallback).daysBetween(today);
        Integer clientDays = (ctx.lastClientContactDate != null ? ctx.lastClientContactDate : fallback).daysBetween(today);
        Integer recordsThreshold = FollowUpConfig.toInt(rule.Records_Activity_Days__c);
        Integer clientThreshold = FollowUpConfig.toInt(rule.Client_Contact_Days__c);

        Boolean stalled =
            treatmentDays >= rule.Threshold_Days__c &&
            (recordsThreshold == null ||
            recordsDays >= recordsThreshold) &&
            (clientThreshold == null ||
            clientDays >= clientThreshold);
        result.stalledByMatter.put(ctx.matter.Id, stalled);
        if (!stalled) {
            return;
        }
        String key = dedupeKey(FollowUpConstants.TYPE_STALLED_MATTER, ctx.matter.Id);
        result.activeConditionKeys.add(key);
        if (isSuppressed(ctx, key, rule)) {
            result.suppressedCount++;
            return;
        }
        Follow_Up_Recommendation__c rec = newRecommendation(
            ctx,
            FollowUpConstants.TYPE_STALLED_MATTER,
            FollowUpConstants.RULE_STALLED_MATTER,
            key,
            priorityFor(rule, treatmentDays)
        );
        rec.Audience__c = FollowUpConstants.AUDIENCE_INTERNAL;
        rec.Channel__c = FollowUpConstants.CHANNEL_TASK;
        rec.Gap_Days__c = treatmentDays;
        rec.Last_Treatment_Date__c = ctx.lastTreatmentDate;
        rec.Reason__c = format(
            Label.FollowUp_Reason_Stalled,
            new List<Object>{
                treatmentDays,
                rule.Threshold_Days__c.intValue(),
                formatDate(recordsActivity),
                recordsThreshold == null ? '-' : String.valueOf(recordsThreshold),
                formatDate(ctx.lastClientContactDate),
                clientThreshold == null ? '-' : String.valueOf(clientThreshold)
            }
        );
        addCandidate(result, ctx, rec, rule);
    }

    // ---------------------------------------------------------------- Monthly client status update

    private void evaluateClientStatusUpdate(FollowUpMatterContext ctx, Result result) {
        Follow_Up_Rule__mdt rule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_CLIENT_STATUS_UPDATE);
        Contact client = ctx.client();
        Date signUp = ctx.signUpDate();
        if (rule == null || client == null || signUp == null || signUp.daysBetween(today) < rule.Threshold_Days__c) {
            return;
        }
        String channel = clientChannel(client, rule.Default_Channel__c);
        if (channel == FollowUpConstants.CHANNEL_PHONE) {
            result.warnings.add(ctx.matter.Name + ': no email or mobile on file; monthly status update skipped.');
            return;
        }
        String key = dedupeKey(FollowUpConstants.TYPE_CLIENT_STATUS_UPDATE, ctx.matter.Id);
        result.activeConditionKeys.add(key);
        if (isSuppressed(ctx, key, rule)) {
            result.suppressedCount++;
            return;
        }
        List<Follow_Up_Recommendation__c> previous = ctx.sentForKey(key);
        Follow_Up_Recommendation__c rec = newRecommendation(
            ctx,
            FollowUpConstants.TYPE_CLIENT_STATUS_UPDATE,
            FollowUpConstants.RULE_CLIENT_STATUS_UPDATE,
            key,
            priorityFor(rule, null)
        );
        rec.Audience__c = FollowUpConstants.AUDIENCE_CLIENT;
        rec.Recipient_Contact__c = client.Id;
        rec.Channel__c = channel;
        rec.Last_Treatment_Date__c = ctx.lastTreatmentDate;
        rec.Reason__c = format(
            Label.FollowUp_Reason_Status_Update,
            new List<Object>{ previous.isEmpty() ? Label.FollowUp_Not_Recorded : formatDate(previous[0].Sent_Date__c.date()) }
        );
        addCandidate(result, ctx, rec, rule);
    }

    // ---------------------------------------------------------------- Shared helpers

    @TestVisible
    private Boolean isSuppressed(FollowUpMatterContext ctx, String key, Follow_Up_Rule__mdt rule) {
        Integer repeatDays = FollowUpConfig.toInt(rule.Repeat_After_Days__c);
        for (Follow_Up_Recommendation__c prior : ctx.historyForKey(key)) {
            if (FollowUpConstants.OPEN_STATUSES.contains(prior.Status__c)) {
                return true;
            }
            if (prior.Next_Follow_Up_Date__c != null && prior.Next_Follow_Up_Date__c > today) {
                return true;
            }
            if (prior.Status__c == FollowUpConstants.STATUS_SUPERSEDED || repeatDays == null) {
                continue;
            }
            Datetime lastTouch = prior.Sent_Date__c != null
                ? prior.Sent_Date__c
                : (prior.Closed_Date__c != null ? prior.Closed_Date__c : prior.CreatedDate);
            if (lastTouch != null && lastTouch.date().daysBetween(today) < repeatDays) {
                return true;
            }
        }
        return false;
    }

    private Follow_Up_Recommendation__c newRecommendation(
        FollowUpMatterContext ctx,
        String recType,
        String ruleName,
        String key,
        String priority
    ) {
        return new Follow_Up_Recommendation__c(
            Matter__c = ctx.matter.Id,
            Recommendation_Type__c = recType,
            Rule__c = ruleName,
            Status__c = FollowUpConstants.STATUS_PENDING_REVIEW,
            Priority__c = priority,
            Dedupe_Key__c = key,
            Assigned_To__c = ctx.assigneeId(),
            Recommended_Date__c = today,
            AI_Rationale__c = Label.FollowUp_Template_Rationale
        );
    }

    private static void addCandidate(Result result, FollowUpMatterContext ctx, Follow_Up_Recommendation__c rec, Follow_Up_Rule__mdt rule) {
        FollowUpDraftBuilder.applyTemplate(rec, ctx);
        Candidate candidate = new Candidate();
        candidate.recommendation = rec;
        candidate.context = ctx;
        candidate.autoCreateTask = rule.Auto_Create_Task__c == true && rec.Audience__c == FollowUpConstants.AUDIENCE_INTERNAL;
        result.candidates.add(candidate);
    }

    @TestVisible
    private static String priorityFor(Follow_Up_Rule__mdt rule, Integer days) {
        if (days != null && rule.High_Priority_Days__c != null && days >= rule.High_Priority_Days__c) {
            return FollowUpConstants.PRIORITY_HIGH;
        }
        return String.isBlank(rule.Default_Priority__c) ? FollowUpConstants.PRIORITY_MEDIUM : rule.Default_Priority__c;
    }

    /** Preferred channel when the client has an address for it; otherwise SMS, then Email, then a phone call script. */
    @TestVisible
    private static String clientChannel(Contact client, String preferred) {
        Boolean hasEmail = String.isNotBlank(client.Email) && client.HasOptedOutOfEmail != true;
        Boolean hasMobile = String.isNotBlank(client.MobilePhone);
        List<String> order = new List<String>{ preferred, FollowUpConstants.CHANNEL_SMS, FollowUpConstants.CHANNEL_EMAIL };
        for (String channel : order) {
            if (channel == FollowUpConstants.CHANNEL_SMS && hasMobile) {
                return channel;
            }
            if (channel == FollowUpConstants.CHANNEL_EMAIL && hasEmail) {
                return channel;
            }
        }
        return FollowUpConstants.CHANNEL_PHONE;
    }

    /** Preferred channel when the provider has an address for it; otherwise Email, then Fax, then phone. */
    @TestVisible
    private static String providerChannel(Medical_Provider__c provider, String preferred) {
        if (provider == null) {
            return FollowUpConstants.CHANNEL_PHONE;
        }
        List<String> order = new List<String>{ preferred, FollowUpConstants.CHANNEL_EMAIL, FollowUpConstants.CHANNEL_FAX };
        for (String channel : order) {
            if (channel == FollowUpConstants.CHANNEL_EMAIL && String.isNotBlank(provider.Email__c)) {
                return channel;
            }
            if (channel == FollowUpConstants.CHANNEL_FAX && String.isNotBlank(provider.Fax__c)) {
                return channel;
            }
        }
        return FollowUpConstants.CHANNEL_PHONE;
    }

    /** String.format over any values, rendered with String.valueOf (no locale number formatting). */
    public static String format(String template, List<Object> args) {
        List<String> values = new List<String>();
        for (Object arg : args) {
            values.add(arg == null ? Label.FollowUp_Not_Recorded : String.valueOf(arg));
        }
        return String.format(template, values);
    }

    public static String formatDate(Date value) {
        return value == null ? Label.FollowUp_Not_Recorded : value.format();
    }
}
