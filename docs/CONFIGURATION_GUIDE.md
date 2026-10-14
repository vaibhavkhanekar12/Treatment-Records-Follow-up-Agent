# Configuration Guide — Treatment & Records Follow-up Agent

**Repository:** `vaibhavkhanekar12/Treatment-Records-Follow-up-Agent`  
**Configuration target:** Salesforce Personal Injury org  
**Status:** Setup runbook for the code in this repository. Follow each gate in order; this document does not imply that any org has already been configured.

## 1. Purpose and operating rules

The solution scans open Personal Injury matters, applies deterministic follow-up rules, creates recommendations/tasks, drafts messages, and helps case managers monitor responses.

- **Apex + Custom Metadata are the source of truth** for eligibility, cadence, priority and escalation.
- Agentforce/AI may summarize verified facts, classify inbound replies and draft communications; it must not invent missing facts or decide legal/medical merits.
- **Every external client/provider message requires authorized human approval before send.** The intake pipeline cannot approve or send messages.
- Do not create a second `Matter__c` definition in an established PI org. Map the solution to the org's existing schema first.
- Routine manual entry is not the goal. Automatic intake/record application only becomes operational after a supported extraction adapter is implemented, configured and tested. The current default extractor setting is intentionally inactive.

## 2. Prerequisites

Confirm before deployment:

- Salesforce CLI (`sf`) is installed and authenticated to the intended sandbox.
- The org has the required Salesforce features/licenses for the components you plan to enable.
- A technical admin can inspect object fields, picklist values, validation/duplicate rules, sharing, FLS, flows and scheduled jobs.
- The org's actual `Matter__c`, `Treatment_Visits__c`, `Records_Request__c`, `Medical_Provider__c`, Contact and Task schema is documented in `docs/org-discovery.md`.
- The business owner approves AI use for medical/legal case information, retention, sender/domain restrictions and communication templates before AI or inbound email is enabled.
- Use a sandbox/UAT org first. Never test with real client communications without approval.

## 3. Authenticate and identify the target org

Run from the repository root:

```bash
sf --version
sf org login web --alias pi-uat
sf org display --target-org pi-uat
```

Use the alias you authenticated to in all commands. Do not put access tokens, passwords, private keys or credential values in this repository.

## 4. Discover the org data model first

Before deployment, inspect the existing object and field API names, required fields, picklist values, lookups, validation rules and automation for:

- `Matter__c` (especially status, practice area, client, case manager and sign-up/demand dates)
- `Treatment_Visits__c`
- `Records_Request__c`
- `Medical_Provider__c`
- `Contact` and `Task`

Compare the actual schema with `prerequisites/` and `docs/org-discovery.md`. The files under `prerequisites/` are a sample data model, not a mandate to replace the firm's objects. If the real schema differs, map/adapt the code and metadata before proceeding. Do not assume a successful metadata deployment proves the business fields are mapped correctly.

## 5. Deploy to a Personal Injury org

### Windows PowerShell (recommended for the established PI org)

The repository's staged script is designed to preserve the existing `Matter__c` object definition:

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg pi-uat
```

Read the script before execution and verify the stages against the target org. It may add solution-required Matter fields and the supporting Treatment Visit, Records Request and Medical Provider model where expected. If those objects already exist with a different schema, do not blindly run the prerequisite stages; map the schema and use the appropriate skip/adapted deployment path.

- Use `-SkipPrerequisites` only when the required objects and fields are already present and compatible.
- Use `-DeployFullPrerequisites` only for a disposable scratch/developer org that genuinely needs the sample data model. **Never use this flag against the established PI org.**

### Staged CLI deployment (when reviewing each step manually)

Follow `docs/deployment.md` for the repository's exact package order. Validate in a sandbox first; run tests and review deployment results before production.

## 6. Configure permissions

After the relevant metadata has been deployed:

1. Assign `Follow_Up_Automation` to a dedicated automation user.
2. Assign `Follow_Up_Case_Manager` to case managers.
3. Assign `Follow_Up_Supervisor` to supervising attorneys.
4. Assign `Automatic_Intake_Reviewer` only to designated users who are allowed to access staged intake records and attachments.
5. Verify record access, object permissions, field-level security, and sharing using a non-admin test user. Do not rely on System Administrator access as the only test.
6. Add the Follow-up Work Queue and (when deployed) Automatic Intake review UI to the intended Lightning app navigation.

Keep sensitive medical documents and email bodies restricted to authorized users. Avoid logging full source bodies or document contents.

## 7. Configure follow-up rules and firm settings

Navigate to **Setup → Custom Metadata Types** and inspect:

- **Follow-up Rule** (`Follow_Up_Rule__mdt`): treatment-gap thresholds, records follow-up cadence, escalation count, priority, channel and auto-task behavior.
- **Follow-up Setting** (`Follow_Up_Setting__mdt`): open matter statuses, practice-area filters, outstanding request statuses, excluded treatment statuses, firm name, verified org-wide email address, AI enablement and pluggable class names.
- **Response Classification Rule** (`Response_Classification_Rule__mdt`): inbound-response keyword/category/next-action mapping.
- **Automatic Intake Extraction Setting** (`Automatic_Intake_Extraction_Setting__mdt`): extractor class and activation. The shipped default is inactive; do not activate it until a real supported extractor is implemented and tested.

Configuration checklist:

- Match all configured status/type values to the actual org picklists exactly.
- Verify the firm's practice-area value and which matter statuses count as open.
- Set thresholds/cadences with the process owner; avoid activating monthly status updates if an existing process already sends them.
- Verify the org-wide email address and Salesforce email deliverability.
- Keep AI disabled until security/compliance sign-off and successful sandbox testing.
- Never store secrets or personal health information in Custom Metadata.

## 8. Schedule the nightly evaluator

Run the scheduler setup as the dedicated automation user after deployment and permission assignment:

```bash
sf apex run --file scripts/apex/schedule-nightly.apex --target-org pi-uat
```

The repository also documents this Apex alternative:

```apex
FollowUpNightlyScheduler.schedule(null);
```

Confirm the resulting job in **Setup → Scheduled Jobs** and monitor **Apex Jobs** after the first run. Do not schedule duplicates; check for an existing job first.

### Optional approved-message scheduler

Only enable after the approval workflow, sender configuration and audit trail have been tested:

```apex
FollowUpApprovedSendScheduler.schedule(null);
```

This scheduler is optional and must only send due recommendations already approved through the application's server-side approval flow. Verify that an approval stamp is required for every external send. Never use a scheduler to bypass approval.

## 9. Configure Agentforce (manual Salesforce Setup)

The Agentforce Builder configuration is not fully source-controlled in this repository; create and validate it in the target org, then retrieve the actual metadata when supported.

1. Confirm Agentforce and the required Einstein/Prompt Builder capability are enabled/licensed in the org.
2. Create an **Employee** agent named **Treatment & Records Follow-up Agent** with API name `Treatment_Records_Follow_up_Agent`.
3. Follow `docs/agentforce.md` for the complete agent instructions, topic descriptions, action mapping and prompt-template text.
4. Configure the three topics:
   - **Matter Follow-up Review**
   - **Follow-up Drafting**
   - **Inbound Response Handling**
5. Expose only the relevant deployed Apex actions. Do not expose an action that approves or sends a message.
6. Ground answers in the repository's verified Salesforce actions. Instruct the agent to say when a field is not recorded, avoid displaying raw record IDs, and refuse legal advice, case-merit/settlement discussion and medical advice.
7. Test as a case manager and a supervisor with different record access. Confirm that inaccessible matters are not disclosed.
8. Activate only after action tests and safety checks pass. Record the active version and retrieve supported metadata into source control.

Do not activate the Einstein draft generator/classifier in `Follow_Up_Setting.Default` until the required Apex classes, prompt templates and org capabilities are available. Template/keyword fallback should remain usable when AI is off.

## 10. Configure automatic inbound email and document intake

**Current status: capture code exists; end-to-end extraction is not configured.** This section is a setup gate, not a claim that email intake already works in your org.

### 10.1 Create the Salesforce Email Service

In **Setup → Email Services**:

1. Create an Email Service using Apex class `AutomaticIntakeEmailService`.
2. Configure an Email Service Address and restrict allowed sender addresses/domains according to the firm's approved inbound-mail policy.
3. Confirm whether the address is reachable from the intended provider/client mailboxes and test inbound delivery in sandbox.
4. Verify attachment-size limits, supported file types, retention and access permissions before sending real documents.
5. Send a synthetic test email with a harmless attachment and confirm that one `Automatic_Intake__c` record is created and the file is linked to it.
6. Re-send the same message (with the same message ID) and verify idempotency; inspect Apex Jobs and intake status.

Do not expose the inbound service address publicly without sender restrictions and an operational abuse/retention plan. The service captures source email/attachments; it must not create clinical/business records based only on keyword classification.

### 10.2 Implement and configure a real extractor before enabling processing

The repository defines `IAutomaticIntakeExtractor` as an extension point. A concrete class must be implemented using a document-extraction API that is actually licensed and supported in the target org. Do not assume a generic Agentforce prompt can parse arbitrary PDF/image attachments reliably without a configured supported file-input/extraction path.

The adapter should return typed candidate data and confidence/evidence for each critical field, support the approved document classes, and never fill missing values by guessing. Validate at least:

- treatment/appointment date and provider
- records request/receipt/bill type and relevant dates
- provider identity and verified contact details
- Matter match evidence
- duplicate/conflict evidence and source reference

Before enabling the matching Custom Metadata record, verify that the adapter class exists, implements the interface, is bulk/limit safe, has tests, and has been validated against representative redacted documents. Confirm the target objects' required fields and picklist values.

### 10.3 Automatic application gates

Automatic record application should occur only if all configured gates pass:

- confidence meets the threshold (the current implementation uses a minimum overall threshold of 0.90);
- Matter and provider matches are unambiguous and supported by verified identifiers/relationships;
- required fields and picklist values are valid;
- no duplicate or conflicting clinical/billing facts exist;
- the source can be traced back to the intake record/file;
- DML and subsequent evaluation are successful and auditable.

Uncertain records must not be guessed. The current review LWC is a queue/list view; full case-manager edit/apply/reject workflow is still a required implementation item. Until that workflow and the extractor are complete and tested, keep extraction inactive and do not represent the intake as end-to-end autonomous.

## 11. Optional external channels

- **Email:** use Salesforce native email delivery, verified org-wide address and deliverability.
- **SMS / e-fax / telephony:** the repository uses a channel abstraction. An actual provider adapter, a Named Credential/External Credential, authentication, sender identity, compliance review and error handling are required. Never commit credentials. Until configured, use the solution's Task fallback.
- Test opt-out handling, wrong recipient, provider errors, retry/idempotency, delivery failure, and audit logging before enabling an external channel.

## 12. Validate the deployment

Run in sandbox:

```bash
sf apex run test --target-org pi-uat --test-level RunLocalTests --code-coverage --result-format human --wait 30
```

Run the repository CI checks as defined in `.github/workflows/ci.yml`. For org-backed CI deployment validation, configure the protected `SF_AUTH_URL` GitHub Actions secret using the team's approved credential process; never print it in logs or commit it.

Minimum UAT scenarios:

- open matter with a treatment gap creates the expected recommendation;
- outstanding records request increments follow-up/escalation correctly;
- repeat evaluation does not create duplicate open recommendations;
- stale matter flag is set and cleared correctly;
- drafts cannot be sent without server-side approval;
- an edited approved draft returns to review;
- inbound replies are classified and logged without inventing facts;
- a duplicate inbound email does not create duplicate intake/business records;
- low-confidence/ambiguous extraction does not create business records;
- permissions prevent unauthorized users from seeing matter or intake details;
- AI-off mode works without live LLM calls;
- no legal/medical advice or case value/settlement content is generated.

## 13. Operational monitoring and rollback

- Monitor **Setup → Apex Jobs**, **Scheduled Jobs**, failed Flow interviews (if relevant), email delivery and intake statuses.
- Review failed/Needs Review intake items and the reason/status, not raw medical text in logs.
- Track gap days, records request-to-receipt days, inbound status calls per month and sign-up-to-demand days as defined by the business.
- If an automation misbehaves, disable the related scheduler or Custom Metadata feature flag first, preserve the audit trail, and investigate in sandbox. Do not delete intake sources or recommendations as a rollback shortcut.
- For rollback, use the approved Salesforce deployment/release procedure and assess dependent metadata before destructive changes.

## 14. Configuration sign-off

Before production activation, record the owner/date for each item:

- [ ] Org schema discovery and mapping approved
- [ ] Sandbox deployment and Apex/CI checks pass
- [ ] Permission and sharing tests pass for case manager/supervisor/reviewer
- [ ] Follow-up thresholds and picklists approved by process owner
- [ ] Org-wide email and deliverability verified
- [ ] Nightly evaluator scheduled once; no duplicate jobs
- [ ] Approved-send workflow and approval stamp tested
- [ ] Agentforce topics/actions/prompts tested and activated
- [ ] Inbound Email Service tested with sender restrictions
- [ ] Real extractor implemented, tested and explicitly enabled
- [ ] Intake apply/edit/reject path and audit trail completed
- [ ] AI/privacy/compliance and retention sign-off recorded
- [ ] External channels disabled or fully credentialed/tested
- [ ] Rollback owner and monitoring process assigned
