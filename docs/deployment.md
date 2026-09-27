# Deployment Guide

## 1. Package directories and order

| Order | Directory | Contents | When |
|---|---|---|---|
| 0 | `prerequisites/` | Minimal Matter / Treatment Event / Records Request / Medical Provider objects | **Scratch/dev orgs only.** Never deploy to an org that already has these objects. Map fields instead (`org-discovery.md`). |
| 1 | `force-app/` | Core solution | Every org |
| 2 | `analytics/` | Report types, reports, dashboard | After core |
| 3 | `agentforce/` | Prompt grounding + Einstein adapters (Apex) | Only orgs with Einstein generative AI / Agentforce |
| 4 | Manual | Prompt templates, agent, topics, actions | `agentforce.md` sections 5–7 |

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
sf org login web --alias pi-dev                       # or: sf org create scratch -f config/project-scratch-def.json -a pi-dev
sf project deploy start --source-dir prerequisites --target-org pi-dev
sf project deploy start --source-dir force-app     --target-org pi-dev
sf project deploy start --source-dir analytics     --target-org pi-dev
sf org assign permset --name Follow_Up_Case_Manager --target-org pi-dev
sf apex run --file scripts/apex/create-sample-data.apex --target-org pi-dev
sf apex run test --target-org pi-dev --test-level RunLocalTests --code-coverage --result-format human --wait 30
```

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
