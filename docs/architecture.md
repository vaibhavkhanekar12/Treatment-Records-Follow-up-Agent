# Architecture & Decision Record

## 1. End-to-end flow

```
                         SALESFORCE (system of record)
Matter__c ─┬─ Treatment_Event__c   (3.2)            Contact (client)   Task (activity log)
           ├─ Records_Request__c   (3.2) ── Medical_Provider__c
           └─ Follow_Up_Recommendation__c  (NEW, Master-Detail → inherits matter sharing)
                              │
  Nightly: FollowUpNightlyScheduler ─► FollowUpEvaluationBatch (open PI matters only)
                              │
                FollowUpMatterSelector   (bulk queries, no SOQL in loops)
                              │
                FollowUpRuleEngine       (pure deterministic logic, CMDT thresholds)
                  Treatment gap · Records follow-up · Provider escalation
                  Missing bills · Stalled matter · Monthly client update
                  + dedupe/cadence suppression + supersede stale open items
                              │
                FollowUpEvaluationService
                  insert recommendations (template drafts) · auto-Tasks for escalations
                  set/clear Matter__c.Stalled__c
                              │
       (optional, only if AI configured)  FollowUpAiDraftQueueable, capped per run
                              │   IFollowUpDraftGenerator → FollowUpEinsteinDraftGenerator
                              │   Prompt Builder templates, grounded by FollowUpPromptFacts
                              │   FollowUpDraftGuard rejects drafts with restricted topics
                              ▼
          Case Manager  ─── treatmentRecordsFollowUpConsole (LWC work queue)
            Approve · Edit · Reject · Override/Snooze · Send · Log response
                              │
          FollowUpRecommendationService  (custom-permission checks, record access checks)
          FollowUpSendService ─► IFollowUpChannel: Email (native) | Manual Task (SMS/Fax/Phone)
                              │     validation rule: no "Sent" without approval stamp
                              ▼
          Inbound reply ─► FollowUpResponseService
                             classify (agent/human category, keyword CMDT, or async AI)
                             ─► deterministic next action (CMDT): Complete · Re-check · Case-manager review

          Agentforce employee agent "Treatment & Records Follow-up Agent"
            Topics → Invocable actions (read status, history, evaluate, draft, log reply, escalate)
            No send or approve capability. Every action runs as the user (USER_MODE).
```

## 2. Decisions

### ADR-1: Deterministic rules first, AI second
**Decision.** Eligibility (gap, request age, follow-up count, stalled) is computed in Apex from verified fields and CMDT thresholds. AI is called only for recommendations that already exist and face a client or provider, and only up to a per-run cap.
**Why.** This is cheaper, explainable, testable and avoids hallucination. AI adds value only in wording, summarising and understanding free text.

### ADR-2: Scheduled Apex + Batch Apex (not a Scheduled Flow)
**Decision.** `FollowUpNightlyScheduler` launches `FollowUpEvaluationBatch` (configurable scope size).
**Why not a Scheduled Flow.** Each matter needs aggregates across four child/related objects (max treatment date per matter and per provider, outstanding requests, follow-up history per request, last client Task), plus dedupe, cadence suppression and superseding. In Flow that means nested loops and Get Records per matter, which hits limits at a few hundred matters and is hard to test. Batch Apex gives a fresh governor context per scope and bulk aggregate queries.
**Why not Queueable only.** Open PI matter volume can reach thousands, and Batch provides chunking and a restartable QueryLocator.

### ADR-3: New object `Follow_Up_Recommendation__c`, Master-Detail to `Matter__c`
**Decision.** Create one new object. Nothing equivalent exists in the specification or the repository.
**Why Master-Detail.** Recommendations contain treatment facts. Inheriting the matter's sharing ("Controlled by Parent") guarantees nobody sees a recommendation for a matter they cannot see. No extra sharing rules are needed.
**Why not Task alone.** Tasks cannot hold approval state, dedupe keys, rationale, classification and structured metrics for reporting, and approval enforcement on Task would affect all activities firm-wide.
**Not created.** No fields on `Records_Request__c` or `Treatment_Event__c`. Follow-up counts are derived from recommendation history. The only additions to `Matter__c` are `Stalled__c` and `Stalled_Since__c`, for supervisor dashboards.

### ADR-4: Custom Metadata for every business threshold
`Follow_Up_Rule__mdt` (one record per rule: thresholds, cadence, escalation count, priority, channel, auto-task), `Follow_Up_Setting__mdt` (open statuses, practice area, outstanding request statuses, bill types, excluded treatment statuses, restricted AI terms, pluggable class names, firm name, org-wide email), `Response_Classification_Rule__mdt` (keywords → category → next action). CMDT is deployable, versioned and packageable, and needs no code change to tune. Apex holds only rule *identities*, never numbers.

### ADR-5: Flow where the logic is simple
| Flow | Type | Why Flow |
|---|---|---|
| `Follow_Up_Recommendation_Before_Save` | Before-save record-triggered | Maintains `Active_Key__c` (the unique key of *open* recommendations) from status. It is a same-record field update, which Salesforce recommends doing in a before-save flow. It runs for every writer (Apex, UI, API, data loader), so the uniqueness guarantee cannot be bypassed. |
| `Follow_Up_Task_Completed` | After-save record-triggered on Task | When a Task created from a recommendation is completed, the recommendation is marked Completed. This is a single filtered update, so no Apex is needed. |

Flow is **not** used for the evaluation engine (ADR-2) or for send/approval, because those need custom-permission checks, multi-object validation and channel abstraction.

### ADR-6: Human approval enforced server-side, in three layers
1. **FLS.** Case managers have read-only FLS on status, approval stamps and drafts. All changes go through `FollowUpRecommendationService`.
2. **Service.** Custom permissions `Follow_Up_Approve_Communications`, `Follow_Up_Send_Communications`, `Follow_Up_Bulk_Approve`, `Follow_Up_Override_Recommendations` are checked. Record edit access is verified with `UserRecordAccess`. Editing an approved draft resets it to *Pending Review*. Bulk approval is limited to template drafts.
3. **Validation rules.** `Sent` requires the prior status `Approved`/`Send_Failed` and an approval stamp, for any external audience. This also stops admins, integrations and data loads.

The service performs its DML in `SYSTEM_MODE` **only after** these checks. This is deliberate: it is the only way to keep the audit fields non-editable by users while still letting the controlled workflow write them.

### ADR-7: Channel abstraction (`IFollowUpChannel`)
Email uses native `Messaging.SingleEmailMessage` (bulk `sendEmail` call, org-wide address from CMDT, logged as Task). SMS, Fax and Phone default to `FollowUpManualChannel`, which creates a Task containing the approved text for the case manager to deliver through their existing tool. To integrate Salesforce Messaging, Twilio or an e-fax service, implement `IFollowUpChannel` using a **Named Credential / External Credential** and set its class name in `Follow_Up_Setting__mdt` (`SMS_Channel_Class__c`, `Fax_Channel_Class__c`). No credentials exist in code, and no external integration was built because none was confirmed available (see `org-discovery.md`).

### ADR-8: Pluggable AI behind interfaces, in a separate package directory
`IFollowUpDraftGenerator` and `IFollowUpResponseClassifier` live in core. Their Einstein/Prompt-Builder implementations, the Prompt Template grounding class and the Agentforce topic/action metadata live in `agentforce/`. Core resolves them by class name from CMDT (`Type.forName`). This means:
- core deploys and runs in orgs **without** Einstein/Agentforce (template drafts, keyword classification),
- AI can be switched off instantly by clearing a CMDT field,
- unit tests use stubs and never depend on a live LLM.

### ADR-9: Agentforce: one internal employee agent, three topics, no send action
Topics are *Matter Follow-up Review*, *Follow-up Drafting* and *Inbound Response Handling*. The seven candidate topics in the brief were consolidated because they share the same actions and data. Separate topics per recommendation type would make topic classification harder and add nothing. See `agentforce.md`.

### ADR-10: Inbound classification: category from a person or agent where possible, AI asynchronous
- When the **agent** logs a reply, it has already understood the text and passes a category. The action validates it against the allowed set.
- When a **case manager** logs a reply, the LWC pre-fills a keyword suggestion and the human confirms it.
- Otherwise the configured classifier runs. The keyword classifier runs synchronously. The AI classifier runs in a Queueable, because LLM calls cannot follow uncommitted DML in the same transaction.
- **The next action is always deterministic** (CMDT), and below-threshold confidence always routes to human review.

### ADR-11: LWC work queue
Standard list views cannot show combined facts, rationale and editable drafts, or enforce approve/send sequencing with bulk actions. One LWC (`treatmentRecordsFollowUpConsole`) is exposed as a Tab, an App Page and a Matter record page component.

### ADR-12: Security model
`with sharing` everywhere. `WITH USER_MODE` for all user-facing reads. The batch runs as a dedicated automation user holding `Follow_Up_Automation`, which grants View All on the source objects and is still `with sharing`. One deliberately narrow exception: the private inner class `FollowUpEvaluationService.StalledFlagWriter` is `without sharing` and writes only `Matter__c.Stalled__c`/`Stalled_Since__c`, so the evaluator does not need Modify All on matters. Details are in `security.md`.

### ADR-13: Agentforce metadata is configured in the org, then retrieved
Prompt templates, topics, agent actions and the agent are specified exactly in `agentforce.md` and created in Prompt Builder / Agentforce Builder. No org was available to validate the version-specific `GenAi*`/`Bot` metadata shapes, so hand-writing them would be fabricated metadata. The retrieve command in `agentforce.md` brings the real metadata into source control afterwards. The Apex they depend on (actions, grounding, Einstein adapters) is in the repository.

### ADR-14: Separate package directories
`prerequisites/` (dev-only data contract), `force-app/` (core), `analytics/` (reports/dashboard) and `agentforce/` (Einstein-dependent Apex). Core deploys and runs in any org. Analytics and AI can be deployed, or rolled back, independently.

## 3. Component inventory

| Layer | Component |
|---|---|
| Data | `Follow_Up_Recommendation__c` (41 fields, 4 validation rules, 4 list views, layout, tab, field history), `Matter__c.Stalled__c`, `Matter__c.Stalled_Since__c` |
| Config | `Follow_Up_Rule__mdt` (6 records), `Follow_Up_Setting__mdt` (1), `Response_Classification_Rule__mdt` (8), 41 Custom Labels |
| Apex: engine | `FollowUpConstants`, `FollowUpConfig`, `FollowUpException`, `FollowUpMatterSelector`, `FollowUpMatterContext`, `FollowUpRuleEngine`, `FollowUpDraftBuilder`, `FollowUpEvaluationService`, `FollowUpEvaluationBatch`, `FollowUpNightlyScheduler` |
| Apex: workflow | `FollowUpRecommendationService`, `FollowUpSendService`, `IFollowUpChannel`, `FollowUpDeliveryResult`, `FollowUpEmailChannel`, `FollowUpManualChannel`, `FollowUpSecurity`, `FollowUpWorkQueueController` |
| Apex: AI seams | `IFollowUpDraftGenerator`, `FollowUpDraftResult`, `FollowUpDraftService`, `FollowUpDraftGuard`, `FollowUpAiDraftQueueable`, `IFollowUpResponseClassifier`, `FollowUpClassification`, `FollowUpKeywordClassifier`, `FollowUpResponseService`, `FollowUpAiClassificationQueueable`, `FollowUpFactsBuilder` |
| Apex: agent actions | `FollowUpAgentSupport`, `FollowUpGetMatterStatusAction`, `FollowUpGetHistoryAction`, `FollowUpEvaluateMatterAction`, `FollowUpGenerateDraftAction`, `FollowUpLogResponseAction`, `FollowUpEscalateMatterAction` |
| Flow | `Follow_Up_Recommendation_Before_Save`, `Follow_Up_Task_Completed` |
| UI | LWC `treatmentRecordsFollowUpConsole`, Tab `Follow_Up_Work_Queue` |
| Security | Permission sets `Follow_Up_Case_Manager`, `Follow_Up_Supervisor`, `Follow_Up_Automation`, 4 custom permissions |
| Analytics (`analytics/`) | Report types ×2, 6 reports, dashboard *Follow-up Operations* |
| Agentforce (`agentforce/`) | `FollowUpPromptFacts` (Prompt Builder grounding), `FollowUpEinsteinDraftGenerator`, `FollowUpEinsteinClassifier`, `FollowUpEinsteinTest` |
| Agentforce (manual, `agentforce.md`) | Agent, 3 topics, 6 agent actions (from the Apex invocables), 4 flex prompt templates (bodies in `docs/prompt-templates/`) |

## 4. Extension points (designed, not built)
- SMS / e-fax / telephony: `IFollowUpChannel` + Named Credential.
- Direct `MessagingSession` / `EmailMessage` ingestion: a record-triggered flow on those objects that calls the `FollowUpLogResponseAction` invocable.
- Stall-risk prediction: `Stalled__c` history gives the labelled data for a future Einstein Discovery / Data Cloud model. It is not built now because it needs production history.
