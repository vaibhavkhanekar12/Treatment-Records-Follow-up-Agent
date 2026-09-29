# Deployment Guide

## 1. Package directories and order

| Order | Directory | Contents | When |
|---|---|---|---|
| 0 | `prerequisites/` | Minimal Matter / Treatment Event / Records Request / Medical Provider objects | **Only when the target org does not already have these objects.** Never deploy these sample definitions over an established firm's data model. |
| 1 | `force-app/` | Core solution | Every org |
| 2 | `analytics/` | Report types, reports, dashboard | After core |
| 3 | `agentforce/` | Prompt grounding + Einstein adapters (Apex) | Only orgs with Einstein generative AI / Agentforce |
| 4 | Manual | Prompt templates, agent, topics, actions | `agentforce.md` sections 5–7 |

**Important:** Package directories that contain dependent metadata may need to be deployed sequentially. This repository keeps the foundational data model in `prerequisites/` so the dependent solution can be compiled only after those objects exist in the target org.

## 2. Pre-deployment checklist

- [ ] `docs/org-discovery.md` section 4 completed against the target org (object and field names, status values, existing automation).
- [ ] Status values in `Follow_Up_Setting.Default` match the org's picklists.
- [ ] No existing Flow or scheduled job already chases records or treatment gaps (avoid double follow-ups).
- [ ] Org-wide email address verified, and its address entered in `Follow_Up_Setting.Default.Org_Wide_Email_Address__c`.
- [ ] Deliverability set to "All email" (production).
- [ ] Compliance sign-off for AI features (see `security.md` section 6) before step 3/4.

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

### Personal Injury org — one-command ordered deployment (Windows)

If the target Personal Injury org is missing `Medical_Provider__c` and `Records_Request__c` (the dependencies shown in the deployment errors), **do not use VS Code's "Deploy Source to Org" on `force-app` directly**. Run the staged deployment instead:

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
```

Or from Command Prompt:

```cmd
scripts\deploy-personal-injury.cmd Personal_Injury_Org
```

The target Personal Injury org is expected to already have only `Matter__c`. The script performs four separate deployments and stops immediately if a stage fails:

1. Required fields on the existing `Matter__c`
2. Creates `Medical_Provider__c`, `Records_Request__c`, and `Treatment_Event__c`
3. `Follow_Up_Rule__mdt` + `Follow_Up_Setting__mdt` + `Response_Classification_Rule__mdt`
4. `force-app` + `agentforce` + `analytics`

The script never deploys the sample `Matter__c` object definition in the normal Personal Injury path, so the existing Matter data model is not replaced. This ordering is intentional because Salesforce recommends separating metadata deployments when dependencies exist. Use `-DeployFullPrerequisites` only for a scratch/developer org that genuinely needs the complete sample data model.


### Sandbox / production (existing data model)
```bash
# 1. Validate core with all local tests (no changes made)
sf project deploy validate --source-dir force-app --target-org pi-uat --test-level RunLocalTests --wait 60
# 2. Quick-deploy the validated job
sf project deploy quick --job-id <validation-job-id> --target-org pi-uat
# 3. Analytics
sf project deploy start --source-dir analytics --target-org pi-uat
# 4. Agentforce Apex (only when Einstein generative AI is enabled)
sf project deploy start --source-dir agentforce --target-org pi-uat --test-level RunSpecifiedTests --tests FollowUpEinsteinTest
```

## 4. Post-deployment configuration

1. **Automation user.** Create or choose an integration user, assign `Follow_Up_Automation`, then log in as that user (or use `sf org login` with that user) and run:
   ```bash
   sf apex run --file scripts/apex/schedule-nightly.apex --target-org pi-uat
   ```
2. **Permission sets.** Assign `Follow_Up_Case_Manager` to case managers and `Follow_Up_Supervisor` to supervising attorneys (or add them to existing persona permission set groups).
3. **Work queue.** The *Follow-up Work Queue* tab is visible through the permission sets. Add it to the firm's Lightning app navigation. Optionally, drag **Follow-up Work Queue** onto the Matter record page in Lightning App Builder (it filters to that matter and offers "Evaluate this matter").
4. **Page layout.** Assign "Follow-up Recommendation Layout" to the relevant profiles (all fields are read-only by design).
5. **Reports.** Share the *Follow-up Reports* and *Follow-up Dashboards* folders with the case-manager and supervisor groups.
6. **Tune thresholds** in *Custom Metadata Types → Follow-up Rule*. Start with `Client_Status_Update` inactive if the firm already sends monthly updates.
7. **Integrations (optional).** Implement `IFollowUpChannel` for SMS/e-fax with Named/External Credentials, then set `SMS_Channel_Class__c` / `Fax_Channel_Class__c`. Until then those channels create manual delivery Tasks.
8. **Agentforce (optional).** Follow `agentforce.md` sections 5–7, then enable AI in `Follow_Up_Setting.Default`.

## 5. Rollout recommendation

| Phase | Configuration | Goal |
|---|---|---|
| Baseline (2–4 weeks) | Rules active, AI off; case managers use the queue but may reject freely | Capture baseline KPIs, tune thresholds |
| Pilot | 1–2 case managers; SMS/fax via manual Tasks | Validate tone, cadence, escalation volume |
| AI drafting | Enable the draft generator for a pilot group; review withheld-draft rate | Measure edit rate of AI drafts vs templates |
| Firm-wide | All case managers; dashboard to supervising attorneys | KPIs in `business-analysis.md` |

## 6. Rollback

- Stop the job: *Setup → Scheduled Jobs → "Treatment & Records Follow-up - Nightly Evaluation" → Delete*.
- Turn off individual rules: `Active__c = false`.
- Turn off AI: clear the two class-name fields in `Follow_Up_Setting.Default`.
- The solution adds no triggers and changes no existing records other than `Matter__c.Stalled__c`/`Stalled_Since__c` and its own recommendations and Tasks.

## 7. CI/CD

`.github/workflows/ci.yml` runs on every push to non-main branches and on pull requests:
- Prettier (parses every Apex class), ESLint, LWC Jest, `sf project convert source` for all package directories, and PMD (fails on High severity).
- `validate-deploy` runs `sf project deploy validate --test-level RunLocalTests` against an org **only if** the repository secret `SF_AUTH_URL` (an SFDX auth URL for a sandbox) is configured. Otherwise it is skipped with a notice.


## 7.1 Optional approved-message scheduler

After the nightly evaluator, optionally schedule FollowUpApprovedSendScheduler. It sends only external recommendations already approved by a human and whose Recommended_Date__c is due. Manual Send from the Work Queue remains available. Do not schedule it when the firm's process requires a human to click Send for every communication.

The automation user must have the Follow_Up_Send_Communications custom permission and the Send Custom Notifications user permission when in-app recommendation notifications are enabled.
## 8. Personal Injury requirement alignment

The implementation is intentionally mapped to the Treatment & Records Follow-up use case:

- Daily monitoring: FollowUpNightlyScheduler → FollowUpEvaluationBatch → FollowUpEvaluationService.
- Treatment gaps: Follow_Up_Rule.Treatment_Gap compares the latest treatment/sign-up anchor with today and creates an approval-controlled client check-in.
- Records follow-up: Follow_Up_Rule.Records_Follow_Up tracks request age and repeat cadence.
- Second provider miss escalation: Follow_Up_Rule.Provider_Escalation escalates after two sent provider follow-ups and automatically creates an internal case-manager Task.
- Missing bills: the rule engine checks treatment events against bill-request activity.
- Client contact recency: completed client Tasks are included in matter facts and the stalled condition.
- Stalled/at-risk matters: treatment, records activity and client-contact staleness are combined into a rule-based stalled-risk signal and persisted to Matter__c.Stalled__c / Stalled_Since__c.
- Monthly client status: Client_Status_Update creates a plain-language client update recommendation on a configurable cadence.
- Human-in-the-loop: external recommendations remain pending review until an authorized case manager approves them; bulk approval is restricted to eligible template drafts.
- Scheduled sending: FollowUpApprovedSendScheduler sends only due recommendations already in Approved status.
- Audit: approval, send, delivery, response classification and follow-up dates remain on Follow_Up_Recommendation__c.
- ROI data: Gap_Days__c and Records_Age_Days__c support treatment-gap and records-delay KPI reporting; the reporting layer should be mapped to the firm's actual data model before production rollout.
- AI boundaries: AI is limited to drafting, summarization/rationale and inbound classification. Eligibility and escalation decisions remain deterministic.

## 9. Missing prerequisite objects / cascading deployment errors

If deployment errors show invalid or missing types such as `Medical_Provider__c` or `Records_Request__c`, do not treat the resulting Apex errors as independent defects. They are usually cascading metadata/compiler errors caused by the missing foundational objects.

The same applies to errors such as:

- `referenceTo value ... does not resolve to a valid sObject type`
- `Invalid type: Medical_Provider__c`
- `DML requires SObject or SObject list type`
- `Variable does not exist: provider`
- `Invalid type: Response_Classification_Rule__mdt`
- `Custom metadata type Response_Classification_Rule__mdt is not available in this organization`

### If the target org does not have the prerequisite objects

Run the ordered deployment script:

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
```

Or run the three ordered deployments manually:

```bash
sf project deploy start --source-dir prerequisites/main/default/objects/Medical_Provider__c --source-dir prerequisites/main/default/objects/Records_Request__c --target-org Personal_Injury_Org --wait 30
sf project deploy start --source-dir force-app/main/default/objects/Follow_Up_Rule__mdt --source-dir force-app/main/default/objects/Follow_Up_Setting__mdt --source-dir force-app/main/default/objects/Response_Classification_Rule__mdt --target-org Personal_Injury_Org --wait 30
sf project deploy start --source-dir force-app --source-dir agentforce --source-dir analytics --target-org Personal_Injury_Org --wait 30
```

**Do not** continue to the next command if the previous command failed.

### If the target org already has those objects

Do not deploy `prerequisites/`. Instead, confirm the real org's API names and field relationships in `docs/org-discovery.md`, map the solution to that data model, and deploy only the solution packages.

This separation is intentional because dependent package directories can require sequential deployments.
