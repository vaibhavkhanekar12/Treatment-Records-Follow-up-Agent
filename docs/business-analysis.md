# Business Analysis: Treatment & Records Follow-up Agent

Practice area: **Personal Injury**. Users: **case managers, supervising attorneys, intake/records staff.**

## 1. Problem statement

Between client sign-up and the demand package, PI matters **stall silently**:

- clients stop treating, and nobody notices until the monthly file review,
- providers ignore records and bills requests,
- bills are missing for treatment that is already documented,
- clients call to ask "where is my case?" because nobody proactively updates them.

Treatment gaps can reduce claim value and lengthen cycle time, because gaps are routinely raised by insurers. Records delays push out the demand date. The failure is one of **visibility and follow-through**. It is not a legal-judgement problem.

## 2. Current manual workflow

1. The case manager works a spreadsheet or a Salesforce list view of their open matters.
2. They periodically open each matter to check the last treatment date, outstanding records requests and the last client contact.
3. They call or email providers and clients "when they get to it".
4. They log notes by hand (often inconsistently: free-text notes, no structured follow-up count).
5. A supervising attorney reviews files monthly and finds stalled matters late.

## 3. Pain points

| # | Pain point | Consequence |
|---|---|---|
| P1 | No daily, systematic check of treatment recency | Gaps discovered weeks late |
| P2 | Records request age is not tracked against a cadence | Provider delays compound, demand slips |
| P3 | Follow-up count per request is not structured | No objective trigger for escalation |
| P4 | Client contact recency is invisible | Clients feel ignored, inbound "status" calls rise |
| P5 | Follow-up wording varies by staff member | Inconsistent tone, risk of inappropriate statements to clients |
| P6 | Stalled matters surface only at monthly review | Supervisors cannot intervene early |
| P7 | Manual logging | Weak audit trail of who contacted whom, when and what was said |

## 4. Operational risks today

- A treatment gap that goes unnoticed.
- A missing bill for documented treatment, which leaves specials under-stated in the demand.
- Inappropriate client communication (discussing case value or merits in a hurried message).
- Unauthorised disclosure of medical information in an email or SMS sent to the wrong recipient.
- Key-person dependency: follow-up knowledge lives in one case manager's head or spreadsheet.

## 5. Where each technique fits

| Need | Best fit | Why |
|---|---|---|
| "Is the last treatment older than N days?" | **Deterministic rules** (Apex + Custom Metadata) | Factual, auditable, cheap, no hallucination risk |
| "Is this records request past cadence, and how many follow-ups were sent?" | **Deterministic rules** | Countable facts |
| "Should this be escalated?" | **Deterministic rules** (count ≥ configured threshold) | Must be consistent and explainable |
| "Is this matter stalled?" | **Deterministic rules** (three stale signals) | Same |
| Duplicate prevention and cadence | **Deterministic** (dedupe key + unique active key) | Must be exact |
| Wording a client check-in or provider follow-up in the firm's tone | **AI (Prompt Builder)** | Natural-language generation over verified facts |
| Explaining *why* in plain language for the case manager | **AI** with template fallback | Summarisation |
| Classifying a free-text reply ("we need another authorisation") | **AI**, with a keyword fallback | Language understanding. The resulting **action** is still deterministic |
| Conversational "what needs attention on my matters?" | **Agentforce employee agent** | Reasoning across the action outputs |
| Approving and sending client/provider communication | **Human** | Mandatory. Legal, ethical and privacy exposure |
| Task creation, stalled flag, status transitions | **Deterministic automation** (Apex/Flow) | No judgement required |

**Design principle:** AI never decides *whether* to follow up. Rules decide that. AI only helps *word* and *explain* the follow-up and *understand* replies. Every client- or provider-facing message is approved by a person before it is sent, and the server enforces that approval. The UI alone does not.

## 6. Human approval: mandatory points

1. Any message to a **client** (check-in, monthly update).
2. Any message to a **provider** (records follow-up).
3. Any override of a recommendation (reason required and audited).
4. Any change to an approved draft **re-opens** approval (enforced by a before-save Flow).

Bulk approval is allowed **only** for template-sourced drafts (e.g. the monthly status update). AI-sourced drafts must be approved one at a time.

## 7. Security and privacy risks

| Risk | Mitigation |
|---|---|
| Treatment information is sensitive health information | Recommendation object is Master-Detail to Matter and **inherits matter sharing**. Access is only through permission sets. No clinical fields are read. |
| Prompt exposure of PHI to the LLM | Apex grounding sends only dates, provider name, counts and the client's first name. Salesforce IDs and clinical data are excluded. Einstein Trust Layer (zero data retention, masking) is required. |
| Message sent to the wrong recipient | Recipient is resolved server-side from the matter/provider record at send time, never from free text supplied by the UI. |
| Staff forging approvals | `Approved_By__c` and `Approved_Date__c` are read-only to users (FLS). Only the service writes them, after a custom-permission check. A validation rule blocks `Sent` without an approval stamp. |
| Agent sending messages autonomously | The agent has **no send action**. It can draft and create recommendations only. |

## 8. AI risks

| Risk | Mitigation |
|---|---|
| Hallucinated facts (wrong dates, invented appointments) | Grounding contains only verified fields. Missing values are rendered as "Not recorded". The prompt forbids inventing facts, and a human reviews every draft. |
| Legal/medical advice in drafts | Explicit prohibitions in agent, topic and prompt instructions. Case managers review. Drafts are operational and neutral in tone. |
| Mis-classification of a reply | The classifier returns a confidence score. Below the threshold, or for any "stopped/unclear/action required" category, the reply goes to case-manager review. |
| Over-use or cost | Only rule-flagged, client/provider-facing recommendations are drafted by AI, capped per run (`Max_AI_Drafts_Per_Run__c`). Template drafting always works without AI. |

## 9. Legal and compliance boundaries

The agent is an **internal case-management assistant**. It must never provide legal advice, determine liability, value a case, recommend or discuss settlement, predict outcomes, recommend legal strategy, or interpret diagnoses/give medical advice. Client messages are administrative only (appointments, paperwork, contact information, general status stage). SMS opt-out ("STOP") is classified and routed to a human. Channel-level opt-out enforcement belongs to the messaging platform.

## 10. Proposed process

1. **Nightly**: the scheduled batch evaluates every open PI matter against the configured rules.
2. Matters that meet a rule get a `Follow_Up_Recommendation__c` with deterministic facts (gap days, request age, follow-up count), a reason, a priority and a template draft. Duplicates are suppressed.
3. Escalations and stalled matters also create a **Task** for the case manager, and the matter's `Stalled__c` flag is set for supervisor dashboards.
4. A capped queueable asks Prompt Builder to refine client/provider drafts and write a rationale (only if AI is configured).
5. The case manager works the **Follow-up Work Queue** (LWC): review facts and rationale, then approve, edit, reject, override (snooze) or send.
6. Sending goes through the server-side send service (email natively; SMS/fax/phone via Task until an integration is registered). Every touch is logged as a Task.
7. Replies are logged (work-queue "Log Response" or the agent action), classified, and routed to the deterministic next action: complete, re-check later, or case-manager review.
8. The case manager can also ask the **Agentforce agent** "what needs attention on this matter?" or "draft the provider follow-up".

## 11. Business value

- Fewer and shorter treatment gaps, because gaps are detected on day N instead of at the monthly review.
- Faster records turnaround, through consistent cadence and objective escalation after the second missed follow-up.
- Fewer "where is my case" calls, through proactive plain-language monthly updates.
- Shorter time from sign-up to demand.
- Consistent, auditable, professional communication.

## 12. KPIs

| KPI | Source |
|---|---|
| Average treatment gap days per flagged matter | `Follow_Up_Recommendation__c.Gap_Days__c` (report *Treatment Gaps*) |
| Records request-to-receipt days | `Records_Request__c.Received_Date__c - Requested_Date__c` (3.2 object; report to be added in the org after discovery) |
| Provider escalations per month | Report *Provider Escalations* |
| Stalled matters (count, ageing) | `Matter__c.Stalled__c`, `Stalled_Since__c` |
| Pending approvals / time to approve | Report *Pending Approvals* (`CreatedDate` to `Approved_Date__c`) |
| Follow-up response rate | `Response_Received__c` over sent recommendations |
| Inbound client status calls per month | Tasks classified `Status_Question` (plus call logs) |
| Days from sign-up to demand | `Matter__c.Demand_Sent_Date__c - Sign_Up_Date__c` |

Capture a **baseline for 30 days before go-live** (rules active, drafting and sending disabled) so the improvement can be measured.
