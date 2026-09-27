# Testing

## 1. What was actually executed in the build environment

| Check | Tool | Result |
|---|---|---|
| LWC unit tests | `sfdx-lwc-jest` | **10 / 10 passed** |
| LWC lint | ESLint (`@salesforce/eslint-config-lwc/recommended`) | **0 errors** |
| Apex syntax (all 50 classes) | Prettier Apex parser (Salesforce jorje grammar) | **All parse** |
| Metadata structure | `sf project convert source` on all 4 package directories | **All convert** |
| XML well-formedness | 200+ metadata files | **All well-formed** |
| Apex static analysis | Salesforce Code Analyzer (PMD Recommended + Security) | **0 High**; Moderate/Low = complexity, ApexDoc |
| **Apex unit tests** | `sf apex run test` | **NOT RUN: no Salesforce org was available** |
| Flow / validation rule behaviour | Apex tests exercise them | **NOT RUN** (same reason) |
| Deployment validation | `sf project deploy validate` | **NOT RUN** (same reason) |

The Apex tests are written against real behaviour: DML, flows, validation rules, permission sets, `System.runAs` users and sharing. They must be executed in a scratch/dev org (commands in `deployment.md`) before this work is considered verified. Expect to fix minor issues on the first org run.

## 2. Apex test classes

| Class | Focus | Key scenarios |
|---|---|---|
| `FollowUpRuleEngineTest` | Pure rule logic (in-memory, no DML) | recent treatment → nothing; gap → check-in; SMS→Email→Phone fallback; no treatment uses sign-up; upcoming appointment suppresses; unanswered check-ins escalate; missing client; missing dates → warning; outstanding request → provider follow-up; received/young requests ignored; fax fallback; 2nd missed follow-up escalates; escalation waits for threshold; open item suppresses; cadence / snooze / rejection / superseded suppression; missing bills; stalled needs all 3 signals; monthly update due/not due; inactive rules; priority/channel helpers |
| `FollowUpEvaluationServiceTest` | Service + Flow + batch | end-to-end creation; **idempotent second run**; resumed treatment **supersedes** open check-in; stalled flag set/cleared with auto-Task; **Task completion flow** closes recommendation; escalation auto-Task; **200-matter bulk run with ≤ 15 queries**; batch only evaluates open PI matters; scheduler; AI queueable accepts safe / discards unsafe drafts |
| `FollowUpRecommendationServiceTest` | Human-in-the-loop | approve with edits (stamp by approver); edit after approval re-opens; **no approve permission blocked**; **no matter access blocked**; bulk approve only templates; reject requires reason; override priority/snooze; supervisor cannot act without access; complete; empty draft blocked; closed status blocked |
| `FollowUpSendServiceTest` | Server-side send enforcement | **unapproved send blocked**; **validation rule blocks direct Sent**; approved email sent + activity logged; SMS without integration → manual Task → completes via Flow; registered integration used; internal send without approval; failure → retry; **no send permission blocked**; email opt-out / missing address |
| `FollowUpResponseServiceTest` | Inbound classification | the four examples from the brief + opt-out + unclear; Treatment_Stopped → review + pause; Records_Sent → complete + re-check; low confidence → review, no pause; human category; invalid category rejected; matter-only attaches to latest sent; unmatched response held; **async AI** classification; AI failure → keyword fallback |
| `FollowUpAgentActionsTest` | Agent actions as a user | verified facts without Ids; inaccessible matter → neutral message, nothing created; evaluate → draft → history; agent-supplied category; escalation idempotent; reason required |
| `FollowUpWorkQueueControllerTest` | LWC controller | filters and priority order; detail facts/history; save→approve→send→suggest→log; errors as `AuraHandledException`; regenerate / bulk approve / override / evaluate |
| `FollowUpDraftServiceTest` | Drafting and guard | restricted-term guard; AI result application (safe/unsafe/failed/internal); approval reset; unresolvable generator class; provider draft numbering; **facts contain no Ids or DOB** |
| `FollowUpConfigTest` | Configuration | CSV parsing; inactive/threshold-less rules skipped; safe defaults when unconfigured; classification ordering; deployed CMDT loads |
| `FollowUpEinsteinTest` (`agentforce/`) | Prompt grounding and adapters | grounding has facts, placeholder, no DOB/Ids; no-access grounding; JSON parsing with fences; template routing; LLM failure reported not thrown; classification parsing |

Test classes create up to three Standard User licences each, so run them in an **Enterprise** scratch org (`config/project-scratch-def.json`) or a sandbox; Developer Edition licence limits can fail user creation.

Tests inject configuration in memory (`FollowUpTestDataFactory.useDefaultConfig()`), so results don't depend on the org's CMDT values. `FollowUpConfigTest` separately checks that the deployed records load.

## 3. Governor-limit design (what the bulk test protects)

- The selector issues **7 queries per evaluation call, regardless of scope size** (aggregates for treatment dates and client contact, no per-matter queries).
- All DML is list-based: one insert of recommendations, one of Tasks, one update each for superseded items and stalled flags.
- The batch scope size is configurable (`Batch_Size__c`, default 100).
- AI drafting is chunked (10 per queueable execution) and capped per run.

## 4. How to run

```bash
# LWC
npm ci && npm run lint && npm run test:unit
# Apex (org required)
sf apex run test --target-org pi-dev --test-level RunLocalTests --code-coverage --result-format human --wait 30
# Agentforce adapters (org with Einstein generative AI)
sf apex run test --target-org pi-dev --tests FollowUpEinsteinTest --result-format human --wait 10
# Static analysis
sf code-analyzer run --workspace force-app --workspace agentforce --rule-selector pmd:Recommended --rule-selector pmd:Security
```

## 5. Manual UAT script

1. Run `scripts/apex/create-sample-data.apex`. Open the *Follow-up Work Queue*. SAMPLE-001 shows a client check-in (SMS), a provider follow-up (email), missing bills and a monthly update. SAMPLE-002 shows a monthly update only: the recent visit and upcoming appointment mean no check-in. SAMPLE-003 is flagged **Stalled** with an assigned Task, plus a phone-script check-in (the client has no email or mobile) and a fax provider follow-up.
2. Try to send the SAMPLE-001 check-in before approving it: Send is disabled, and the API call is rejected.
3. Edit and approve, then send. Status becomes *Sent*, and a manual SMS delivery Task is created with the mobile number.
4. Log the response "I stopped treatment last month": an *Inbound Response Review* appears and check-ins pause for 14 days.
5. Bulk-select monthly updates → *Bulk approve templates* → *Send selected*.
6. Snooze the provider follow-up for 14 days → *Evaluate this matter* on SAMPLE-001 creates no duplicate.
7. As a supervisor user: Approve/Send are disabled, the dashboard shows the stalled matter.
8. Agent (if configured): run the scenarios in `agentforce.md` section 8.
