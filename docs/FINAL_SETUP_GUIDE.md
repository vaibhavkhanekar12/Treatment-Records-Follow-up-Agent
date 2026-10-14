# Final Setup Guide — Treatment & Records Follow-up Agent

**Repository:** [vaibhavkhanekar12/Treatment-Records-Follow-up-Agent](https://github.com/vaibhavkhanekar12/Treatment-Records-Follow-up-Agent)  
**Audience:** Salesforce admin, developer, and Personal Injury operations lead  
**Recommended rollout:** Sandbox/UAT first  
**Document status:** Setup runbook for the repository. It is not evidence that a Salesforce org has already been deployed, configured, or validated.

---

## 1. What the agent does

The solution helps a Personal Injury law firm identify operational follow-ups across open matters. It uses Apex and Custom Metadata to evaluate business rules, creates follow-up recommendations and internal tasks, and provides a Salesforce work queue. Agentforce is an optional assistant for grounded summaries, draft communications, and inbound-response classification.

Core use cases:
- Treatment gaps and client check-ins
- Outstanding medical records and provider follow-ups
- Escalation after repeated unanswered provider follow-ups
- Missing medical bills
- Stalled-matter operational signals
- Monthly client status update drafts
- Inbound response classification and case-manager review
- Work queue, audit history, reporting, and notifications

**Guardrails**
- The solution is not a lawyer or medical professional and must not provide legal/medical advice, decide liability, assess case value, or discuss settlement merits.
- Apex/Custom Metadata determine eligibility, cadence, and escalation. AI must not replace these deterministic decisions.
- Every outbound client/provider communication must pass the existing authorized human-approval workflow. Do not let intake or an AI action bypass it.
- Do not deploy the sample `Matter__c` object definition over an established firm's existing object.

## 2. Repository areas

| Path | Purpose |
|---|---|
| `force-app/` | Core Salesforce objects, fields, Apex, flows/UI, permission sets, Custom Metadata, and notification metadata |
| `prerequisites/` | Sample/foundational data model. Deploy only after comparing it with the target org |
| `agentforce/` | Apex adapters/actions used by Agentforce features |
| `analytics/` | Reports, report types, and dashboards |
| `scripts/deploy-personal-injury.ps1` | Ordered Windows deployment script for the Personal Injury org |
| `scripts/apex/schedule-nightly.apex` | Scheduling entry point for the nightly evaluation |
| `docs/org-discovery.md` | Target-org schema and automation discovery |
| `docs/deployment.md` | Detailed deployment, rollout, and rollback notes |
| `docs/agentforce.md` | Manual Agentforce and Prompt Builder setup |
| `docs/security.md` | Security and AI guardrails |
| `docs/AUTOMATIC_INTAKE_IMPLEMENTATION_PLAN.md` | Scope and current limitations of automatic intake |

## 3. Prerequisites

Before starting, make sure you have:
1. A Salesforce sandbox/UAT org and permission to deploy metadata.
2. Salesforce CLI (`sf`) installed.
3. An authenticated org alias.
4. Admin/developer access to inspect objects, fields, picklists, validation rules, flows, sharing, FLS, and scheduled jobs.
5. Business/compliance approval for processing medical/legal case information and enabling AI.
6. A verified org-wide email address and email deliverability configuration before testing email delivery.
7. Agentforce/Einstein licenses and permissions if the optional AI features are to be enabled.

Never commit access tokens, passwords, private keys, or an SFDX auth URL to source control.

## 4. Keep Windows paths short

If Windows Explorer reports **0x80010135: Path too long** while copying/extracting the repository, cancel the copy rather than skipping files. Use a short folder such as `C:\SF\Treatment-Records-Follow-up-Agent`. Clone or extract the repository there. A skipped file can leave the source incomplete.

## 5. Authenticate and inspect the target org

Run these commands from the repository root:

```powershell
sf --version
sf org login web --alias pi-uat
sf org display --target-org pi-uat
```

Use your actual alias in subsequent commands. Confirm the org username and instance are correct before deployment.

### Required schema discovery

Complete `docs/org-discovery.md` before deploying. Confirm actual API names, field types, required fields, picklist values, lookup relationships, validation/duplicate rules, and existing automation for:

- `Matter__c` (the target org is expected to already have this object)
- `Treatment_Visits__c`
- `Records_Request__c`
- `Medical_Provider__c`
- `Contact` and `Task`

Also check for existing jobs/flows that already perform similar follow-ups to avoid duplicate communications. The sample data model in `prerequisites/` is not a mandate to replace the firm's data model. If the target org differs from the repository schema, stop and map/adjust the implementation before deploying.

## 6. Deploy in the recommended order

### Personal Injury org with an existing `Matter__c`

From the repository root, run:

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg pi-uat
```

Replace `pi-uat` with the alias confirmed in the previous step. The script stages dependencies and then deploys the solution. It is designed not to deploy the sample `Matter__c` object definition in the normal Personal Injury path.

**Important:** This script is appropriate only after confirming that its field/object assumptions match the target org. Review the output of each stage. If any stage fails, stop and resolve the first error before attempting later deployments. Do not treat a cascade of missing-type compiler errors as independent defects.

### If the supporting objects already exist

Do not blindly deploy duplicate or incompatible definitions. Follow `docs/deployment.md`, compare the org schema with repository metadata, and only use `-SkipPrerequisites` when the existing objects and fields are compatible with the code. This flag does not automatically map different API names.

### Scratch/developer org that needs the complete sample model

Only for a disposable org that genuinely lacks the sample data model:

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg pi-dev -DeployFullPrerequisites
```

Do not use this option against an established firm's org.

### Confirm deployment and tests

The script's success message only reports that its CLI deployment stages completed; separately verify the deployment in Salesforce Setup and run the relevant tests. For example:

```powershell
sf apex run test --target-org pi-uat --test-level RunLocalTests --code-coverage --result-format human --wait 30
```

Review all failures and code coverage. If the deployment command returns a job ID because it has not finished within the wait period, check its status with the Salesforce CLI deploy report command. Do not mark the rollout complete until deployment and test results have been inspected.

## 7. Post-deployment configuration

Perform these tasks in the sandbox/UAT org after metadata deployment:

1. **Permission sets:** Assign `Follow_Up_Case_Manager` to case managers and `Follow_Up_Supervisor` to supervising attorneys. Assign `Follow_Up_Automation` to the dedicated automation user. Apply the automatic-intake reviewer permission set only to staff who should review intake items.
2. **Work queue:** Add the Follow-up Work Queue tab/component to the appropriate Lightning app/navigation and, if required, the Matter record page.
3. **Page layouts and access:** Check object permissions, field-level security, record sharing, tab visibility, and page-layout assignments for the intended personas. Validate with a non-admin test user.
4. **Email:** Verify the org-wide email address, sender/domain policy, and deliverability. Test only with approved internal/test addresses before any client/provider delivery.
5. **Custom Metadata:** Review the default Follow-up Rule, Follow-up Setting, and Response Classification Rule records. Confirm statuses and picklist values match the actual org. Tune thresholds/cadence with the operations owner; do not activate duplicate monthly-update rules if another process already sends those updates.
6. **Automation user:** Use a dedicated least-privilege user. Confirm the permissions needed by scheduled evaluation, notifications, and any approved-send workflow.
7. **Reports/dashboards:** Share the relevant report/dashboard folders with the correct case-manager and supervisor groups.
8. **External channels:** SMS/fax integrations require a real provider, Named/External Credentials, and a reviewed adapter. Until configured, use the documented Task/manual-delivery fallback.
9. **Run a controlled pilot:** Use test matters and test contacts; verify that recommendations are accurate and that rejected/unapproved messages cannot be sent.

## 8. Schedule the nightly evaluation

After deployment and configuration, run the scheduling script as the intended automation user:

```powershell
sf apex run --file scripts/apex/schedule-nightly.apex --target-org pi-uat
```

Then inspect **Setup → Scheduled Jobs** and confirm the expected job is present. Confirm it runs at the intended time and under the intended user.

The optional approved-message scheduler can deliver only recommendations that have already been approved and are due. Do not enable it if firm policy requires a person to click Send for every message. If enabling it, follow `docs/deployment.md` and verify the required custom permission and notification permissions first.

## 9. Configure Agentforce (manual org setup)

Agentforce Builder configuration is not completed solely by deploying Apex. Feature availability, labels, and navigation can vary by Salesforce release and license. Use `docs/agentforce.md` and the prompt bodies under `docs/prompt-templates/` as the source of truth.

Recommended configuration sequence:

1. Confirm Agentforce/Einstein features, licenses, permissions, and approved model availability in the target org.
2. Create/configure the internal case-management agent in Agentforce Builder.
3. Configure the three intended subagents:
   - **Matter Follow-up Review** — summarize verified matter and recommendation facts.
   - **Follow-up Drafting** — draft a client/provider message from approved facts and templates.
   - **Inbound Response Handling** — classify a reply and suggest a next operational step.
4. Add only the Apex/prompt actions documented in `docs/agentforce.md`. Confirm each action's inputs/outputs and require user confirmation for actions that write or escalate records.
5. Create/configure the Prompt Builder templates using the corresponding files in `docs/prompt-templates/`. Verify grounding uses current Salesforce facts and that outputs are structured as expected.
6. Keep external message approval and sending in the existing Salesforce workflow. The agent may prepare a draft or classification; it must not send a message or bypass approval.
7. Test in Agentforce Builder/Testing Center using representative synthetic or redacted scenarios, including missing facts, conflicting facts, low confidence, no matching matter, and an attempted request for legal/medical advice.
8. Activate only after review by the Salesforce owner and the firm's compliance/business owner. Record the version and test outcomes.

Use Salesforce's current Agentforce Builder terminology in the org; some releases use “subagents” where older documentation says “topics.”

## 10. Automatic intake: current implementation boundary

The automatic intake feature is an additional pipeline; it does not replace the follow-up engine.

The current feature branch includes the initial staging/inbound-processing code, an extractor interface, validated record-application services, a reviewer permission set/UI, and tests. **It is not yet an end-to-end autonomous extraction deployment.** In particular:

- A concrete, supported document-extraction adapter must be implemented and configured; an interface alone does not extract document content.
- The org's inbound email service/address and attachment constraints must be configured and tested.
- The review interface must be verified against the intended operational process; do not assume a complete edit/approve/reject workflow unless it has been implemented and tested in the org.
- Confidence thresholds, field mappings, matching, duplicate detection, source retention, retries, and access controls need target-org validation.
- Do not claim automatic record creation is live until the extractor, inbound channel, metadata, permissions, tests, and end-to-end scenarios have passed in a sandbox.

Until those prerequisites are completed, keep the extraction setting inactive and route unprocessed/uncertain items to review. Automatic intake must never authorize outbound communication.

## 11. Acceptance checklist

Use this checklist before a pilot is considered ready:

- [ ] Target-org schema discovery completed; no existing business object is overwritten.
- [ ] Ordered metadata deployment succeeded and the deployed components are visible in Setup.
- [ ] Relevant Apex tests pass; failures and coverage have been reviewed.
- [ ] Permission sets and field/record access verified with non-admin personas.
- [ ] Nightly evaluation job is scheduled and runs as the intended automation user.
- [ ] Test matters produce expected recommendations for treatment gaps, records delays, missing bills, provider escalation, and stale/stalled signals.
- [ ] Duplicate runs do not create duplicate active recommendations or duplicate intake records.
- [ ] External drafts remain pending approval; rejected/unapproved messages cannot be sent.
- [ ] Inbound responses are classified as suggestions for review, not as legal conclusions.
- [ ] Agentforce outputs are grounded in verified facts and pass negative/edge-case tests.
- [ ] Email sender and deliverability are verified using test addresses.
- [ ] Automatic intake is either disabled until complete or has passed end-to-end tests with a real configured extractor.
- [ ] Business/compliance owner signs off on pilot scope, retention, access, and communications.

## 12. Rollback and incident response

If the system creates incorrect recommendations or unexpected activity:

1. Disable the relevant Custom Metadata rule(s) or stop the scheduled job in **Setup → Scheduled Jobs**.
2. Disable the optional approved-send scheduler if any delivery behavior is unexpected.
3. Disable the Agentforce agent or its relevant actions if outputs are unsafe or ungrounded.
4. Keep outbound communication disabled while investigating; do not delete audit history as a quick fix.
5. Capture the deployment/job ID, failed test name, Apex exception, and affected record IDs without copying sensitive medical/document content into public logs or GitHub.
6. Correct the configuration/code in source control, redeploy to sandbox, and rerun the acceptance tests before re-enabling.

For detailed component-level rollback notes, see `docs/deployment.md` and `docs/security.md`.

## 13. Official Salesforce references

- [Salesforce CLI: Deploy metadata with `sf project deploy start`](https://developer.salesforce.com/docs/platform/salesforce-cli-reference/guide/cli_reference_project_deploy_start.html)
- [Salesforce Agentforce Developer Guide: Build and enhance Agentforce actions](https://developer.salesforce.com/docs/ai/agentforce/guide/get-started-actions.html)
- [Salesforce Help: Agentforce Builder overview](https://help.salesforce.com/s/articleView?id=ai.agent_builder_intro.htm&language=en_US&type=5)

---

**Go-live rule:** Treat the agent as not production-ready until the target org's schema, deployment, tests, permissions, scheduling, Agentforce configuration, communication approval path, and any enabled automatic-intake integration have been verified in that org.
