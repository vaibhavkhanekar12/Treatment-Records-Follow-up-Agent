/**
 * Picklist API values and rule identities used by the Treatment & Records Follow-up solution.
 * Business thresholds are NOT defined here; they live in Follow_Up_Rule__mdt / Follow_Up_Setting__mdt.
 */
public with sharing class FollowUpConstants {
    // Follow_Up_Rule__mdt DeveloperNames (rule identities)
    public static final String RULE_TREATMENT_GAP = 'Treatment_Gap';
    public static final String RULE_RECORDS_FOLLOW_UP = 'Records_Follow_Up';
    public static final String RULE_PROVIDER_ESCALATION = 'Provider_Escalation';
    public static final String RULE_MISSING_BILLS = 'Missing_Bills';
    public static final String RULE_STALLED_MATTER = 'Stalled_Matter';
    public static final String RULE_CLIENT_STATUS_UPDATE = 'Client_Status_Update';
    public static final Set<String> AUTOMATED_RULES = new Set<String>{
        RULE_TREATMENT_GAP,
        RULE_RECORDS_FOLLOW_UP,
        RULE_PROVIDER_ESCALATION,
        RULE_MISSING_BILLS,
        RULE_STALLED_MATTER,
        RULE_CLIENT_STATUS_UPDATE
    };
    public static final String SOURCE_AGENT = 'Agent';
    public static final String SOURCE_INBOUND = 'Inbound_Response';

    // Follow_Up_Recommendation__c.Recommendation_Type__c
    public static final String TYPE_CLIENT_CHECK_IN = 'Client_Check_In';
    public static final String TYPE_TREATMENT_GAP_REVIEW = 'Treatment_Gap_Review';
    public static final String TYPE_PROVIDER_FOLLOW_UP = 'Provider_Follow_Up';
    public static final String TYPE_PROVIDER_ESCALATION = 'Provider_Escalation';
    public static final String TYPE_MISSING_BILLS = 'Missing_Bills';
    public static final String TYPE_STALLED_MATTER = 'Stalled_Matter_Review';
    public static final String TYPE_CLIENT_STATUS_UPDATE = 'Client_Status_Update';
    public static final String TYPE_INBOUND_REVIEW = 'Inbound_Response_Review';
    public static final String TYPE_CASE_MANAGER_ESCALATION = 'Case_Manager_Escalation';

    // Status__c
    public static final String STATUS_PENDING_REVIEW = 'Pending_Review';
    public static final String STATUS_APPROVED = 'Approved';
    public static final String STATUS_SENT = 'Sent';
    public static final String STATUS_SEND_FAILED = 'Send_Failed';
    public static final String STATUS_COMPLETED = 'Completed';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String STATUS_OVERRIDDEN = 'Overridden';
    public static final String STATUS_SUPERSEDED = 'Superseded';
    /** Statuses in which a recommendation is still being worked (Active_Key__c populated). */
    public static final Set<String> OPEN_STATUSES = new Set<String>{ STATUS_PENDING_REVIEW, STATUS_APPROVED, STATUS_SEND_FAILED };
    public static final Set<String> CLOSED_STATUSES = new Set<String>{
        STATUS_COMPLETED,
        STATUS_REJECTED,
        STATUS_OVERRIDDEN,
        STATUS_SUPERSEDED
    };

    // Audience__c
    public static final String AUDIENCE_CLIENT = 'Client';
    public static final String AUDIENCE_PROVIDER = 'Provider';
    public static final String AUDIENCE_INTERNAL = 'Internal';
    public static final Set<String> EXTERNAL_AUDIENCES = new Set<String>{ AUDIENCE_CLIENT, AUDIENCE_PROVIDER };

    // Channel__c
    public static final String CHANNEL_EMAIL = 'Email';
    public static final String CHANNEL_SMS = 'SMS';
    public static final String CHANNEL_FAX = 'Fax';
    public static final String CHANNEL_PHONE = 'Phone';
    public static final String CHANNEL_TASK = 'Task';

    // Draft_Source__c
    public static final String DRAFT_TEMPLATE = 'Template';
    public static final String DRAFT_AI = 'AI';
    public static final String DRAFT_MANUAL = 'Manual';

    // Priority__c
    public static final String PRIORITY_HIGH = 'High';
    public static final String PRIORITY_MEDIUM = 'Medium';
    public static final String PRIORITY_LOW = 'Low';

    // Response_Classification__c
    public static final String CATEGORY_UNCLEAR = 'Unclear';
    public static final String CATEGORY_PENDING = 'Pending_Classification';

    // Response_Classification_Rule__mdt.Next_Action__c
    public static final String ACTION_COMPLETE = 'Complete';
    public static final String ACTION_COMPLETE_AND_RECHECK = 'Complete_And_Recheck';
    public static final String ACTION_CASE_MANAGER_REVIEW = 'Case_Manager_Review';

    // Custom permissions
    public static final String PERM_APPROVE = 'Follow_Up_Approve_Communications';
    public static final String PERM_SEND = 'Follow_Up_Send_Communications';
    public static final String PERM_BULK_APPROVE = 'Follow_Up_Bulk_Approve';
    public static final String PERM_OVERRIDE = 'Follow_Up_Override_Recommendations';
}
