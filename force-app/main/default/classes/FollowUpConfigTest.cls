/**
 * Configuration loading and parsing.
 */
@IsTest
private class FollowUpConfigTest {
    @IsTest
    static void splitCsvTrimsAndDropsBlanks() {
        Set<String> values = FollowUpConfig.splitCsv(' Open , Treating,,Pre-Demand ');
        Assert.areEqual(new Set<String>{ 'Open', 'Treating', 'Pre-Demand' }, values, 'Trimmed values');
        Assert.isTrue(FollowUpConfig.splitCsv(null).isEmpty(), 'Null safe');
    }

    @IsTest
    static void activeRuleRequiresActiveFlagAndThreshold() {
        FollowUpTestDataFactory.useDefaultConfig();
        Assert.isNotNull(FollowUpConfig.getActiveRule(FollowUpConstants.RULE_TREATMENT_GAP), 'Active rule');
        FollowUpConfig.rulesOverride.get(FollowUpConstants.RULE_TREATMENT_GAP).Active__c = false;
        Assert.isNull(FollowUpConfig.getActiveRule(FollowUpConstants.RULE_TREATMENT_GAP), 'Inactive rule skipped');
        FollowUpConfig.rulesOverride.get(FollowUpConstants.RULE_MISSING_BILLS).Threshold_Days__c = null;
        Assert.isNull(
            FollowUpConfig.getActiveRule(FollowUpConstants.RULE_MISSING_BILLS),
            'Rule without threshold skipped, never defaulted'
        );
        Assert.isNull(FollowUpConfig.getActiveRule('Unknown_Rule'), 'Unknown rule');
    }

    @IsTest
    static void settingsAccessorsAndSafeDefaults() {
        FollowUpTestDataFactory.useDefaultConfig();
        Assert.isTrue(FollowUpConfig.openMatterStatuses().contains('Treating'), 'Open statuses');
        Assert.isTrue(FollowUpConfig.billRequestTypes().contains('Bills'), 'Bill types');
        Assert.areEqual(0.7, FollowUpConfig.classificationThreshold(), 'Threshold');
        Assert.areEqual(200, FollowUpConfig.batchSize(), 'Batch size');
        Assert.areEqual('Test Injury Law', FollowUpConfig.firmName(), 'Firm name');

        FollowUpConfig.settingOverride = new Follow_Up_Setting__mdt(DeveloperName = 'Default');
        Assert.isTrue(FollowUpConfig.openMatterStatuses().isEmpty(), 'Unconfigured: evaluate nothing');
        Assert.isTrue(FollowUpConfig.classificationThreshold() > 1, 'Unconfigured: every response goes to review');
        Assert.areEqual(100, FollowUpConfig.batchSize(), 'Safe batch size');
        Assert.areEqual(UserInfo.getOrganizationName(), FollowUpConfig.firmName(), 'Falls back to org name');
        Assert.areEqual(0, FollowUpConfig.maxAiDraftsPerRun(), 'AI off by default');
    }

    @IsTest
    static void classificationRulesAreSortedAndDeployedRecordsLoad() {
        FollowUpTestDataFactory.useDefaultConfig();
        List<Response_Classification_Rule__mdt> rules = FollowUpConfig.getClassificationRules();
        Assert.areEqual('Opt_Out', rules[0].Category__c, 'Lowest sort order first');
        Assert.areEqual('Unclear', rules[rules.size() - 1].Category__c, 'Catch-all last');
        Assert.isNotNull(FollowUpConfig.getClassificationRule('Records_Sent'), 'Lookup by category');

        // Deployed CMDT records (no override) must load without error.
        FollowUpConfig.rulesOverride = null;
        FollowUpConfig.settingOverride = null;
        FollowUpConfig.classificationOverride = null;
        Assert.isNotNull(FollowUpConfig.getRules(), 'Deployed rules load');
        Assert.isNotNull(FollowUpConfig.getSetting(), 'Deployed setting loads');
        Assert.isNotNull(FollowUpConfig.getClassificationRules(), 'Deployed classification rules load');
    }
}
