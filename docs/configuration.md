# Configuration Guide: Treatment & Records Follow-up Agent

Audience: Salesforce administrators configuring the solution after deployment.
Related: [deployment](deployment.md) (how to deploy), [business rules](business-rules.md) (what the rules do), [Agentforce](agentforce.md) (agent setup detail), [security](security.md).

> **Before you start:** confirm the data contract in [org-discovery.md](org-discovery.md) section 4. The solution expects `Matter__c`, `Treatment_Event__c`, `Records_Request__c` and `Medical_Provider__c` with the fields listed there. Most of the steps below are configuration-only; **no code changes are needed** unless those names differ.

## Configuration checklist

| # | Step | Where | Required? |
|---|---|---|---|
| 1 | Global settings (`Follow_Up_Setting.Default`) | Custom Metadata | **Yes** |
| 2 | Rule thresholds (`Follow_Up_Rule`) | Custom Metadata | Review defaults |
| 3 | Response classification rules | Custom Metadata | Review defaults |
| 4 | Org-wide email address | Setup → Organization-Wide Addresses | **Yes** (for email) |
| 5 | Automation user + nightly schedule | User, permission set, Anonymous Apex | **Yes** |
| 6 | Case manager / supervisor access | Permission sets | **Yes** |
| 7 | Work queue in the app and on the Matter page | App Manager, Lightning App Builder | **Yes** |
| 8 | Page layout assignment | Object Manager | Recommended |
| 9 | Report and dashboard folder sharing | Reports / Dashboards | Recommended |
| 10 | SMS / e-fax / telephony adapters | Named Credentials + Custom Metadata | Optional |
| 11 | AI drafting and classification (Prompt Builder) | Prompt Builder + Custom Metadata | Optional |
| 12 | Agentforce agent | Agentforce Builder | Optional |
| 13 | Verify | Sample data / smoke test | **Yes** |

---

## 1. Global settings: `Follow_Up_Setting.Default`

**Setup → Custom Metadata Types → Follow-up Setting → Manage Records → Default → Edit**

The solution reads only the record named **Default**. If it is missing, no matter is evaluated. The engine never guesses which matters are open.

| Field | Default | What it controls | Set it to |
|---|---|---|---|
| Open Matter Statuses | `Intake,Open,Treating,Pre-Demand` | `Matter__c.Status__c` values evaluated nightly (comma-separated, exact API values) | Your org's "open, pre-demand" statuses. Exclude settled, closed and litigation statuses if they are handled differently. |
| Practice Area Filter | `Personal Injury` | `Matter__c.Practice_Area__c` value to evaluate. Blank = all practice areas. | Your PI picklist value. |
| Outstanding Request Statuses | `Requested,Partially Received` | `Records_Request__c.Status__c` values that mean "still waiting" | Match the 3.2 Records Request picklist. |
| Bill Request Types | `Bills,Records and Bills` | `Records_Request__c.Request_Type__c` values that cover bills (used by the Missing Bills rule) | Match your picklist. |
| Excluded Treatment Statuses | `Cancelled,No Show` | `Treatment_Event__c.Status__c` values that do **not** count as treatment | Add any "rescheduled" or "void" values. |
| Restricted Draft Terms | settlement, liability, diagnosis, … | Whole-word terms that cause an AI draft to be discarded (the template draft is kept) | Add firm-specific terms (e.g. insurer names, "lawsuit value"). |
| Classification Confidence Threshold | `0.7` | Below this (0–1), a reply always goes to case-manager review | 0.7–0.85. Higher means more human review. |
| Batch Size | `100` | Matters per batch scope | Lower (50) if the org has heavy automation on Tasks or Matters. |
| Max AI Drafts Per Run | `200` | Cap on AI draft generations per nightly run (cost and exposure control) | Leave as is until AI is enabled. |
| AI Draft Generator Class | *(blank)* | Blank = template drafts only | `FollowUpEinsteinDraftGenerator` after step 11 |
| AI Response Classifier Class | *(blank)* | Blank = keyword classification only | `FollowUpEinsteinClassifier` after step 11 |
| SMS Channel Class | *(blank)* | Blank = SMS creates a manual delivery Task | Your adapter class (step 10) |
| Fax Channel Class | *(blank)* | Blank = fax creates a manual delivery Task | Your adapter class (step 10) |
| Firm Name | *(blank)* | Name used in drafts and grounding. Blank = the Salesforce organization name. | The firm's client-facing name. |
| Org-Wide Email Address | *(blank)* | Sender address for follow-up emails. Blank = the sending user's own address. | The verified address from step 4 (e.g. `records@firm.com`). |

> Picklist values in these fields must be **API values**, not labels. Check them in Object Manager → field → Values.

## 2. Rule thresholds: `Follow_Up_Rule`

**Setup → Custom Metadata Types → Follow-up Rule → Manage Records**

A rule runs only when **Active** is checked **and** **Threshold Days** is set.

| Field | Meaning |
|---|---|
| Active | Turns the rule on or off |
| Threshold Days | Primary trigger in days (meaning per rule, below) |
| Repeat After Days | Minimum days before the same follow-up is raised again after it was sent, rejected or completed |
| Escalate After Count | Unanswered follow-ups before escalating to the case manager |
| High Priority Days | At or above this many days the item is High priority |
| Records Activity Days / Client Contact Days | Stalled Matter rule only |
| Default Priority | Priority when not High |
| Preferred Channel | Tried first; falls back automatically when the recipient has no address for it |
| Auto-Create Task | Internal items only: create and assign a Task to the case manager immediately |

Default values and recommended tuning:

| Rule | Trigger (defaults) | Repeat | Channel | Auto-Task | Tuning advice |
|---|---|---|---|---|---|
| **Treatment_Gap** (client check-in) | 21 days since last treatment; escalate after 2 unanswered; High ≥ 45 days | 7 | SMS | No | Many PI firms use 14–30 days. Shorter thresholds create more check-ins. |
| **Records_Follow_Up** (provider) | 14 days after request; High ≥ 45 days | 10 | Email | No | Align with the firm's records-request SLA letter. |
| **Provider_Escalation** | 2 follow-ups sent and 7 days since the last one | 14 | Task | **Yes** | This is the "provider misses a second follow-up" rule from the brief. |
| **Missing_Bills** | 30 days after treatment, no bills request | 30 | Task | No | Deactivate if 3.2 already requests bills automatically. |
| **Stalled_Matter** | 45 days since treatment, records 30, client contact 30 | 14 | Task | **Yes** | Drives `Matter__c.Stalled__c` and the supervisor dashboard. |
| **Client_Status_Update** (monthly) | 30 days after sign-up | 30 | Email | No | **Deactivate** if the firm already sends monthly updates. |

**Go-live recommendation:** run for 2–4 weeks with every rule active. Case managers may reject freely, and the Rejection Reason field tells you which thresholds need tuning.

## 3. Response classification rules: `Response_Classification_Rule`

**Setup → Custom Metadata Types → Response Classification Rule → Manage Records**

These rules map each reply category to a next action. Keywords are used only by the fallback keyword classifier. Do not rename **Category**, because Apex validates against these values.

| Field | Meaning |
|---|---|
| Keywords | Comma-separated phrases, case-insensitive, whole-phrase match |
| Match Type | `Contains`, or `Exact Message` (e.g. "STOP") |
| Audience | `Client`, `Provider` or `Any` |
| Sort Order | Lower values are checked first (put specific rules before general ones) |
| Next Action | `Complete`, `Complete and Re-check Later` or `Case Manager Review` |
| Re-check Days | Pauses the same follow-up for this many days (confident classifications only) |

Defaults: Opt-Out (exact "stop" / "unsubscribe" → review, pause 90 days); Provider Action Required (review, 14); Records Sent (complete, re-check 7); Treatment Stopped (review, pause 14); Callback Requested (review); Status Question (review); Treatment Continuing (complete, pause 14); Unclear (review).

Add firm-specific phrasing to **Keywords** (e.g. local provider jargon, Spanish phrases if you serve Spanish-speaking clients).

## 4. Org-wide email address

1. **Setup → Organization-Wide Addresses → Add**, e.g. `Records Department <records@firm.com>`. Allow all profiles, or the case-manager profiles. Complete verification.
2. Enter the address in `Follow_Up_Setting.Default` → **Org-Wide Email Address**.
3. **Setup → Deliverability → Access level = All email** (production).
4. Optional: add the address to the firm's SPF/DKIM (**Setup → DKIM Keys**) so provider mail servers don't reject the messages.

## 5. Automation user and nightly schedule

1. Create (or reuse) an integration user, e.g. `followup.automation@firm.com`, with a Salesforce licence.
2. Assign permission set **Follow-up: Automation User** (`Follow_Up_Automation`). It grants View All on Matters, Treatment Events, Records Requests, Medical Providers and Contacts, and full access to Follow-up Recommendations.
3. Log in as that user (or authorise the CLI as that user) and run:
   ```bash
   sf apex run --file scripts/apex/schedule-nightly.apex --target-org <org>
   ```
   This schedules **"Treatment & Records Follow-up - Nightly Evaluation"** daily at 02:00 org time. For a different time, run `FollowUpNightlyScheduler.schedule('0 30 1 * * ?');`.
4. Verify in **Setup → Scheduled Jobs**. After the first run, check **Setup → Apex Jobs** for `FollowUpEvaluationBatch`.

> Schedule the job as the automation user, **not** as a named employee. Scheduled Apex runs as the user who scheduled it, and it stops if that user is deactivated.

## 6. User access

| Persona | Permission set | Grants |
|---|---|---|
| Case manager | **Follow-up: Case Manager** (`Follow_Up_Case_Manager`) | Work queue, approve, bulk-approve templates, send, override, agent actions |
| Supervising attorney | **Follow-up: Supervising Attorney** (`Follow_Up_Supervisor`) | Read recommendations and stalled flags, dashboards, override. **No approve or send.** |
| Nightly job | **Follow-up: Automation User** | See step 5 |

```bash
sf org assign permset --name Follow_Up_Case_Manager --on-behalf-of casemanager@firm.com --target-org <org>
```

Notes:
- Users only see recommendations for **matters they can already see** (Master-Detail sharing). No extra sharing rules are needed.
- To restrict a capability, remove the custom permission from a cloned permission set: *Approve / Send / Bulk Approve / Override Follow-up …*.
- Contacts: case managers also need Read on Contact (standard profiles have it), so client names and addresses resolve.

## 7. Work queue placement

- **Tab.** The *Follow-up Work Queue* tab is already visible through the permission sets. Add it to the firm's app: **App Manager → [app] → Edit → Navigation Items → Follow-up Work Queue**.
- **Matter record page.** **Lightning App Builder → Matter record page → drag "Follow-up Work Queue"**. On the record page it filters to that matter and shows **Evaluate this matter**.
- **Home page (optional).** Add the component to the case-manager Home page, with "Assigned to me" as the working view.
- The *Follow-up Recommendations* object tab and its list views (Open Follow-ups, High Priority – Open, Sent – Awaiting Response, Escalations & Stalled Matters) are available for ad-hoc use.

## 8. Page layout

**Object Manager → Follow-up Recommendation → Page Layouts → Page Layout Assignment:** assign **Follow-up Recommendation Layout** to all relevant profiles. All fields are read-only by design, because changes go through the work queue so approval rules are enforced. Field History Tracking is enabled for Status, Priority, Approved By, Approved Date and Sent Date.

## 9. Reports and dashboard

1. **Reports → Folders → Follow-up Reports → Share**: View for case managers and supervisors (public groups or roles).
2. **Dashboards → Follow-up Dashboards → Share**: the same audience.
3. The *Follow-up Operations* dashboard is **dynamic** (runs as the logged-in user), so each person sees only their matters. Your edition may limit the number of dynamic dashboards.
4. Pin the dashboard on the supervising attorneys' Home page.

## 10. SMS, e-fax and telephony (optional)

Out of the box, SMS and fax sends create a **manual delivery Task**. It holds the approved text and the recipient's number, is assigned to the case manager, and completes the recommendation when the Task is closed.

To integrate a provider (Salesforce Messaging, Twilio, an e-fax service):

1. **Setup → External Credentials → New** (authentication for the vendor), then **Named Credentials → New** (vendor URL, linked to the External Credential). Grant the External Credential principal to the case-manager permission set.
2. A developer implements `IFollowUpChannel` (one method, `deliver(List<Follow_Up_Recommendation__c>)`). It calls out via `callout:<NamedCredential>`, performs no DML, and returns one `FollowUpDeliveryResult` per record.
3. Set **SMS Channel Class** or **Fax Channel Class** in `Follow_Up_Setting.Default` to the class name.
4. Carrier opt-out (STOP) must also be enforced by the SMS platform. The solution only classifies "STOP" replies and routes them to a person.

Never place credentials in code or in custom metadata.

## 11. AI drafting and classification (optional)

Prerequisites: Einstein generative AI enabled, Einstein Trust Layer settings reviewed (data masking for health information), compliance sign-off ([security.md](security.md) section 6), and the `agentforce/` directory deployed.

1. **Prompt Builder → New Prompt Template → Flex**, four times, using the API names below. For each: add input `recommendation` (Object → Follow-up Recommendation), insert the **Apex → FollowUpPromptFacts** resource, paste the body from `docs/prompt-templates/`, then **Save & Activate**.

   | API name | Body |
   |---|---|
   | `Follow_Up_Client_Draft` | `Follow_Up_Client_Draft.txt` |
   | `Follow_Up_Provider_Draft` | `Follow_Up_Provider_Draft.txt` |
   | `Follow_Up_Stalled_Matter_Summary` | `Follow_Up_Stalled_Matter_Summary.txt` |
   | `Follow_Up_Inbound_Classification` | `Follow_Up_Inbound_Classification.txt` |

2. Preview each template against a sample recommendation and confirm the output is JSON only.
3. In `Follow_Up_Setting.Default` set **AI Draft Generator Class** = `FollowUpEinsteinDraftGenerator`, **AI Response Classifier Class** = `FollowUpEinsteinClassifier`, and a suitable **Max AI Drafts Per Run**.
4. **Kill switch:** clear those two fields and the solution immediately returns to template drafts and keyword classification.

AI drafts are always marked *Draft Source = AI*, cannot be bulk-approved, and are discarded automatically if they contain a restricted term.

## 12. Agentforce agent (optional)

Follow [agentforce.md](agentforce.md) sections 2–7. In summary:
1. **Setup → Agentforce Agents → New → Employee agent**: *Treatment & Records Follow-up Agent*.
2. Paste the agent instructions (section 2).
3. Create three topics (*Matter Follow-up Review*, *Follow-up Drafting*, *Inbound Response Handling*) with the instructions given.
4. Create six agent actions from the Apex invocables (category *Treatment & Records Follow-up*).
5. Grant access to the case-manager and supervisor permission sets, test with the scenarios in section 8, then activate.
6. Retrieve the configuration into source control (section 7).

## 13. Verification

**In a sandbox:**
```bash
sf apex run --file scripts/apex/create-sample-data.apex --target-org <sandbox>   # synthetic data, never production
sf apex run test --target-org <sandbox> --test-level RunLocalTests --code-coverage --result-format human --wait 30
```
Then walk through the UAT script in [testing.md](testing.md) section 5.

**Smoke test in production:**
1. Pick one real open PI matter with a known gap. On its record page, click **Evaluate this matter**.
2. Confirm the recommendation's facts (dates, day counts, provider) match the matter.
3. Try **Send** before approving: it must be blocked.
4. Approve and send a check-in to a test contact. Confirm the completed Task *"Follow-up sent: …"* on the matter.
5. The next morning, confirm the nightly job ran (**Apex Jobs**) and that no duplicates were created.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Nightly run creates nothing | `Default` settings missing, or status/practice-area values don't match | Step 1; use exact API values |
| Rule never fires | Rule inactive or Threshold Days blank | Step 2 |
| "You do not have permission to approve…" | Missing custom permission | Step 6 |
| "…do not have edit access…" | User can't edit the parent Matter (sharing) | Share the matter or reassign |
| Email send fails | Deliverability off, unverified org-wide address, or client opted out of email | Step 4; check the Delivery Note field |
| Stalled flag never clears | No completed Tasks with the client Contact | Log calls against the client Contact, or log the reply in the work queue |
| AI draft shows "withheld" rationale | Output contained a restricted term | Expected; review the template draft or tune the restricted terms |
| Many "Unclear" classifications | Keywords don't match the firm's phrasing | Add keywords (step 3) or enable AI classification (step 11) |
| Duplicate follow-ups | Another automation (3.2, legacy Flow) also chases providers | Deactivate the overlapping rule or automation |
