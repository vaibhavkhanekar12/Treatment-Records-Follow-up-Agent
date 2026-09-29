/**
 * Bulk data access for the Treatment & Records Follow-up solution.
 * All matter-level facts are loaded with a fixed number of queries per call (no SOQL in loops),
 * so one batch scope costs 7 queries regardless of scope size.
 *
 * Sharing: `with sharing`. The nightly batch runs as the automation user (Follow_Up_Automation permission
 * set: View All on the source objects); agent and UI callers see only what their own sharing allows, and
 * entry points verify matter access WITH USER_MODE before calling this selector.
 */
// Reads run in the class sharing context without per-query CRUD/FLS: the nightly batch must compute complete facts for
// every open matter, and user-facing callers verify access first (FollowUpSecurity.readableMatters / requireSourceDataAccess).
// Outputs are aggregate facts written to Follow_Up_Recommendation__c, which inherits matter sharing.
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class FollowUpMatterSelector {
    /** Prefix of Tasks this solution logs for its own outbound messages; excluded from client-contact recency. */
    public static final String OUTBOUND_TASK_PREFIX = 'Follow-up sent:';
    private static final String NO_MATCH = '__follow_up_no_match__';

    public static List<FollowUpMatterContext> loadContexts(Set<Id> matterIds, Date today) {
        Map<Id, FollowUpMatterContext> byMatter = new Map<Id, FollowUpMatterContext>();
        if (matterIds == null || matterIds.isEmpty()) {
            return byMatter.values();
        }
        for (Matter__c matter : [
            SELECT
                Id,
                Name,
                Status__c,
                Practice_Area__c,
                Sign_Up_Date__c,
                CreatedDate,
                OwnerId,
                Owner.Name,
                Case_Manager__c,
                Case_Manager__r.Name,
                Case_Manager__r.FirstName,
                Client__c,
                Client__r.FirstName,
                Client__r.LastName,
                Client__r.Name,
                Client__r.Email,
                Client__r.MobilePhone,
                Client__r.Phone,
                Client__r.Birthdate,
                Client__r.HasOptedOutOfEmail,
                Stalled__c,
                Stalled_Since__c
            FROM Matter__c
            WHERE Id IN :matterIds
        ]) {
            byMatter.put(matter.Id, new FollowUpMatterContext(matter));
        }
        Set<Id> ids = byMatter.keySet();
        if (ids.isEmpty()) {
            return byMatter.values();
        }

        Set<String> excluded = withSentinel(FollowUpConfig.excludedTreatmentStatuses());
        Set<Id> providerIds = new Set<Id>();

        for (AggregateResult row : [
            SELECT Matter__c matterId, Medical_Provider__c providerId, MAX(Treatment_Date__c) lastDate
            FROM Treatment_Event__c
            WHERE Matter__c IN :ids AND Treatment_Date__c <= :today AND Status__c NOT IN :excluded
            GROUP BY Matter__c, Medical_Provider__c
        ]) {
            FollowUpMatterContext ctx = byMatter.get((Id) row.get('matterId'));
            Date lastDate = (Date) row.get('lastDate');
            Id providerId = (Id) row.get('providerId');
            ctx.lastTreatmentDate = FollowUpMatterContext.maxDate(ctx.lastTreatmentDate, lastDate);
            if (providerId != null) {
                ctx.lastTreatmentByProvider.put(providerId, lastDate);
                providerIds.add(providerId);
            }
        }

        for (AggregateResult row : [
            SELECT Matter__c matterId, MIN(Treatment_Date__c) nextDate
            FROM Treatment_Event__c
            WHERE Matter__c IN :ids AND Treatment_Date__c > :today AND Status__c NOT IN :excluded
            GROUP BY Matter__c
        ]) {
            byMatter.get((Id) row.get('matterId')).nextScheduledTreatmentDate = (Date) row.get('nextDate');
        }

        for (Records_Request__c req : [
            SELECT Id, Name, Matter__c, Medical_Provider__c, Request_Type__c, Status__c, Requested_Date__c, Received_Date__c
            FROM Records_Request__c
            WHERE Matter__c IN :ids
            ORDER BY Requested_Date__c ASC NULLS LAST
        ]) {
            byMatter.get(req.Matter__c).requests.add(req);
            if (req.Medical_Provider__c != null) {
                providerIds.add(req.Medical_Provider__c);
            }
        }

        if (!providerIds.isEmpty()) {
            Map<Id, Medical_Provider__c> providers = new Map<Id, Medical_Provider__c>(
                [SELECT Id, Name, Email__c, Fax__c, Phone__c FROM Medical_Provider__c WHERE Id IN :providerIds]
            );
            for (FollowUpMatterContext ctx : byMatter.values()) {
                for (Id providerId : ctx.lastTreatmentByProvider.keySet()) {
                    putProvider(ctx, providers.get(providerId));
                }
                for (Records_Request__c req : ctx.requests) {
                    putProvider(ctx, providers.get(req.Medical_Provider__c));
                }
            }
        }

        loadClientContact(byMatter.values(), today);

        for (Follow_Up_Recommendation__c rec : [
            SELECT
                Id,
                Name,
                Matter__c,
                Recommendation_Type__c,
                Rule__c,
                Status__c,
                Priority__c,
                Audience__c,
                Channel__c,
                Dedupe_Key__c,
                Sent_Date__c,
                Closed_Date__c,
                Next_Follow_Up_Date__c,
                Response_Received__c,
                Response_Classification__c,
                Records_Request__c,
                Medical_Provider__c,
                CreatedDate
            FROM Follow_Up_Recommendation__c
            WHERE Matter__c IN :ids
            ORDER BY CreatedDate DESC, Id DESC
        ]) {
            byMatter.get(rec.Matter__c).history.add(rec);
        }
        return byMatter.values();
    }

    public static FollowUpMatterContext loadContext(Id matterId, Date today) {
        List<FollowUpMatterContext> contexts = loadContexts(new Set<Id>{ matterId }, today);
        return contexts.isEmpty() ? null : contexts[0];
    }

    private static void loadClientContact(List<FollowUpMatterContext> contexts, Date today) {
        Map<Id, List<FollowUpMatterContext>> byClient = new Map<Id, List<FollowUpMatterContext>>();
        for (FollowUpMatterContext ctx : contexts) {
            if (ctx.matter.Client__c != null) {
                if (!byClient.containsKey(ctx.matter.Client__c)) {
                    byClient.put(ctx.matter.Client__c, new List<FollowUpMatterContext>());
                }
                byClient.get(ctx.matter.Client__c).add(ctx);
            }
        }
        if (byClient.isEmpty()) {
            return;
        }
        Set<Id> clientIds = byClient.keySet();
        String outboundPattern = OUTBOUND_TASK_PREFIX + '%';
        for (AggregateResult row : [
            SELECT WhoId clientId, MAX(CompletedDateTime) lastCompleted, MAX(ActivityDate) lastActivity
            FROM Task
            WHERE WhoId IN :clientIds AND IsClosed = TRUE AND (NOT Subject LIKE :outboundPattern)
            GROUP BY WhoId
        ]) {
            Datetime lastCompleted = (Datetime) row.get('lastCompleted');
            Date lastActivity = (Date) row.get('lastActivity');
            // CompletedDateTime is authoritative; ActivityDate (a due date) is only a fallback for legacy Tasks.
            Date lastContact = lastCompleted != null ? lastCompleted.date() : lastActivity;
            if (lastContact != null && lastContact > today) {
                lastContact = today;
            }
            for (FollowUpMatterContext ctx : byClient.get((Id) row.get('clientId'))) {
                ctx.lastClientContactDate = lastContact;
            }
        }
    }

    private static void putProvider(FollowUpMatterContext ctx, Medical_Provider__c provider) {
        if (provider != null) {
            ctx.providers.put(provider.Id, provider);
        }
    }

    /** SOQL `NOT IN` with an empty bind set is avoided by adding a value that can never match. */
    private static Set<String> withSentinel(Set<String> values) {
        Set<String> copy = new Set<String>(values);
        copy.add(NO_MATCH);
        return copy;
    }
}
