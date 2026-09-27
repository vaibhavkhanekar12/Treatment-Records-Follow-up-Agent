/**
 * Single access point for Treatment & Records Follow-up configuration (Custom Metadata).
 * Custom Metadata cannot be inserted by unit tests, so tests inject in-memory records through the
 * @TestVisible overrides below. Production code never reads the overrides.
 */
public with sharing class FollowUpConfig {
    public static final String SETTING_RECORD = 'Default';

    @TestVisible
    private static Map<String, Follow_Up_Rule__mdt> rulesOverride;
    @TestVisible
    private static Follow_Up_Setting__mdt settingOverride;
    @TestVisible
    private static List<Response_Classification_Rule__mdt> classificationOverride;

    private static Map<String, Follow_Up_Rule__mdt> rulesCache;
    private static Follow_Up_Setting__mdt settingCache;
    private static List<Response_Classification_Rule__mdt> classificationCache;

    /** All rules keyed by DeveloperName (active and inactive). */
    public static Map<String, Follow_Up_Rule__mdt> getRules() {
        if (rulesOverride != null) {
            return rulesOverride;
        }
        if (rulesCache == null) {
            rulesCache = new Map<String, Follow_Up_Rule__mdt>();
            for (Follow_Up_Rule__mdt rule : Follow_Up_Rule__mdt.getAll().values()) {
                rulesCache.put(rule.DeveloperName, rule);
            }
        }
        return rulesCache;
    }

    /** Returns the rule when it exists, is active and has a threshold; otherwise null (rule skipped). */
    public static Follow_Up_Rule__mdt getActiveRule(String developerName) {
        Follow_Up_Rule__mdt rule = getRules().get(developerName);
        if (rule == null || rule.Active__c != true || rule.Threshold_Days__c == null) {
            return null;
        }
        return rule;
    }

    public static Follow_Up_Setting__mdt getSetting() {
        if (settingOverride != null) {
            return settingOverride;
        }
        if (settingCache == null) {
            settingCache = Follow_Up_Setting__mdt.getInstance(SETTING_RECORD);
            if (settingCache == null) {
                // Missing configuration: evaluate nothing rather than guess which matters are open.
                settingCache = new Follow_Up_Setting__mdt(DeveloperName = SETTING_RECORD);
            }
        }
        return settingCache;
    }

    /** Classification rules ordered by Sort_Order__c ascending. */
    public static List<Response_Classification_Rule__mdt> getClassificationRules() {
        if (classificationOverride != null) {
            return sortRules(classificationOverride);
        }
        if (classificationCache == null) {
            classificationCache = sortRules(Response_Classification_Rule__mdt.getAll().values());
        }
        return classificationCache;
    }

    public static Response_Classification_Rule__mdt getClassificationRule(String category) {
        for (Response_Classification_Rule__mdt rule : getClassificationRules()) {
            if (rule.Category__c == category) {
                return rule;
            }
        }
        return null;
    }

    public static Set<String> openMatterStatuses() {
        return splitCsv(getSetting().Open_Matter_Statuses__c);
    }

    public static Set<String> outstandingRequestStatuses() {
        return splitCsv(getSetting().Outstanding_Request_Statuses__c);
    }

    public static Set<String> billRequestTypes() {
        return splitCsv(getSetting().Bill_Request_Types__c);
    }

    public static Set<String> excludedTreatmentStatuses() {
        return splitCsv(getSetting().Excluded_Treatment_Statuses__c);
    }

    public static List<String> restrictedTerms() {
        return new List<String>(splitCsv(getSetting().Restricted_Terms__c));
    }

    public static Decimal classificationThreshold() {
        Decimal threshold = getSetting().Classification_Confidence_Threshold__c;
        // Without a configured threshold every classification goes to human review.
        return threshold == null ? 1.01 : threshold;
    }

    public static Integer batchSize() {
        Decimal size = getSetting().Batch_Size__c;
        return (size == null || size < 1 || size > 2000) ? 100 : size.intValue();
    }

    public static Integer maxAiDraftsPerRun() {
        Decimal max = getSetting().Max_AI_Drafts_Per_Run__c;
        return max == null ? 0 : max.intValue();
    }

    public static String firmName() {
        String name = getSetting().Firm_Name__c;
        return String.isBlank(name) ? UserInfo.getOrganizationName() : name;
    }

    /** Parses a comma-separated CMDT value into a trimmed, de-duplicated, order-preserving set. */
    public static Set<String> splitCsv(String value) {
        Set<String> result = new Set<String>();
        if (String.isBlank(value)) {
            return result;
        }
        for (String part : value.split(',')) {
            if (String.isNotBlank(part)) {
                result.add(part.trim());
            }
        }
        return result;
    }

    public static Integer toInt(Decimal value) {
        return value == null ? null : value.intValue();
    }

    private static List<Response_Classification_Rule__mdt> sortRules(List<Response_Classification_Rule__mdt> rules) {
        List<RuleOrder> wrappers = new List<RuleOrder>();
        for (Response_Classification_Rule__mdt rule : rules) {
            wrappers.add(new RuleOrder(rule));
        }
        wrappers.sort();
        List<Response_Classification_Rule__mdt> sorted = new List<Response_Classification_Rule__mdt>();
        for (RuleOrder wrapper : wrappers) {
            sorted.add(wrapper.rule);
        }
        return sorted;
    }

    private class RuleOrder implements Comparable {
        private Response_Classification_Rule__mdt rule;
        private RuleOrder(Response_Classification_Rule__mdt rule) {
            this.rule = rule;
        }
        public Integer compareTo(Object other) {
            Decimal mine = rule.Sort_Order__c == null ? 9999 : rule.Sort_Order__c;
            Response_Classification_Rule__mdt otherRule = ((RuleOrder) other).rule;
            Decimal theirs = otherRule.Sort_Order__c == null ? 9999 : otherRule.Sort_Order__c;
            return mine == theirs ? 0 : (mine < theirs ? -1 : 1);
        }
    }
}
