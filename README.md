# Treatment & Records Follow-up Agent

Salesforce + Agentforce solution for a **Personal Injury law firm**. It finds, every night, the open matters that are quietly stalling (treatment gaps, unanswered medical-records requests, missing bills, stale client contact). It prepares the right follow-up for a case manager to approve, then logs every touch and response.

> **The agent is an internal case-management assistant, not a lawyer.** It never gives legal or medical advice, never discusses case value or settlement, and **never sends anything without human approval**. The server enforces that approval; the UI alone does not.

## Business problem and value

Between sign-up and demand, PI matters stall silently. Clients stop treating, providers ignore records requests, bills go missing, and case managers only notice at the monthly file review. Treatment gaps weaken claims, and records delays push out the demand date.

| Before | After |
|---|---|
| Spreadsheets / list views, checked "when time allows" | Nightly deterministic evaluation of every open PI matter |
| Follow-up counts kept in people's heads | Follow-up history, counts and escalation computed automatically |
| Inconsistent wording | Firm-approved templates, optionally refined by AI, always approved by a person |
| Stalled matters found at monthly review | `Stalled` flag and assigned Task the day the signals line up; supervisor dashboard |
| "Where is my case?" calls | Proactive monthly plain-language status updates (bulk-approvable) |

KPIs: average treatment-gap days, records request-to-receipt days, provider escalations, stalled matters, pending approvals, follow-up response rate, inbound status calls, sign-up-to-demand days. See [business analysis](docs/business-analysis.md).

## Architecture at a glance

```
Nightly Scheduled Apex → Batch (open PI matters only)
  → Selector (7 bulk queries/scope) → Deterministic Rule Engine (Custom Metadata thresholds)
  → Follow_Up_Recommendation__c (dedupe + unique active key) → auto-Tasks for escalations, Stalled flag
  → [optional] capped AI drafting via Prompt Builder (grounded, guarded)
  → Case Manager Work Queue (LWC): approve / edit / reject / override / send / log response
  → Send service (email native; SMS/fax/phone via Task or pluggable Named-Credential adapters)
  → Inbound reply → classification (person / agent / keywords / async AI) → deterministic next action
Agentforce employee agent: 3 topics, 6 actions (read, evaluate, draft, log reply, escalate); no send capability
```

**AI never decides whether to follow up. Rules do.** AI only words drafts, explains the recommendation, and understands replies. Details are in [architecture & decisions](docs/architecture.md).

| Layer | Technology | Why |
|---|---|---|
| Eligibility rules | Apex (pure engine) + Custom Metadata | Factual, testable, bulk-safe, configurable without code |
| Nightly processing | Scheduled Apex → Batch Apex | Cross-object aggregates and dedupe exceed what a Scheduled Flow handles safely at volume |
| Simple record automation | 2 record-triggered Flows | Unique active-key maintenance (before-save); close a recommendation when its Task completes |
| Approval / send | Apex services + custom permissions + validation rules | Server-side human-in-the-loop that the UI cannot bypass |
| Work queue | LWC `treatmentRecordsFollowUpConsole` (Tab, App page, Matter page) | Facts, rationale, editable draft and actions on one screen |
| Reasoning / drafting / classification | Agentforce + Prompt Builder (flex templates grounded by Apex) | Natural-language tasks only, over verified facts |

## Repository layout

| Path | Contents |
|---|---|
| `force-app/` | **Core**: object `Follow_Up_Recommendation__c`, 2 Matter fields, 3 CMDT types + records, 46 Apex classes (incl. 10 test classes), LWC, 2 Flows, 4 validation rules, layout, list views, tabs, 4 custom permissions, 3 permission sets, 41 Custom Labels |
| `analytics/` | 2 report types, 6 reports, *Follow-up Operations* dashboard |
| `agentforce/` | Prompt Builder grounding and Einstein adapters (Apex + tests); needs Einstein generative AI |
| `prerequisites/` | Minimal Matter / Treatment Event / Records Request / Medical Provider objects **for scratch/dev orgs only** |
| `docs/` | Analysis, discovery, architecture, Agentforce spec, rules, security, deployment, testing, prompt templates |
| `scripts/apex/` | Schedule the nightly job; create synthetic sample data (dev only) |
| `.github/workflows/ci.yml` | Lint, LWC tests, Apex parse, metadata conversion, PMD; org validation when `SF_AUTH_URL` is set |

## Data model

- **Reused (not modified):** `Matter__c`, `Treatment_Event__c`, `Records_Request__c` (from use case 3.2), `Medical_Provider__c`, `Contact`, `Task`.
- **New:** `Follow_Up_Recommendation__c`, Master-Detail to Matter so it inherits matter sharing. It holds type, status, priority, audience, channel, verified reason, gap/age/count metrics, draft and rationale, approval/send audit fields, response and classification, dedupe/active keys and run id.
- **Added to Matter:** `Stalled__c`, `Stalled_Since__c`.
- Follow-up counts per records request are **derived** from recommendation history. No fields are added to 3.2's objects.

The object and field names come from the specification. **They could not be verified against an org** (see [org discovery](docs/org-discovery.md)).

## Configuration

Step-by-step admin guide: **[docs/configuration.md](docs/configuration.md)**.

*Setup → Custom Metadata Types*:
- **Follow-up Rule**: `Treatment_Gap` (21 d), `Records_Follow_Up` (14 d, repeat 10), `Provider_Escalation` (after 2 follow-ups + 7 d), `Missing_Bills` (30 d), `Stalled_Matter` (45/30/30 d), `Client_Status_Update` (monthly).
- **Follow-up Setting (Default)**: open statuses, practice area, request statuses, bill types, excluded treatment statuses, restricted AI terms, confidence threshold, batch size, AI cap, pluggable class names (AI generator, AI classifier, SMS, fax), firm name, org-wide email.
- **Response Classification Rule**: category → keywords → next action → re-check days.

See [business rules](docs/business-rules.md).

## Security

Master-Detail sharing, `WITH USER_MODE` reads, `UserRecordAccess` edit checks, custom permissions for approve/bulk/send/override, read-only FLS on workflow fields (writes only through the service), and validation rules as a backstop. There is one narrow `without sharing` writer, for the stalled flag only. AI grounding sends minimum-necessary facts, no record Ids, and no date of birth (placeholder restored server-side), and an output guard applies. See [security](docs/security.md).

## Agentforce

Agent **Treatment & Records Follow-up Agent** (employee agent). Topics: *Matter Follow-up Review*, *Follow-up Drafting*, *Inbound Response Handling*. Actions: Get Matter Follow-up Status, Get Previous Follow-up History, Create Follow-up Recommendations, Generate Follow-up Draft, Classify Inbound Response, Escalate Matter to Case Manager. Prompt templates: client draft, provider draft, stalled-matter summary, inbound classification. Full instructions, guardrails and test utterances are in [Agentforce design](docs/agentforce.md).

## Deploy

```bash
npm ci
sf project deploy start --source-dir prerequisites --target-org <dev-org>   # dev/scratch only
sf project deploy start --source-dir force-app     --target-org <org>
sf project deploy start --source-dir analytics     --target-org <org>
sf project deploy start --source-dir agentforce    --target-org <org>       # Einstein-enabled orgs
```
Then assign permission sets, schedule the job as the automation user, and complete the manual Agentforce setup. See the [deployment guide](docs/deployment.md).

## Testing

`npm run lint && npm run test:unit` (LWC). Apex: `sf apex run test --test-level RunLocalTests --code-coverage`. See the [testing guide](docs/testing.md) for what each test class covers and what was, and was not, executed.

## Manual setup still required

1. Confirm the data contract against the real org (`docs/org-discovery.md` section 4).
2. Create the automation user, assign `Follow_Up_Automation`, and run `scripts/apex/schedule-nightly.apex`.
3. Assign `Follow_Up_Case_Manager` / `Follow_Up_Supervisor`. Share the report and dashboard folders.
4. Set the org-wide email address in `Follow_Up_Setting.Default`.
5. Agentforce: create the 4 prompt templates, the agent, 3 topics and 6 actions (`docs/agentforce.md`), then retrieve them into `agentforce/`.
6. Optional: SMS / e-fax adapters (`IFollowUpChannel` + Named Credentials).

## Known limitations

- **Not deployed or tested in an org.** No Salesforce org or credentials were available, so the Apex tests, Flows, validation rules, reports and dashboard have not been executed or deployed. Only offline checks ran (see `docs/testing.md`).
- Agentforce agent, topics, agent actions and prompt templates are manual configuration (with exact specs), not deployable metadata in this repository.
- SMS, e-fax and telephony are not integrated: they produce manual delivery Tasks until an `IFollowUpChannel` adapter is registered.
- Inbound replies must be logged from the work queue or the agent. Automatic ingestion of `EmailMessage` / `MessagingSession` is a documented extension point.
- Client-contact recency is based on completed Tasks linked to the client Contact.
- The report on records request-to-receipt turnaround belongs on the 3.2 `Records_Request__c` object and is not included.
