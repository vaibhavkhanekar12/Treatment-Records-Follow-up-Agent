# Deployment Guide

## 1. Package directories and order

| Order | Directory | Contents | When |
|---|---|---|---|
| 0 | `prerequisites/` | Foundational Matter fields plus Treatment Visits, Records Request and Medical Provider objects/fields | Deploy when the target org is missing these solution-owned objects. Never deploy the sample Matter object over an established Matter data model. |
| 1 | `force-app/` | Core solution, Apex, flows/UI, permission sets and Custom Metadata | After prerequisite objects/fields |
| 2 | `analytics/` | Report types, reports, dashboard | After core |
| 3 | `agentforce/` | Prompt grounding + Einstein adapters (Apex) | Only orgs with Einstein generative AI / Agentforce |
| 4 | Manual | Prompt templates, agent, topics, actions | `agentforce.md` sections 5–7 |

**Important:** Package directories that contain dependent metadata may need to be deployed sequentially. This repository keeps the foundational data model in `prerequisites/` so the dependent solution can be compiled only after those objects exist in the target org.

## 2. Pre-deployment checklist

- [ ] `docs/org-discovery.md` completed against the target org.
- [ ] Confirm `Matter__c` already exists and the required Matter fields are compatible.
- [ ] Confirm the target org does not already contain a conflicting `Treatment_Visits__c`, `Records_Request__c`, or `Medical_Provider__c` object. If one exists, map the implementation instead of creating a duplicate object.
- [ ] Status values in `Follow_Up_Setting.Default` match the org's picklists.
- [ ] No existing Flow or scheduled job already chases records or treatment gaps.
- [ ] Org-wide email address verified.
- [ ] Compliance sign-off for AI features before enabling Agentforce.

## 3. Commands

### Personal Injury org — ordered deployment (Windows)

If the target org has `Matter__c` but is missing `Treatment_Visits__c`, `Medical_Provider__c`, and/or `Records_Request__c`, use the staged deployment script. **Do not deploy `force-app` first.**

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
```

Or:

```cmd
scripts\deploy-personal-injury.cmd Personal_Injury_Org
```

The script performs these stages:

1. Deploy required fields on the existing `Matter__c`.
2. Create `Medical_Provider__c`, `Records_Request__c`, and `Treatment_Visits__c`.
3. Deploy fields for those supporting objects, including all Treatment Visits fields used by the Apex automation.
4. Create Follow-up Custom Metadata Types.
5. Deploy Custom Metadata Type fields and records.
6. Deploy `force-app` + `agentforce` + `analytics`.

The `Treatment_Visits__c` object is included in `prerequisites/` for deployment where the target org does not have it. Its Medical field uses the org's `Medical__c` Master-Detail relationship to `Medical_Provider__c`.

### Scratch / developer org (full stack)

```bash
sf org login web --alias pi-dev
sf project deploy start --source-dir prerequisites --target-org pi-dev --wait 30
sf project deploy start --source-dir force-app --target-org pi-dev --wait 30
sf project deploy start --source-dir analytics --target-org pi-dev --wait 30
sf project deploy start --source-dir agentforce --target-org pi-dev --wait 30
sf org assign permset --name Follow_Up_Case_Manager --target-org pi-dev
sf apex run test --target-org pi-dev --test-level RunLocalTests --code-coverage --result-format human --wait 30
```

### Sandbox / production after validation

```bash
sf project deploy validate --source-dir prerequisites --target-org pi-uat --wait 60
```

Then deploy the remaining package directories after the prerequisite validation succeeds.

## 4. Treatment Visits metadata

The deployable object is:

`prerequisites/main/default/objects/Treatment_Visits__c/Treatment_Visits__c.object-meta.xml`

Fields included:

- `Matter__c` — Lookup to `Matter__c`
- `Medical__c` — Master-Detail to `Medical_Provider__c`
- `Visit_Start__c` — Date/Time
- `Visit_End__c` — Date/Time
- `Visit_Attended__c` — Checkbox
- `Visit_Type__c` — Picklist
- `Involved_Party__c` — Lookup to the `Involved_Party__c` object
- 

The follow-up engine reads Treatment Visits through `FollowUpMatterSelector`. Completed treatment is based on attended visits with a past `Visit_Start__c`; future visits are treated as upcoming appointments. The trigger re-evaluates the affected Matter when a Treatment Visit is inserted or relevant fields are updated.

## 5. Post-deployment configuration

1. Assign `Follow_Up_Automation` to the automation user.
2. Verify Treatment Visits object and field permissions with the intended non-admin test user.
3. Add the Follow-up Work Queue to the Lightning app/navigation as required.
4. Configure and test email delivery with test addresses.
5. Review Follow-up Custom Metadata thresholds before enabling the nightly job.
6. Run the nightly scheduler only after metadata, permissions and tests pass.
7. Configure Agentforce manually only if the org has the required Einstein/Agentforce features and licenses.

## 6. Validation

Run local tests after deployment:

```bash
sf apex run test --target-org Personal_Injury_Org --test-level RunLocalTests --code-coverage --result-format human --wait 30
```

Test at minimum:

1. Create an attended past Treatment Visit → Matter gets evaluated using the visit.
2. Create a future Treatment Visit → upcoming treatment is detected.
3. Update Visit Start/Medical/Attendance → Matter is re-evaluated.
4. Verify no duplicate active recommendations are created on repeated evaluation.
5. Verify the automation user can read all Treatment Visit fields used by Apex.

## 7. Rollback

If deployment or evaluation fails, stop the scheduled job and disable the affected rule(s). Do not delete audit/recommendation history as a first response. Fix the metadata/code in source control, redeploy to sandbox, and rerun tests before re-enabling automation.
