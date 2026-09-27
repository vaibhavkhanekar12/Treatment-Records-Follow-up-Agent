/**
 * Template drafting, facts rendering, AI result application and the restricted-topic guard.
 */
@IsTest
private class FollowUpDraftServiceTest {
    private static final Date TODAY = Date.today();

    @IsTest
    static void guardDetectsRestrictedTermsAsWholeWords() {
        FollowUpTestDataFactory.useDefaultConfig();
        Assert.areEqual('settlement', FollowUpDraftGuard.findRestrictedTerm('About your Settlement offer'), 'Case-insensitive match');
        Assert.areEqual('liability', FollowUpDraftGuard.findRestrictedTerm('liability is clear'), 'Legal conclusion blocked');
        Assert.isNull(FollowUpDraftGuard.findRestrictedTerm('Please confirm your appointment.'), 'Neutral text passes');
        Assert.isNull(FollowUpDraftGuard.findRestrictedTerm(null), 'Null safe');
        Assert.isTrue(FollowUpDraftGuard.isSafe('Checking in', 'Any upcoming appointments?', 'Gap exceeds threshold'), 'Safe draft');
    }

    @IsTest
    static void applyAiResultsAcceptsSafeAndRejectsUnsafeOrFailed() {
        FollowUpTestDataFactory.useDefaultConfig();
        Follow_Up_Recommendation__c safeRec = memoryRec(FollowUpConstants.AUDIENCE_CLIENT);
        Follow_Up_Recommendation__c unsafeRec = memoryRec(FollowUpConstants.AUDIENCE_CLIENT);
        Follow_Up_Recommendation__c failedRec = memoryRec(FollowUpConstants.AUDIENCE_PROVIDER);
        Follow_Up_Recommendation__c internalRec = memoryRec(FollowUpConstants.AUDIENCE_INTERNAL);

        List<FollowUpDraftResult> results = new List<FollowUpDraftResult>{
            result(safeRec.Id, true, 'Polished check-in', 'Gap of 30 days'),
            result(unsafeRec.Id, true, 'We expect a strong settlement', 'x'),
            result(failedRec.Id, false, 'ignored', 'ignored'),
            result(internalRec.Id, true, 'Should not become a message', 'Stalled: no activity in 60 days')
        };
        Map<Id, Follow_Up_Recommendation__c> byId = new Map<Id, Follow_Up_Recommendation__c>{
            safeRec.Id => safeRec,
            unsafeRec.Id => unsafeRec,
            failedRec.Id => failedRec,
            internalRec.Id => internalRec
        };

        Set<Id> accepted = FollowUpDraftService.applyAiResults(results, byId);

        Assert.isTrue(accepted.contains(safeRec.Id), 'Safe accepted');
        Assert.areEqual('Polished check-in', safeRec.Draft_Message__c, 'Message replaced');
        Assert.areEqual(FollowUpConstants.DRAFT_AI, safeRec.Draft_Source__c, 'Marked AI (not bulk-approvable)');
        Assert.areEqual('Template text', unsafeRec.Draft_Message__c, 'Unsafe draft discarded');
        Assert.areEqual(Label.FollowUp_AI_Draft_Withheld, unsafeRec.AI_Rationale__c, 'Reviewer informed');
        Assert.areEqual('Template text', failedRec.Draft_Message__c, 'Failure leaves the template');
        Assert.isNull(internalRec.Draft_Message__c, 'Internal items never get a message');
        Assert.areEqual('Stalled: no activity in 60 days', internalRec.AI_Rationale__c, 'Internal summary stored as rationale');
    }

    @IsTest
    static void resetApprovalClearsStamp() {
        Follow_Up_Recommendation__c rec = memoryRec(FollowUpConstants.AUDIENCE_CLIENT);
        rec.Status__c = FollowUpConstants.STATUS_APPROVED;
        rec.Approved_By__c = UserInfo.getUserId();
        rec.Approved_Date__c = System.now();
        FollowUpDraftService.resetApprovalIfNeeded(rec);
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, rec.Status__c, 'Back to review');
        Assert.isNull(rec.Approved_By__c, 'Stamp cleared');
    }

    @IsTest
    static void unresolvableGeneratorClassMeansTemplateOnly() {
        FollowUpTestDataFactory.useDefaultConfig();
        FollowUpConfig.settingOverride.AI_Draft_Generator_Class__c = 'Class_That_Does_Not_Exist';
        Assert.isNull(FollowUpDraftService.resolveAiGenerator(), 'Missing class -> no AI, no failure');
        FollowUpConfig.settingOverride.AI_Draft_Generator_Class__c = 'FollowUpConstants';
        Assert.isNull(FollowUpDraftService.resolveAiGenerator(), 'Wrong type -> no AI');
    }

    @IsTest
    static void providerDraftAndFactsUseVerifiedDataOnly() {
        FollowUpTestDataFactory.useDefaultConfig();
        Contact client = new Contact(FirstName = 'Jamie', LastName = 'Client', Birthdate = Date.newInstance(1985, 4, 12));
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client);
        Records_Request__c req = FollowUpTestDataFactory.memoryRequest(
            ctx,
            new Medical_Provider__c(Name = 'Metro PT'),
            'Records',
            'Requested',
            TODAY.addDays(-20)
        );
        Follow_Up_Recommendation__c rec = new Follow_Up_Recommendation__c(
            Matter__c = ctx.matter.Id,
            Recommendation_Type__c = FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            Audience__c = FollowUpConstants.AUDIENCE_PROVIDER,
            Channel__c = FollowUpConstants.CHANNEL_EMAIL,
            Records_Request__c = req.Id,
            Medical_Provider__c = req.Medical_Provider__c,
            Prior_Follow_Up_Count__c = 1
        );

        FollowUpDraftBuilder.applyTemplate(rec, ctx);
        String facts = FollowUpFactsBuilder.matterFacts(ctx, TODAY) + '\n' + FollowUpFactsBuilder.recommendationFacts(rec, ctx);

        Assert.isTrue(rec.Draft_Message__c.contains('follow-up number 2'), 'Second follow-up numbered');
        Assert.isTrue(rec.Draft_Message__c.contains('records request'), 'Request type in lower case');
        Assert.isTrue(rec.Draft_Subject__c.contains('records'), 'Subject');
        Assert.isTrue(facts.contains('Outstanding records requests: 1'), 'Outstanding count');
        Assert.isTrue(facts.contains('Firm name: Test Injury Law'), 'Firm from settings');
        Assert.isFalse(facts.contains(String.valueOf(ctx.matter.Id)), 'No record Ids');
        Assert.isFalse(facts.contains(String.valueOf(req.Id)), 'No record Ids');
        Assert.isFalse(facts.contains('1985'), 'Birthdate is not part of grounding facts');
    }

    private static Follow_Up_Recommendation__c memoryRec(String audience) {
        return new Follow_Up_Recommendation__c(
            Id = FollowUpTestDataFactory.fakeId(Follow_Up_Recommendation__c.SObjectType),
            Audience__c = audience,
            Draft_Message__c = audience == FollowUpConstants.AUDIENCE_INTERNAL ? null : 'Template text',
            Draft_Source__c = FollowUpConstants.DRAFT_TEMPLATE
        );
    }

    private static FollowUpDraftResult result(Id recId, Boolean success, String message, String rationale) {
        FollowUpDraftResult result = new FollowUpDraftResult(recId);
        result.success = success;
        result.message = message;
        result.rationale = rationale;
        result.source = FollowUpConstants.DRAFT_AI;
        return result;
    }
}
