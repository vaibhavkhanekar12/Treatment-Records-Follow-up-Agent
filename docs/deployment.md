# Deployment Guide

## 1. Package directories and order

| Order | Directory | Contents | When |
|---|---|---|---|
| 0 | `prerequisites/` | Minimal Matter / Records Request / Medical Provider objects | **Only when the target org does not already have these objects.** Never deploy these sample definitions over an established firm's data model. |
| 1 | `force-app/` | Core follow-up solution, including the Treatment Visits trigger/handler | Every org |
| 2 | `analytics/` | Report types, reports, dashboard | After core |
| 3 | `agentforce/` | Prompt grounding + Einstein adapters (Apex) | Only orgs with Einstein generative AI / Agentforce |
| 4 | Manual | Prompt templates, agent, topics, actions | `agentforce.md` sections 5–7 |

**Important:** `Treatment_Visits__c` is an existing source object in the target org. The final automation does **not** deploy a new Treatment Visits object.

## 2. Pre-deployment checklist

- [ ] `docs/org-discovery.md` section 4 completed against the target org.
- [ ] `Treatment_Visits__c` exists.
- [ ] Treatment Visit fields match: `Matter__c`, `Provider__c`, `Visit_Start__c`, `Visit_End__c`, `Visit_Attended__c`, `Visit_Type__c`.
- [ ] No existing Treatment Visits trigger performs the same follow-up evaluation. Merge/deactivate duplicate automation before enabling this trigger.
- [ ] Status values in `Follow_Up_Setting.Default` match the org's Matter and Records Request picklists.
- [ ] No existing Flow or scheduled job already chases records or treatment gaps.
- [ ] Org-wide email address verified and configured.
- [ ] Deliverability set to "All email" in production.
- [ ] Compliance sign-off for AI features before enabling Agentforce/AI drafting.

## 3. Commands

### Scratch / developer org (full stack)

```bash
sf org login web --alias pi-dev
sf project deploy start --source-dir prerequisites --target-org pi-dev --wait 30
sf project deploy start --source-dir force-app --target-org pi-dev --wait 30
sf project deploy start --source-dir analytics --target-org pi-dev --wait 30
sf project deploy start --source-dir agentforce --target-org pi-dev --wait 30
sf org assign permset --name Follow_Up_Case_Manager --target-org pi-dev
sf apex run --file scripts/apex/create-sample-data.apex --target-org pi-dev
sf apex run test --target-org pi-dev --test-level RunLocalTests --code-coverage --result-format human --wait 30
```

For a scratch/dev org that does not contain the real Treatment Visits object, the repository's prerequisites are not a substitute for the firm's production Treatment Visits schema. Use the real Treatment Visits metadata in the integration/UAT org.

### Sandbox / production with the existing data model

First deploy the core solution and run local tests:

```bash
sf project deploy start --source-dir force-app --target-org pi-uat --test-level RunLocalTests --wait 60
```

Then deploy analytics and, if applicable, Agentforce:

```bash
sf project deploy start --source-dir analytics --target-org pi-uat --wait 30
sf project deploy start --source-dir agentforce --target-org pi-uat --test-level RunSpecifiedTests --tests FollowUpEinsteinTest --wait 30
```

### Windows / VS Code

From the repository root, use the Salesforce CLI in the VS Code terminal. For an existing Personal Injury org, **do not deploy the sample prerequisite objects over the firm's existing data model**.

```powershell
sf project deploy start --source-dir force-app --target-org Personal_Injury_Org --test-level RunLocalTests --wait 60
```

## 4. What the Treatment Visits automation does

`TreatmentVisitsTrigger` runs after Treatment Visit insert/update and sends the affected Matter IDs to `FollowUpTreatmentVisitEvalQueueable`.

The evaluator then:

1. Loads the Matter and related facts.
2. Reads `Treatment_Visits__c` for completed treatment using `Visit_Start__c` and `Visit_Attended__c`.
3. Reads future Treatment Visits to determine whether an upcoming treatment exists.
4. Uses `Provider__c` to associate treatment with the medical provider.
5. Runs the deterministic follow-up rules.
6. Creates/suppresses/supersedes `Follow_Up_Recommendation__c` records according to the existing idempotency rules.
7. Creates internal Tasks for configured escalations.
8. Updates stalled Matter flags when the configured conditions are met.

The trigger is bulk-safe: it collects Matter IDs first and queues one asynchronous evaluation for the transaction.

## 5. Post-deployment configuration

1. **Automation user.** Create or choose an integration user, assign `Follow_Up_Automation`, then schedule the nightly evaluation.
2. **Treatment Visits access.** The `Follow_Up_Automation` permission set now grants read/View All access to `Treatment_Visits__c` and read access to the fields used by the evaluator.
3. **Case managers.** Assign `Follow_Up_Case_Manager` and supervisors `Follow_Up_Supervisor` as appropriate.
4. **Work queue.** Add *Follow-up Work Queue* to the firm's Lightning app navigation.
5. **Page layout.** Assign the Follow-up Recommendation layout to relevant profiles.
6. **Reports.** Share Follow-up Reports/Dashboards with case-manager and supervisor groups.
7. **Tune thresholds** in *Custom Metadata Types → Follow-up Rule*.
8. **Integrations (optional).** Configure SMS/e-fax channel implementations if required.
9. **Agentforce (optional).** Configure the agent and AI features only after deterministic evaluation is working.

## 6. Rollback

- Delete the nightly scheduled job.
- Set individual follow-up rules `Active__c = false`.
- Disable `TreatmentVisitsTrigger` if an emergency rollback is required.
- Turn off AI by clearing the configured AI class names.

The automation owns only its `Follow_Up_Recommendation__c` records, its Tasks, and the two Matter stalled fields. It does not create or replace Treatment Visit records.

## 7. Validation checklist

After deployment, create or update a Treatment Visit for a test Matter and verify:

- Treatment Visit has a valid `Matter__c`.
- `Visit_Attended__c = true` for a completed visit.
- `Visit_Start__c` is populated.
- `Provider__c` is populated when provider-specific follow-up is required.
- The Matter is re-evaluated asynchronously.
- A qualifying Treatment Gap recommendation is created only when there is no future Treatment Visit.
- Creating the same qualifying state again does not create a duplicate recommendation.
- Adding a new attended Treatment Visit causes an existing open Treatment Gap recommendation to become superseded when the rule condition is no longer true.
- Missing-bills logic uses the provider from the Treatment Visit.
- A future Treatment Visit prevents a Treatment Gap recommendation.

## 8. Personal Injury requirement alignment

- Daily monitoring: `FollowUpNightlyScheduler → FollowUpEvaluationBatch → FollowUpEvaluationService`.
- Treatment gaps: the latest attended Treatment Visit is the treatment anchor.
- Records follow-up: `Follow_Up_Rule.Records_Follow_Up` tracks request age and repeat cadence.
- Second provider miss escalation: `Follow_Up_Rule.Provider_Escalation` escalates after the configured number of provider follow-ups.
- Missing bills: attended Treatment Visits are grouped by `Provider__c` and compared with bill-type requests.
- Stalled matters: treatment, records activity and client-contact staleness are combined into the stalled-risk signal.
- Human-in-the-loop: external recommendations remain pending review until authorized approval.
- Scheduled sending: only due recommendations already in Approved status are sent.
- AI boundaries: AI is limited to drafting, summarization/rationale and inbound classification. Eligibility and escalation remain deterministic.
