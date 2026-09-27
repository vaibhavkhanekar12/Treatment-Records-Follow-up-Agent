# Security & Privacy Design

Treatment information is sensitive health information. The design goal is least privilege, with every client- or provider-facing action enforced **server-side**.

## 1. Who can do what

| Capability | Case Manager (`Follow_Up_Case_Manager`) | Supervising Attorney (`Follow_Up_Supervisor`) | Automation user (`Follow_Up_Automation`) |
|---|---|---|---|
| See recommendations | Only for matters they can see (Master-Detail sharing) | Same | All (View All) |
| See treatment/records facts | Read on source objects (contract fields only) | Read | View All |
| Edit recommendation fields directly | **No**, all FLS read-only | **No** | Yes (system process) |
| Edit draft / reject / complete | ✅ via service (edit access to the matter required) | complete/reject via service | n/a |
| Approve client/provider messages | ✅ `Follow_Up_Approve_Communications` | ❌ | ❌ |
| Bulk-approve template drafts | ✅ `Follow_Up_Bulk_Approve` | ❌ | ❌ |
| Send | ✅ `Follow_Up_Send_Communications` | ❌ | ❌ |
| Override / snooze | ✅ `Follow_Up_Override_Recommendations` | ✅ | ❌ |
| Use Follow-up Agent actions | ✅ (6 actions) | read-only actions | ❌ |
| Run nightly evaluation | ❌ | ❌ | ✅ |

Permission set group: not created. There are only three personas and they don't overlap. If the firm already has persona PSGs (e.g. "Case Manager"), add these permission sets to them rather than assigning them directly.

## 2. Enforcement layers

1. **Sharing.** `Follow_Up_Recommendation__c` is Master-Detail to `Matter__c` ("Controlled by Parent"), so a user sees a recommendation only if they can see the matter. Reports and dashboards run as the logged-in user.
2. **CRUD/FLS.**
   - All user-facing reads use `WITH USER_MODE` / `AccessLevel.USER_MODE`: work queue, detail, agent actions, prompt grounding.
   - Agent and UI entry points call `FollowUpSecurity.requireSourceDataAccess()` and resolve matters with `readableMatters()` (`WITH USER_MODE`) before building facts.
3. **Record edit access.** Every mutating service call verifies `UserRecordAccess.HasEditAccess` for each record.
4. **Custom permissions.** Approve, bulk approve, send and override are checked in Apex (`FeatureManagement.checkPermission`). The LWC only mirrors them.
5. **Controlled writes.** Workflow and audit fields (`Status`, `Approved_By`, `Approved_Date`, `Draft_*`, `Sent_*`) are **read-only in FLS** for users. The service writes them in `SYSTEM_MODE` **after** checks 1–4. This is the only way to guarantee a user cannot forge an approval through the UI or API.
6. **Validation rules** (last line of defence, for any writer including admins and integrations):
   - `Approval_Required_Before_Send`: client/provider items cannot be `Sent` without an approval stamp.
   - `Sent_Only_From_Approved`: client/provider items can move to `Sent` only from `Approved` / `Send_Failed`.
   - `Rejection_Reason_Required`, `Override_Reason_Required`: audited decisions.
7. **Edit after approval** resets approval (service). Any draft change must be approved again.
8. **Recipients are resolved server-side** from the Contact / Medical Provider records at send time, never from UI input. Email opt-out (`HasOptedOutOfEmail`) is honoured.
9. **Field history** is tracked on status, priority, approval and sent fields.

## 3. `without sharing`: one narrow, justified use

`FollowUpEvaluationService.StalledFlagWriter` (private inner class) writes **only** `Matter__c.Stalled__c` and `Stalled_Since__c`. The evaluator can read every open matter (View All), but granting it Modify All on `Matter__c` would be much broader than updating two system-computed flags. Every other class is `with sharing`.

## 4. AI and Agentforce data exposure

| Control | Implementation |
|---|---|
| Minimum necessary data | `FollowUpFactsBuilder` sends dates, day counts, provider names, statuses, counts, the client's **first name** and the firm/sender name. No diagnosis, notes, codes, amounts, addresses, phone numbers or emails. |
| Date of birth | Provider drafts need it, but it is replaced by `[DATE OF BIRTH]` in grounding and restored server-side after generation. The LLM never receives it. |
| No record Ids | Grounding and agent outputs use matter names and FUR numbers only (asserted in tests). |
| User context | Agent actions and grounding run as the user (`WITH USER_MODE`). Prompts cannot include data the user cannot see. |
| Output guard | `FollowUpDraftGuard` discards AI drafts or rationale containing restricted terms (CMDT `Restricted_Terms__c`). |
| Human approval | Every AI draft is reviewed. AI drafts cannot be bulk-approved. |
| No autonomous send | The agent has no send or approve action. |
| Einstein Trust Layer | Required: zero data retention with the LLM provider, prompt/response masking, and audit trail in Data Cloud (if licensed). Review masking settings for PHI before enabling AI. |
| Kill switch | Clear `AI_Draft_Generator_Class__c` / `Response_Classifier_Class__c` in CMDT and the solution runs template-only. |

## 5. Integrations and credentials

- No credentials, tokens, endpoints or org Ids exist in code or metadata.
- SMS / e-fax / telephony adapters must implement `IFollowUpChannel` and call out through **Named Credentials + External Credentials** (per-user or named principal). They are registered by class name in CMDT.
- Email uses the org's verified **Org-Wide Email Address** (configured by address in CMDT).

## 6. Compliance boundaries

- The agent and drafts are **administrative only**: no legal advice, liability, case value, settlement, outcome prediction, strategy or medical interpretation (agent instructions, topic instructions, prompt rules and output guard).
- "STOP"/opt-out replies are classified and routed to a person. Carrier-level SMS opt-out must be enforced by the SMS platform adapter.
- The firm should confirm, with its compliance lead, whether its Salesforce environment is covered by a BAA for health information, and whether Einstein generative AI features are within that scope, **before** enabling AI drafting.

## 7. Static analysis (PMD / Salesforce Code Analyzer)

`sf code-analyzer run --rule-selector pmd:Recommended --rule-selector pmd:Security` result: **0 High-severity** findings. The system-context reads are suppressed with justification comments: the batch selector, `AsyncApexJob`, `UserRecordAccess`, `OrgWideEmailAddress`, and DOB restoration. Remaining Moderate/Low findings are complexity metrics, test-factory parameter lists and ApexDoc style. `ProtectSensitiveData` flags `Active_Key__c`/`Dedupe_Key__c`/`Keywords__c` only because their names contain "Key"; they are not secrets.
