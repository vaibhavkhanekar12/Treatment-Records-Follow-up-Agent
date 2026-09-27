# Business Rules (Deterministic Engine)

All thresholds live in **Custom Metadata**. Apex holds only rule identities (`FollowUpConstants`). Change values in *Setup → Custom Metadata Types → Follow-up Rule → Manage Records*, or deploy the CMDT records. No code change is needed.

A rule is evaluated only when `Active__c = true` **and** `Threshold_Days__c` is set. A rule with no threshold is skipped, never defaulted.

## 1. Scope: which matters are evaluated

`Follow_Up_Setting.Default`:

| Field | Default | Meaning |
|---|---|---|
| `Open_Matter_Statuses__c` | `Intake,Open,Treating,Pre-Demand` | Only matters in these statuses are evaluated nightly |
| `Practice_Area_Filter__c` | `Personal Injury` | Blank = all practice areas |
| `Outstanding_Request_Statuses__c` | `Requested,Partially Received` | Records requests still awaited |
| `Bill_Request_Types__c` | `Bills,Records and Bills` | Request types that cover bills |
| `Excluded_Treatment_Statuses__c` | `Cancelled,No Show` | Treatment events that do not count as treatment |

If the `Default` record is missing, no matter is evaluated. The engine does not guess which matters are open.

## 2. Derived facts (per matter)

| Fact | Definition |
|---|---|
| Last treatment | Max `Treatment_Date__c` ≤ today, excluding excluded statuses |
| Next scheduled treatment | Min `Treatment_Date__c` > today, excluding excluded statuses |
| Treatment anchor | Last treatment, else `Sign_Up_Date__c`, else matter created date |
| Gap days | Anchor → today |
| Follow-ups sent for a request | Recommendations with key `Provider_Follow_Up\|<request>` in status Sent/Completed with a sent date |
| Last records activity | Latest of any request date, received date, or provider follow-up sent date |
| Last client contact | Latest *completed* Task with the client (`WhoId`), excluding this solution's own outbound log entries (`Follow-up sent:` prefix). An unanswered outbound message is not "contact". |

## 3. Rules

| Rule (DeveloperName) | Condition | Result | Defaults |
|---|---|---|---|
| **Treatment_Gap** | gap ≥ `Threshold_Days` **and** no upcoming scheduled treatment | **Client Check-In** (client-facing, approval required). Channel: preferred (`SMS`), falling back to Email, then a Phone call script. | 21 days · repeat 7 · high ≥ 45 |
| ↳ escalation | unanswered check-ins since the anchor ≥ `Escalate_After_Count`, **or** no client linked | **Treatment Gap Review** (internal, High) | after 2 |
| **Records_Follow_Up** | outstanding request age ≥ `Threshold_Days` (first follow-up); then every `Repeat_After_Days` after the last sent follow-up | **Provider Records Follow-up** (provider-facing, approval required). Channel: Email → Fax → Phone. | 14 · repeat 10 · high ≥ 45 |
| **Provider_Escalation** | sent follow-ups ≥ `Escalate_After_Count` **and** last follow-up ≥ `Threshold_Days` ago **and** still outstanding | **Provider Escalation** (internal, High). **Task auto-assigned** to the case manager. Further provider follow-ups for that request stop. | 2 follow-ups · 7 days · repeat 14 |
| **Missing_Bills** | treatment at a provider older than `Threshold_Days` **and** no bills-type request for that provider | **Missing Bills** (internal) | 30 · repeat 30 |
| **Stalled_Matter** | gap ≥ `Threshold_Days` **and** records activity ≥ `Records_Activity_Days` **and** client contact ≥ `Client_Contact_Days` | Sets `Matter__c.Stalled__c` / `Stalled_Since__c`; **Stalled Matter Review** (internal, High, **Task auto-assigned**). The flag clears automatically when any signal resumes. | 45 / 30 / 30 · repeat 14 |
| **Client_Status_Update** | client has email or mobile **and** sign-up ≥ `Threshold_Days` ago | **Client Status Update** (template draft, **bulk-approvable**, Low) | 30 · repeat 30 |

Priority is `High` when the day count ≥ `High_Priority_Days__c`; otherwise `Default_Priority__c` applies.

## 4. Duplicate prevention and idempotency

Every follow-up subject has a stable **Dedupe Key**: `<Type>|<matter or request>[|<provider>]`.

1. **Open item exists** (Pending Review, Approved, Send Failed) → no new recommendation. The unique **Active Key** field, maintained by a before-save Flow, enforces this in the database for every writer, including concurrent runs.
2. **Sent, completed or rejected** within `Repeat_After_Days` → suppressed.
3. **Snoozed or re-check date** (`Next_Follow_Up_Date__c` in the future) → suppressed until that date.
4. **Superseded** items never suppress.
5. **Condition no longer holds** (e.g. treatment resumed) → open rule-generated items are set to **Superseded** automatically, so stale messages are never sent.

Running the evaluation twice in a row creates nothing new (covered by tests).

## 5. Missing-data handling

| Situation | Behaviour |
|---|---|
| No treatment, no sign-up date, no created date | Skipped with a run warning; nothing is inferred |
| No client linked | Internal Treatment Gap Review ("no client contact linked") |
| Client has no email/mobile | Check-in as a phone call script; monthly update skipped with a warning |
| Email opt-out on the client | Email channel is not used; delivery is refused |
| Provider has no email/fax | Phone (manual Task) |
| Records request without requested date | Skipped with a run warning |
| Owner is a queue and no case manager is set | Unassigned recommendation; Tasks go to the running user |

## 6. Inbound responses: category → next action

Configured in `Response_Classification_Rule__mdt`. Keywords apply only to the fallback classifier. The next action applies to every classifier.

| Category | Audience | Keyword examples | Next action |
|---|---|---|---|
| Opt_Out | Client | exact message: stop, unsubscribe | Case-manager review; pause 90 days |
| Provider_Action_Required | Provider | authorization, hipaa, fee, need another | Case-manager review; pause 14 days |
| Records_Sent | Provider | sent, faxed, mailed, uploaded | Complete + re-check in 7 days |
| Treatment_Stopped | Client | stopped, no longer, discharged | Case-manager review; pause check-ins 14 days |
| Callback_Requested | Any | call me, call back | Case-manager review |
| Status_Question | Client | status, where is my case | Case-manager review |
| Treatment_Continuing | Client | still going, next appointment | Complete + pause check-ins 14 days |
| Unclear | Any | (no match) | Case-manager review |

`Recheck_Days__c` pauses the same follow-up (sets `Next_Follow_Up_Date__c`) for any **confident** classification. Confidence below `Classification_Confidence_Threshold__c` (0.7) **always** routes to case-manager review and never pauses anything. A category supplied by a person counts as confidence 1.

## 7. Examples from the brief

| Reply | Category | Outcome |
|---|---|---|
| "I am still going to physical therapy." | Treatment_Continuing | Check-in completed; check-ins paused 14 days |
| "I stopped treatment last month." | Treatment_Stopped | Check-in completed; check-ins paused 14 days; **Inbound Response Review** (High) for the case manager |
| "We sent the records yesterday." | Records_Sent | Provider follow-up completed; re-check in 7 days |
| "We need another authorization." | Provider_Action_Required | **Inbound Response Review** for the case manager |
