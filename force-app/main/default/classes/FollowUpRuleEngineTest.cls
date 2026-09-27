/**
 * Pure unit tests of the deterministic rule engine (in-memory facts, no DML).
 */
@IsTest
private class FollowUpRuleEngineTest {
    private static final Date TODAY = Date.today();

    private static FollowUpRuleEngine.Result run(FollowUpMatterContext ctx) {
        return new FollowUpRuleEngine(TODAY).evaluate(new List<FollowUpMatterContext>{ ctx });
    }

    private static List<Follow_Up_Recommendation__c> ofType(FollowUpRuleEngine.Result result, String recType) {
        List<Follow_Up_Recommendation__c> matches = new List<Follow_Up_Recommendation__c>();
        for (FollowUpRuleEngine.Candidate candidate : result.candidates) {
            if (candidate.recommendation.Recommendation_Type__c == recType) {
                matches.add(candidate.recommendation);
            }
        }
        return matches;
    }

    private static Contact client(String email, String mobile) {
        return new Contact(FirstName = 'Jamie', LastName = 'Client', Email = email, MobilePhone = mobile);
    }

    // ------------------------------------------------------------------ treatment gap

    @IsTest
    static void recentTreatmentCreatesNoCheckIn() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', '5550001'));
        ctx.lastTreatmentDate = TODAY.addDays(-5);

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, result.candidates.size(), 'Treatment 5 days ago is within the 21-day threshold');
    }

    @IsTest
    static void treatmentGapCreatesClientCheckInBySms() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', '5550001'));
        ctx.lastTreatmentDate = TODAY.addDays(-30);

        FollowUpRuleEngine.Result result = run(ctx);

        List<Follow_Up_Recommendation__c> recs = ofType(result, FollowUpConstants.TYPE_CLIENT_CHECK_IN);
        Assert.areEqual(1, recs.size(), 'One client check-in expected');
        Follow_Up_Recommendation__c rec = recs[0];
        Assert.areEqual(30, rec.Gap_Days__c, 'Gap days recorded');
        Assert.areEqual(FollowUpConstants.AUDIENCE_CLIENT, rec.Audience__c, 'Client audience');
        Assert.areEqual(FollowUpConstants.CHANNEL_SMS, rec.Channel__c, 'Preferred SMS channel used when a mobile exists');
        Assert.areEqual(FollowUpConstants.STATUS_PENDING_REVIEW, rec.Status__c, 'Always starts pending human review');
        Assert.areEqual(FollowUpConstants.PRIORITY_MEDIUM, rec.Priority__c, 'Below high-priority days');
        Assert.areEqual(FollowUpConstants.DRAFT_TEMPLATE, rec.Draft_Source__c, 'Template draft attached');
        Assert.isTrue(rec.Draft_Message__c.contains('Jamie'), 'Draft uses the client first name');
        Assert.isFalse(rec.Draft_Message__c.contains(String.valueOf(ctx.matter.Id)), 'Draft never contains record Ids');
        Assert.isTrue(result.activeConditionKeys.contains(rec.Dedupe_Key__c), 'Condition key tracked');
    }

    @IsTest
    static void treatmentGapFallsBackToEmailThenPhone() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext emailOnly = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', null));
        emailOnly.lastTreatmentDate = TODAY.addDays(-60);
        FollowUpMatterContext noChannel = FollowUpTestDataFactory.context(TODAY.addDays(-90), client(null, null));
        noChannel.lastTreatmentDate = TODAY.addDays(-60);

        FollowUpRuleEngine.Result result = new FollowUpRuleEngine(TODAY).evaluate(new List<FollowUpMatterContext>{ emailOnly, noChannel });

        List<Follow_Up_Recommendation__c> recs = ofType(result, FollowUpConstants.TYPE_CLIENT_CHECK_IN);
        Assert.areEqual(2, recs.size(), 'Both matters need a check-in');
        Assert.areEqual(FollowUpConstants.CHANNEL_EMAIL, recs[0].Channel__c, 'Email when no mobile');
        Assert.isNotNull(recs[0].Draft_Subject__c, 'Email drafts have a subject');
        Assert.areEqual(FollowUpConstants.PRIORITY_HIGH, recs[0].Priority__c, '60 days >= 45 high-priority days');
        Assert.areEqual(FollowUpConstants.CHANNEL_PHONE, recs[1].Channel__c, 'Phone call script when no address');
        Assert.isTrue(recs[1].Reason__c.contains(Label.FollowUp_Reason_No_Channel.trim()), 'Reason explains missing channel');
    }

    @IsTest
    static void noTreatmentUsesSignUpDate() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-25), client('a@b.com', null));

        List<Follow_Up_Recommendation__c> recs = ofType(run(ctx), FollowUpConstants.TYPE_CLIENT_CHECK_IN);

        Assert.areEqual(1, recs.size(), 'No treatment 25 days after sign-up is a gap');
        Assert.areEqual(25, recs[0].Gap_Days__c, 'Gap measured from sign-up');
        Assert.isNull(recs[0].Last_Treatment_Date__c, 'No treatment date is invented');
    }

    @IsTest
    static void upcomingScheduledTreatmentSuppressesCheckIn() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', '5550001'));
        ctx.lastTreatmentDate = TODAY.addDays(-40);
        ctx.nextScheduledTreatmentDate = TODAY.addDays(3);

        Assert.areEqual(0, run(ctx).candidates.size(), 'Client already has an upcoming appointment');
    }

    @IsTest
    static void unansweredCheckInsEscalateToCaseManagerReview() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-120), client('a@b.com', '5550001'));
        ctx.lastTreatmentDate = TODAY.addDays(-50);
        String checkInKey = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_CLIENT_CHECK_IN, ctx.matter.Id);
        FollowUpTestDataFactory.memoryHistory(
            ctx,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            checkInKey,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-10)
        );
        FollowUpTestDataFactory.memoryHistory(
            ctx,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            checkInKey,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-20)
        );

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, ofType(result, FollowUpConstants.TYPE_CLIENT_CHECK_IN).size(), 'No third automated check-in');
        List<Follow_Up_Recommendation__c> reviews = ofType(result, FollowUpConstants.TYPE_TREATMENT_GAP_REVIEW);
        Assert.areEqual(1, reviews.size(), 'Case manager review raised');
        Assert.areEqual(FollowUpConstants.AUDIENCE_INTERNAL, reviews[0].Audience__c, 'Internal only');
        Assert.areEqual(FollowUpConstants.PRIORITY_HIGH, reviews[0].Priority__c, 'Escalations are high priority');
        Assert.areEqual(2, reviews[0].Prior_Follow_Up_Count__c, 'Unanswered count recorded');
        Assert.isNull(reviews[0].Draft_Message__c, 'Internal items carry no client draft');
    }

    @IsTest
    static void missingClientRaisesInternalReview() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), null);
        ctx.lastTreatmentDate = TODAY.addDays(-30);

        List<Follow_Up_Recommendation__c> reviews = ofType(run(ctx), FollowUpConstants.TYPE_TREATMENT_GAP_REVIEW);

        Assert.areEqual(1, reviews.size(), 'Missing client data surfaces as a review, not a silent skip');
        Assert.isTrue(reviews[0].Reason__c.contains(Label.FollowUp_Reason_No_Client.trim()), 'Reason explains missing client');
    }

    @IsTest
    static void missingDatesProduceWarningNotRecommendation() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(null, client('a@b.com', null));

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, result.candidates.size(), 'Nothing is inferred without dates');
        Assert.areEqual(1, result.warnings.size(), 'Data gap reported');
    }

    // ------------------------------------------------------------------ records requests

    @IsTest
    static void outstandingRequestCreatesProviderFollowUp() {
        FollowUpTestDataFactory.useOnlyRules(
            new Set<String>{ FollowUpConstants.RULE_RECORDS_FOLLOW_UP, FollowUpConstants.RULE_PROVIDER_ESCALATION }
        );
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', null));
        Records_Request__c req = FollowUpTestDataFactory.memoryRequest(
            ctx,
            new Medical_Provider__c(Name = 'Metro PT', Email__c = 'records@metropt.example'),
            'Records',
            'Requested',
            TODAY.addDays(-20)
        );

        List<Follow_Up_Recommendation__c> recs = ofType(run(ctx), FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP);

        Assert.areEqual(1, recs.size(), 'Provider follow-up expected at 20 days (threshold 14)');
        Assert.areEqual(req.Id, recs[0].Records_Request__c, 'Linked to the request');
        Assert.areEqual(20, recs[0].Records_Age_Days__c, 'Request age recorded');
        Assert.areEqual(FollowUpConstants.CHANNEL_EMAIL, recs[0].Channel__c, 'Provider email used');
        Assert.isTrue(recs[0].Draft_Message__c.contains('Metro PT'), 'Draft addressed to provider');
        Assert.isTrue(recs[0].Draft_Message__c.contains('follow-up number 1'), 'First follow-up numbered');
    }

    @IsTest
    static void receivedOrYoungRequestsAreIgnored() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_RECORDS_FOLLOW_UP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', null));
        Medical_Provider__c provider = new Medical_Provider__c(Name = 'Metro PT', Fax__c = '5550199');
        FollowUpTestDataFactory.memoryRequest(ctx, provider, 'Records', 'Received', TODAY.addDays(-60));
        FollowUpTestDataFactory.memoryRequest(ctx, provider, 'Records', 'Requested', TODAY.addDays(-3));
        FollowUpTestDataFactory.memoryRequest(ctx, provider, 'Records', 'Requested', null);

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, result.candidates.size(), 'Received and recent requests need no follow-up');
        Assert.areEqual(1, result.warnings.size(), 'Request without a date is reported');
    }

    @IsTest
    static void providerChannelFallsBackToFax() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_RECORDS_FOLLOW_UP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', null));
        FollowUpTestDataFactory.memoryRequest(
            ctx,
            new Medical_Provider__c(Name = 'Imaging', Fax__c = '5550199'),
            'Bills',
            'Requested',
            TODAY.addDays(-15)
        );

        List<Follow_Up_Recommendation__c> recs = ofType(run(ctx), FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP);

        Assert.areEqual(FollowUpConstants.CHANNEL_FAX, recs[0].Channel__c, 'Fax when the provider has no email');
    }

    @IsTest
    static void secondMissedFollowUpEscalates() {
        FollowUpTestDataFactory.useOnlyRules(
            new Set<String>{ FollowUpConstants.RULE_RECORDS_FOLLOW_UP, FollowUpConstants.RULE_PROVIDER_ESCALATION }
        );
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-120), client('a@b.com', null));
        Records_Request__c req = FollowUpTestDataFactory.memoryRequest(
            ctx,
            new Medical_Provider__c(Name = 'Metro PT', Email__c = 'r@m.example'),
            'Records',
            'Requested',
            TODAY.addDays(-45)
        );
        String key = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP, req.Id);
        FollowUpTestDataFactory.memoryHistory(
            ctx,
            FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            key,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-8)
        );
        FollowUpTestDataFactory.memoryHistory(
            ctx,
            FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            key,
            FollowUpConstants.STATUS_COMPLETED,
            System.now().addDays(-20)
        );

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, ofType(result, FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP).size(), 'No third provider follow-up');
        List<Follow_Up_Recommendation__c> escalations = ofType(result, FollowUpConstants.TYPE_PROVIDER_ESCALATION);
        Assert.areEqual(1, escalations.size(), 'Escalated after the second missed follow-up');
        Assert.areEqual(2, escalations[0].Prior_Follow_Up_Count__c, 'Follow-up count derived from history');
        Assert.isTrue(result.candidates[0].autoCreateTask, 'Escalation rule auto-creates a Task');
    }

    @IsTest
    static void escalationWaitsForThresholdAfterLastFollowUp() {
        FollowUpTestDataFactory.useOnlyRules(
            new Set<String>{ FollowUpConstants.RULE_RECORDS_FOLLOW_UP, FollowUpConstants.RULE_PROVIDER_ESCALATION }
        );
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-120), client('a@b.com', null));
        Records_Request__c req = FollowUpTestDataFactory.memoryRequest(
            ctx,
            new Medical_Provider__c(Name = 'Metro PT', Email__c = 'r@m.example'),
            'Records',
            'Requested',
            TODAY.addDays(-45)
        );
        String key = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP, req.Id);
        FollowUpTestDataFactory.memoryHistory(
            ctx,
            FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            key,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-2)
        );
        FollowUpTestDataFactory.memoryHistory(
            ctx,
            FollowUpConstants.TYPE_PROVIDER_FOLLOW_UP,
            key,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-15)
        );

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, result.candidates.size(), 'Last follow-up 2 days ago: neither escalate nor follow up again yet');
    }

    // ------------------------------------------------------------------ suppression / idempotency

    @IsTest
    static void openRecommendationSuppressesDuplicate() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-90), client('a@b.com', '5550001'));
        ctx.lastTreatmentDate = TODAY.addDays(-30);
        String key = FollowUpRuleEngine.dedupeKey(FollowUpConstants.TYPE_CLIENT_CHECK_IN, ctx.matter.Id);
        FollowUpTestDataFactory.memoryHistory(ctx, FollowUpConstants.TYPE_CLIENT_CHECK_IN, key, FollowUpConstants.STATUS_APPROVED, null);

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, result.candidates.size(), 'Open recommendation is not duplicated');
        Assert.areEqual(1, result.suppressedCount, 'Counted as suppressed');
        Assert.isTrue(result.activeConditionKeys.contains(key), 'Condition still holds (not superseded)');
    }

    @IsTest
    static void cadenceSnoozeAndRejectionSuppressUntilDue() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_TREATMENT_GAP });
        Follow_Up_Rule__mdt rule = FollowUpConfig.getActiveRule(FollowUpConstants.RULE_TREATMENT_GAP);
        FollowUpRuleEngine engine = new FollowUpRuleEngine(TODAY);

        FollowUpMatterContext recentlySent = FollowUpTestDataFactory.context(TODAY.addDays(-90), null);
        String key1 = 'K1';
        FollowUpTestDataFactory.memoryHistory(
            recentlySent,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            key1,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-3)
        );
        Assert.isTrue(engine.isSuppressed(recentlySent, key1, rule), 'Sent 3 days ago, repeat after 7');

        FollowUpMatterContext sentLongAgo = FollowUpTestDataFactory.context(TODAY.addDays(-90), null);
        FollowUpTestDataFactory.memoryHistory(
            sentLongAgo,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            key1,
            FollowUpConstants.STATUS_SENT,
            System.now().addDays(-10)
        );
        Assert.isFalse(engine.isSuppressed(sentLongAgo, key1, rule), 'Sent 10 days ago: due again');

        FollowUpMatterContext snoozed = FollowUpTestDataFactory.context(TODAY.addDays(-90), null);
        Follow_Up_Recommendation__c snooze = FollowUpTestDataFactory.memoryHistory(
            snoozed,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            key1,
            FollowUpConstants.STATUS_OVERRIDDEN,
            null
        );
        snooze.Next_Follow_Up_Date__c = TODAY.addDays(20);
        snooze.Closed_Date__c = System.now().addDays(-30);
        Assert.isTrue(engine.isSuppressed(snoozed, key1, rule), 'Snoozed until a future date');

        FollowUpMatterContext rejected = FollowUpTestDataFactory.context(TODAY.addDays(-90), null);
        Follow_Up_Recommendation__c rejection = FollowUpTestDataFactory.memoryHistory(
            rejected,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            key1,
            FollowUpConstants.STATUS_REJECTED,
            null
        );
        rejection.Closed_Date__c = System.now().addDays(-2);
        Assert.isTrue(engine.isSuppressed(rejected, key1, rule), 'Rejected 2 days ago: respect the case manager');

        FollowUpMatterContext superseded = FollowUpTestDataFactory.context(TODAY.addDays(-90), null);
        Follow_Up_Recommendation__c stale = FollowUpTestDataFactory.memoryHistory(
            superseded,
            FollowUpConstants.TYPE_CLIENT_CHECK_IN,
            key1,
            FollowUpConstants.STATUS_SUPERSEDED,
            null
        );
        stale.Closed_Date__c = System.now();
        Assert.isFalse(engine.isSuppressed(superseded, key1, rule), 'Superseded items never suppress');
    }

    // ------------------------------------------------------------------ missing bills / stalled / status update

    @IsTest
    static void treatmentWithoutBillsRequestRaisesMissingBills() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_MISSING_BILLS });
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-120), client('a@b.com', null));
        Medical_Provider__c withBills = new Medical_Provider__c(
            Id = FollowUpTestDataFactory.fakeId(Medical_Provider__c.SObjectType),
            Name = 'Ortho'
        );
        Medical_Provider__c withoutBills = new Medical_Provider__c(
            Id = FollowUpTestDataFactory.fakeId(Medical_Provider__c.SObjectType),
            Name = 'Chiro'
        );
        ctx.lastTreatmentByProvider.put(withBills.Id, TODAY.addDays(-40));
        ctx.lastTreatmentByProvider.put(withoutBills.Id, TODAY.addDays(-40));
        ctx.providers.put(withoutBills.Id, withoutBills);
        FollowUpTestDataFactory.memoryRequest(ctx, withBills, 'Records and Bills', 'Requested', TODAY.addDays(-10));

        List<Follow_Up_Recommendation__c> recs = ofType(run(ctx), FollowUpConstants.TYPE_MISSING_BILLS);

        Assert.areEqual(1, recs.size(), 'Only the provider without a bills request');
        Assert.areEqual(withoutBills.Id, recs[0].Medical_Provider__c, 'Correct provider');
        Assert.isTrue(recs[0].Reason__c.contains('Chiro'), 'Reason names the provider');
    }

    @IsTest
    static void stalledRequiresAllThreeSignals() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_STALLED_MATTER });
        FollowUpMatterContext stalled = FollowUpTestDataFactory.context(TODAY.addDays(-200), client('a@b.com', null));
        stalled.lastTreatmentDate = TODAY.addDays(-60);
        stalled.lastClientContactDate = TODAY.addDays(-40);
        FollowUpTestDataFactory.memoryRequest(stalled, new Medical_Provider__c(Name = 'Ortho'), 'Records', 'Requested', TODAY.addDays(-50));

        FollowUpMatterContext recentContact = FollowUpTestDataFactory.context(TODAY.addDays(-200), client('a@b.com', null));
        recentContact.lastTreatmentDate = TODAY.addDays(-60);
        recentContact.lastClientContactDate = TODAY.addDays(-2);

        FollowUpRuleEngine.Result result = new FollowUpRuleEngine(TODAY)
            .evaluate(new List<FollowUpMatterContext>{ stalled, recentContact });

        Assert.isTrue(result.stalledByMatter.get(stalled.matter.Id), 'All three stale -> stalled');
        Assert.isFalse(result.stalledByMatter.get(recentContact.matter.Id), 'Recent client contact -> not stalled');
        List<Follow_Up_Recommendation__c> recs = ofType(result, FollowUpConstants.TYPE_STALLED_MATTER);
        Assert.areEqual(1, recs.size(), 'One stalled review');
        Assert.areEqual(stalled.matter.Id, recs[0].Matter__c, 'For the stalled matter');
    }

    @IsTest
    static void monthlyStatusUpdateDueAndNotDue() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>{ FollowUpConstants.RULE_CLIENT_STATUS_UPDATE });
        FollowUpMatterContext due = FollowUpTestDataFactory.context(TODAY.addDays(-40), client('a@b.com', null));
        FollowUpMatterContext tooNew = FollowUpTestDataFactory.context(TODAY.addDays(-10), client('a@b.com', null));
        FollowUpMatterContext noAddress = FollowUpTestDataFactory.context(TODAY.addDays(-40), client(null, null));

        FollowUpRuleEngine.Result result = new FollowUpRuleEngine(TODAY)
            .evaluate(new List<FollowUpMatterContext>{ due, tooNew, noAddress });

        List<Follow_Up_Recommendation__c> recs = ofType(result, FollowUpConstants.TYPE_CLIENT_STATUS_UPDATE);
        Assert.areEqual(1, recs.size(), 'Only the matter past 30 days with an address');
        Assert.areEqual(FollowUpConstants.PRIORITY_LOW, recs[0].Priority__c, 'Rule default priority');
        Assert.areEqual(FollowUpConstants.DRAFT_TEMPLATE, recs[0].Draft_Source__c, 'Template draft: bulk-approvable');
        Assert.isTrue(recs[0].Draft_Message__c.contains('Treating'), 'Uses the matter stage');
        Assert.areEqual(1, result.warnings.size(), 'Missing address reported');
    }

    @IsTest
    static void inactiveRulesProduceNothing() {
        FollowUpTestDataFactory.useOnlyRules(new Set<String>());
        FollowUpMatterContext ctx = FollowUpTestDataFactory.context(TODAY.addDays(-300), client('a@b.com', '5550001'));
        ctx.lastTreatmentDate = TODAY.addDays(-200);

        FollowUpRuleEngine.Result result = run(ctx);

        Assert.areEqual(0, result.candidates.size(), 'All rules inactive');
        Assert.isTrue(result.stalledByMatter.isEmpty(), 'Stalled flag untouched when the rule is inactive');
    }

    @IsTest
    static void channelAndPriorityHelpers() {
        FollowUpTestDataFactory.useDefaultConfig();
        Contact optedOut = new Contact(LastName = 'X', Email = 'x@y.com', HasOptedOutOfEmail = true);
        Assert.areEqual(FollowUpConstants.CHANNEL_PHONE, FollowUpRuleEngine.clientChannel(optedOut, 'Email'), 'Email opt-out respected');
        Assert.areEqual(FollowUpConstants.CHANNEL_PHONE, FollowUpRuleEngine.providerChannel(null, 'Email'), 'Unknown provider -> phone');
        Follow_Up_Rule__mdt rule = FollowUpTestDataFactory.rule('X', 10, null, null, null, null, 'Email', false);
        Assert.areEqual(FollowUpConstants.PRIORITY_MEDIUM, FollowUpRuleEngine.priorityFor(rule, 100), 'Default when not configured');
    }
}
