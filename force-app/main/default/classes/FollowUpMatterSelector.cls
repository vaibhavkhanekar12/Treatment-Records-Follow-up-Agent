/**
 * Bulk data access for the Treatment & Records Follow-up solution.
 * All matter-level facts are loaded in bulk (no SOQL in loops).
 *
 * Treatment history comes from the existing Treatment Visits object.
 * Treatment_Event__c is not used.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public with sharing class FollowUpMatterSelector {
    public static final String OUTBOUND_TASK_PREFIX = 'Follow-up sent:';

    public static List<FollowUpMatterContext> loadContexts(Set<Id> matterIds, Date today) {
        Map<Id, FollowUpMatterContext> byMatter = new Map<Id, FollowUpMatterContext>();
        if (matterIds == null || matterIds.isEmpty()) {
            return byMatter.values();
        }

        for (Matter__c matter : [
            SELECT Id, Name, Status__c, Practice_Area__c, Sign_Up_Date__c, CreatedDate,
                   OwnerId, Owner.Name, Case_Manager__c, Case_Manager__r.Name,
                   Case_Manager__r.FirstName, Client__c, Stalled__c, Stalled_Since__c
            FROM Matter__c
            WHERE Id IN :matterIds
        ]) {
            byMatter.put(matter.Id, new FollowUpMatterContext(matter));
        }

        Set<Id> ids = byMatter.keySet();
        if (ids.isEmpty()) return byMatter.values();

        loadClients(byMatter.values());
        Set<Id> providerIds = new Set<Id>();

        // EXISTING PRODUCTION SOURCE: Treatment Visits.
        // Only attended visits in the past count as completed treatment.
        for (AggregateResult row : [
            SELECT Matter__c matterId, Provider__c providerId, MAX(Visit_Start__c) lastDateTime
            FROM Treatment_Visits__c
            WHERE Matter__c IN :ids
              AND Visit_Start__c <= :System.now()
              AND Visit_Attended__c = TRUE
            GROUP BY Matter__c, Provider__c
        ]) {
            FollowUpMatterContext ctx = byMatter.get((Id) row.get('matterId'));
            if (ctx == null) continue;
            Datetime lastDateTime = (Datetime) row.get('lastDateTime');
            Date lastDate = lastDateTime == null ? null : lastDateTime.date();
            Id providerId = (Id) row.get('providerId');
            ctx.lastTreatmentDate = FollowUpMatterContext.maxDate(ctx.lastTreatmentDate, lastDate);
            if (providerId != null && lastDate != null) {
                ctx.lastTreatmentByProvider.put(providerId, lastDate);
                providerIds.add(providerId);
            }
        }

        // Future Treatment Visits are appointments, not completed treatment.
        for (AggregateResult row : [
            SELECT Matter__c matterId, MIN(Visit_Start__c) nextDateTime
            FROM Treatment_Visits__c
            WHERE Matter__c IN :ids
              AND Visit_Start__c > :System.now()
            GROUP BY Matter__c
        ]) {
            FollowUpMatterContext ctx = byMatter.get((Id) row.get('matterId'));
            if (ctx != null) {
                Datetime nextDateTime = (Datetime) row.get('nextDateTime');
                ctx.nextScheduledTreatmentDate = nextDateTime == null ? null : nextDateTime.date();
            }
        }

        for (Records_Request__c req : [
            SELECT Id, Name, Matter__c, Medical_Provider__c, Request_Type__c, Status__c,
                   Requested_Date__c, Received_Date__c
            FROM Records_Request__c
            WHERE Matter__c IN :ids
            ORDER BY Requested_Date__c ASC NULLS LAST
        ]) {
            byMatter.get(req.Matter__c).requests.add(req);
            if (req.Medical_Provider__c != null) providerIds.add(req.Medical_Provider__c);
        }

        Map<Id, Medical_Provider__c> providers = new Map<Id, Medical_Provider__c>();
        for (Medical_Provider__c provider : [
            SELECT Id, Name, Email__c, Fax__c, Phone__c, Matter__c
            FROM Medical_Provider__c
            WHERE Id IN :providerIds OR Matter__c IN :ids
        ]) {
            providers.put(provider.Id, provider);
            if (provider.Matter__c != null && byMatter.containsKey(provider.Matter__c)) {
                FollowUpMatterContext ctx = byMatter.get(provider.Matter__c);
                if (!ctx.providersByMatter.containsKey(provider.Matter__c)) {
                    ctx.providersByMatter.put(provider.Matter__c, new List<Medical_Provider__c>());
                }
                ctx.providersByMatter.get(provider.Matter__c).add(provider);
            }
        }

        for (FollowUpMatterContext ctx : byMatter.values()) {
            for (Id providerId : ctx.lastTreatmentByProvider.keySet()) {
                putProvider(ctx, providers.get(providerId));
            }
            for (Records_Request__c req : ctx.requests) {
                putProvider(ctx, providers.get(req.Medical_Provider__c));
            }
            if (ctx.lastTreatmentDate != null && ctx.lastTreatmentByProvider.isEmpty()) {
                Medical_Provider__c onlyProvider = ctx.singleMatterProvider();
                if (onlyProvider != null) {
                    ctx.lastTreatmentByProvider.put(onlyProvider.Id, ctx.lastTreatmentDate);
                    putProvider(ctx, onlyProvider);
                }
            }
        }

        loadClientContact(byMatter.values(), today);

        for (Follow_Up_Recommendation__c rec : [
            SELECT Id, Name, Matter__c, Recommendation_Type__c, Rule__c, Status__c, Priority__c,
                   Audience__c, Channel__c, Dedupe_Key__c, Sent_Date__c, Closed_Date__c,
                   Next_Follow_Up_Date__c, Response_Received__c, Response_Classification__c,
                   Records_Request__c, Medical_Provider__c, CreatedDate
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

    private static void loadClients(List<FollowUpMatterContext> contexts) {
        Set<Id> clientIds = new Set<Id>();
        for (FollowUpMatterContext ctx : contexts) {
            if (ctx.matter.Client__c != null) clientIds.add(ctx.matter.Client__c);
        }
        if (clientIds.isEmpty()) return;
        Map<Id, Contact> clients = new Map<Id, Contact>([
            SELECT Id, FirstName, LastName, Name, Email, MobilePhone, Phone, Birthdate
            FROM Contact WHERE Id IN :clientIds
        ]);
        for (FollowUpMatterContext ctx : contexts) {
            if (ctx.matter.Client__c != null) ctx.clientRecord = clients.get(ctx.matter.Client__c);
        }
    }

    private static void loadClientContact(List<FollowUpMatterContext> contexts, Date today) {
        Map<Id, List<FollowUpMatterContext>> byClient = new Map<Id, List<FollowUpMatterContext>>();
        for (FollowUpMatterContext ctx : contexts) {
            if (ctx.matter.Client__c != null) {
                if (!byClient.containsKey(ctx.matter.Client__c)) byClient.put(ctx.matter.Client__c, new List<FollowUpMatterContext>());
                byClient.get(ctx.matter.Client__c).add(ctx);
            }
        }
        if (byClient.isEmpty()) return;
        Set<Id> clientIds = byClient.keySet();
        String outboundPattern = OUTBOUND_TASK_PREFIX + '%';
        Map<Id, Date> latestContactByClient = new Map<Id, Date>();
        for (Task task : [SELECT WhoId, CompletedDateTime, ActivityDate FROM Task WHERE WhoId IN :clientIds AND IsClosed = TRUE AND (NOT Subject LIKE :outboundPattern)]) {
            Date candidate = task.CompletedDateTime != null ? task.CompletedDateTime.date() : task.ActivityDate;
            if (candidate == null) continue;
            if (candidate > today) candidate = today;
            Date existing = latestContactByClient.get(task.WhoId);
            if (existing == null || candidate > existing) latestContactByClient.put(task.WhoId, candidate);
        }
        for (Id clientId : latestContactByClient.keySet()) {
            for (FollowUpMatterContext ctx : byClient.get(clientId)) ctx.lastClientContactDate = latestContactByClient.get(clientId);
        }
    }

    private static void putProvider(FollowUpMatterContext ctx, Medical_Provider__c provider) {
        if (provider != null) ctx.providers.put(provider.Id, provider);
    }
}
