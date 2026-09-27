/**
 * Test data and configuration for the Treatment & Records Follow-up tests.
 * Configuration is injected in memory so tests are deterministic regardless of the org's CMDT values.
 */
@IsTest
public class FollowUpTestDataFactory {
    public static final String PS_CASE_MANAGER = 'Follow_Up_Case_Manager';
    public static final String PS_SUPERVISOR = 'Follow_Up_Supervisor';
    public static final String PS_AUTOMATION = 'Follow_Up_Automation';

    private static Integer fakeIdCounter = 0;

    // ------------------------------------------------------------------ configuration

    public static void useDefaultConfig() {
        FollowUpConfig.rulesOverride = defaultRules();
        FollowUpConfig.settingOverride = defaultSetting();
        FollowUpConfig.classificationOverride = defaultClassificationRules();
    }

    public static Map<String, Follow_Up_Rule__mdt> defaultRules() {
        Map<String, Follow_Up_Rule__mdt> rules = new Map<String, Follow_Up_Rule__mdt>();
        rules.put(FollowUpConstants.RULE_TREATMENT_GAP, rule(FollowUpConstants.RULE_TREATMENT_GAP, 21, 7, 2, 45, 'Medium', 'SMS', false));
        rules.put(
            FollowUpConstants.RULE_RECORDS_FOLLOW_UP,
            rule(FollowUpConstants.RULE_RECORDS_FOLLOW_UP, 14, 10, null, 45, 'Medium', 'Email', false)
        );
        rules.put(
            FollowUpConstants.RULE_PROVIDER_ESCALATION,
            rule(FollowUpConstants.RULE_PROVIDER_ESCALATION, 7, 14, 2, null, 'High', 'Task', true)
        );
        rules.put(
            FollowUpConstants.RULE_MISSING_BILLS,
            rule(FollowUpConstants.RULE_MISSING_BILLS, 30, 30, null, null, 'Medium', 'Task', false)
        );
        Follow_Up_Rule__mdt stalled = rule(FollowUpConstants.RULE_STALLED_MATTER, 45, 14, null, null, 'High', 'Task', true);
        stalled.Records_Activity_Days__c = 30;
        stalled.Client_Contact_Days__c = 30;
        rules.put(FollowUpConstants.RULE_STALLED_MATTER, stalled);
        rules.put(
            FollowUpConstants.RULE_CLIENT_STATUS_UPDATE,
            rule(FollowUpConstants.RULE_CLIENT_STATUS_UPDATE, 30, 30, null, null, 'Low', 'Email', false)
        );
        return rules;
    }

    /** Only the given rules active (others removed) - isolates one rule per test. */
    public static void useOnlyRules(Set<String> ruleNames) {
        useDefaultConfig();
        Map<String, Follow_Up_Rule__mdt> rules = defaultRules();
        for (String name : new List<String>(rules.keySet())) {
            if (!ruleNames.contains(name)) {
                rules.get(name).Active__c = false;
            }
        }
        FollowUpConfig.rulesOverride = rules;
    }

    public static Follow_Up_Rule__mdt rule(
        String name,
        Decimal threshold,
        Decimal repeatDays,
        Decimal escalateAfter,
        Decimal highDays,
        String priority,
        String channel,
        Boolean autoTask
    ) {
        return new Follow_Up_Rule__mdt(
            DeveloperName = name,
            MasterLabel = name,
            Active__c = true,
            Threshold_Days__c = threshold,
            Repeat_After_Days__c = repeatDays,
            Escalate_After_Count__c = escalateAfter,
            High_Priority_Days__c = highDays,
            Default_Priority__c = priority,
            Default_Channel__c = channel,
            Auto_Create_Task__c = autoTask
        );
    }

    public static Follow_Up_Setting__mdt defaultSetting() {
        return new Follow_Up_Setting__mdt(
            DeveloperName = 'Default',
            MasterLabel = 'Default',
            Open_Matter_Statuses__c = 'Intake,Open,Treating,Pre-Demand',
            Practice_Area_Filter__c = 'Personal Injury',
            Outstanding_Request_Statuses__c = 'Requested,Partially Received',
            Bill_Request_Types__c = 'Bills,Records and Bills',
            Excluded_Treatment_Statuses__c = 'Cancelled,No Show',
            Restricted_Terms__c = 'settlement,case value,liability,at fault,diagnosis,legal advice',
            Classification_Confidence_Threshold__c = 0.7,
            Batch_Size__c = 200,
            Max_AI_Drafts_Per_Run__c = 50,
            Firm_Name__c = 'Test Injury Law'
        );
    }

    public static List<Response_Classification_Rule__mdt> defaultClassificationRules() {
        return new List<Response_Classification_Rule__mdt>{
            classification('Opt_Out', 'Client', 'stop,unsubscribe', 'Exact', 1, 'Case_Manager_Review', 90),
            classification(
                'Provider_Action_Required',
                'Provider',
                'authorization,hipaa,fee,need another',
                'Contains',
                5,
                'Case_Manager_Review',
                14
            ),
            classification('Records_Sent', 'Provider', 'sent,faxed,mailed,uploaded', 'Contains', 10, 'Complete_And_Recheck', 7),
            classification(
                'Treatment_Stopped',
                'Client',
                'stopped,no longer,not going,discharged',
                'Contains',
                10,
                'Case_Manager_Review',
                14
            ),
            classification('Callback_Requested', 'Any', 'call me,call back', 'Contains', 15, 'Case_Manager_Review', null),
            classification('Status_Question', 'Client', 'status,where is my case', 'Contains', 18, 'Case_Manager_Review', null),
            classification(
                'Treatment_Continuing',
                'Client',
                'still going,still seeing,next appointment',
                'Contains',
                20,
                'Complete_And_Recheck',
                14
            ),
            classification('Unclear', 'Any', null, 'Contains', 99, 'Case_Manager_Review', null)
        };
    }

    public static Response_Classification_Rule__mdt classification(
        String category,
        String audience,
        String keywords,
        String matchType,
        Decimal sortOrder,
        String nextAction,
        Decimal recheckDays
    ) {
        return new Response_Classification_Rule__mdt(
            DeveloperName = category,
            MasterLabel = category,
            Category__c = category,
            Audience__c = audience,
            Keywords__c = keywords,
            Match_Type__c = matchType,
            Sort_Order__c = sortOrder,
            Next_Action__c = nextAction,
            Recheck_Days__c = recheckDays
        );
    }

    // ------------------------------------------------------------------ users

    /** Creates a Standard User with the given permission sets. Call inside System.runAs to avoid mixed DML. */
    public static User createUser(String alias, List<String> permissionSetNames) {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User user = new User(
            Alias = alias,
            Email = alias + '@followup.example.com',
            EmailEncodingKey = 'UTF-8',
            FirstName = 'Test',
            LastName = alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = alias + '.' + System.currentTimeMillis() + '@followup.example.com'
        );
        insert user;
        if (permissionSetNames != null && !permissionSetNames.isEmpty()) {
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = ps.Id));
            }
            insert assignments;
        }
        return user;
    }

    public static User createCaseManager(String alias) {
        User user;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            user = createUser(alias, new List<String>{ PS_CASE_MANAGER });
        }
        return user;
    }

    // ------------------------------------------------------------------ records

    public static Contact client(Id ownerId, String email, String mobile) {
        Contact client = new Contact(
            FirstName = 'Jamie',
            LastName = 'Client',
            Email = email,
            MobilePhone = mobile,
            Birthdate = Date.newInstance(1985, 4, 12)
        );
        if (ownerId != null) {
            client.OwnerId = ownerId;
        }
        return client;
    }

    public static Medical_Provider__c provider(String name, String email, String fax) {
        return new Medical_Provider__c(Name = name, Email__c = email, Fax__c = fax, Phone__c = '555-0100');
    }

    public static Matter__c matter(String name, Id clientId, Id caseManagerId, Date signUpDate) {
        Matter__c matter = new Matter__c(
            Name = name,
            Status__c = 'Treating',
            Practice_Area__c = 'Personal Injury',
            Client__c = clientId,
            Case_Manager__c = caseManagerId,
            Sign_Up_Date__c = signUpDate
        );
        if (caseManagerId != null) {
            matter.OwnerId = caseManagerId;
        }
        return matter;
    }

    public static Treatment_Event__c treatment(Id matterId, Id providerId, Date treatmentDate, String status) {
        return new Treatment_Event__c(
            Matter__c = matterId,
            Medical_Provider__c = providerId,
            Treatment_Date__c = treatmentDate,
            Status__c = status
        );
    }

    public static Records_Request__c request(Id matterId, Id providerId, String requestType, String status, Date requestedDate) {
        return new Records_Request__c(
            Matter__c = matterId,
            Medical_Provider__c = providerId,
            Request_Type__c = requestType,
            Status__c = status,
            Requested_Date__c = requestedDate
        );
    }

    /** A sent (approved) external follow-up, as it would look after delivery. */
    public static Follow_Up_Recommendation__c sentRecommendation(
        Id matterId,
        String recType,
        String audience,
        String dedupeKey,
        Datetime sentDate
    ) {
        return new Follow_Up_Recommendation__c(
            Matter__c = matterId,
            Recommendation_Type__c = recType,
            Rule__c = 'Test',
            Status__c = FollowUpConstants.STATUS_SENT,
            Audience__c = audience,
            Channel__c = FollowUpConstants.CHANNEL_EMAIL,
            Dedupe_Key__c = dedupeKey,
            Approved_By__c = UserInfo.getUserId(),
            Approved_Date__c = sentDate,
            Sent_Date__c = sentDate,
            Draft_Message__c = 'Sent message'
        );
    }

    /** A pending external recommendation ready for approval. */
    public static Follow_Up_Recommendation__c pendingRecommendation(
        Id matterId,
        String audience,
        String channel,
        Id contactId,
        Id providerId
    ) {
        return new Follow_Up_Recommendation__c(
            Matter__c = matterId,
            Recommendation_Type__c = audience == FollowUpConstants.AUDIENCE_PROVIDER
                ? FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP
                : FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            Rule__c = 'Test',
            Status__c = FollowUpConstants.STATUS_PENDING_REVIEW,
            Priority__c = FollowUpConstants.PRIORITY_MEDIUM,
            Audience__c = audience,
            Channel__c = channel,
            Recipient_Contact__c = contactId,
            Medical_Provider__c = providerId,
            Draft_Subject__c = 'Checking in',
            Draft_Message__c = 'Hello, this is a neutral administrative check-in.',
            Draft_Source__c = FollowUpConstants.DRAFT_TEMPLATE,
            Reason__c = 'Test reason',
            Assigned_To__c = UserInfo.getUserId()
        );
    }

    // ------------------------------------------------------------------ in-memory helpers (rule engine unit tests)

    public static Id fakeId(Schema.SObjectType sObjectType) {
        fakeIdCounter++;
        String counter = String.valueOf(fakeIdCounter);
        return Id.valueOf(
            sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '0'.repeat(12 - counter.length()) + counter
        );
    }

    /** In-memory matter context; no DML. */
    public static FollowUpMatterContext context(Date signUpDate, Contact client) {
        Matter__c matter = new Matter__c(
            Id = fakeId(Matter__c.SObjectType),
            Name = 'M-TEST',
            Status__c = 'Treating',
            Sign_Up_Date__c = signUpDate,
            Case_Manager__c = UserInfo.getUserId()
        );
        if (client != null) {
            if (client.Id == null) {
                client.Id = fakeId(Contact.SObjectType);
            }
            matter.Client__c = client.Id;
            matter.putSObject('Client__r', client);
        }
        return new FollowUpMatterContext(matter);
    }

    public static Records_Request__c memoryRequest(
        FollowUpMatterContext ctx,
        Medical_Provider__c provider,
        String requestType,
        String status,
        Date requestedDate
    ) {
        if (provider.Id == null) {
            provider.Id = fakeId(Medical_Provider__c.SObjectType);
        }
        ctx.providers.put(provider.Id, provider);
        Records_Request__c req = new Records_Request__c(
            Id = fakeId(Records_Request__c.SObjectType),
            Matter__c = ctx.matter.Id,
            Medical_Provider__c = provider.Id,
            Request_Type__c = requestType,
            Status__c = status,
            Requested_Date__c = requestedDate
        );
        ctx.requests.add(req);
        return req;
    }

    public static Follow_Up_Recommendation__c memoryHistory(
        FollowUpMatterContext ctx,
        String recType,
        String dedupeKey,
        String status,
        Datetime sentDate
    ) {
        Follow_Up_Recommendation__c rec = new Follow_Up_Recommendation__c(
            Id = fakeId(Follow_Up_Recommendation__c.SObjectType),
            Matter__c = ctx.matter.Id,
            Recommendation_Type__c = recType,
            Status__c = status,
            Dedupe_Key__c = dedupeKey,
            Sent_Date__c = sentDate
        );
        ctx.history.add(rec);
        return rec;
    }
}
