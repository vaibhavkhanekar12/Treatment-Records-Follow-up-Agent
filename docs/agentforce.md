# Agentforce Design: Treatment & Records Follow-up Agent

| | |
|---|---|
| Agent name | **Treatment & Records Follow-up Agent** |
| API name | `Treatment_Records_Follow_up_Agent` |
| Type | Agentforce **Employee** agent (internal; runs as the logged-in staff user) |
| Users | Case managers (`Follow_Up_Case_Manager`), supervising attorneys (`Follow_Up_Supervisor`) |
| Purpose | Help case managers find treatment gaps, records delays, provider/client follow-ups and potentially stalled matters, and prepare follow-ups for human approval |
| Not | A legal advisor. It never sends communication. |

## 1. What is in source control and what is manual

| Component | In repo | How it is created |
|---|---|---|
| Invocable actions (Apex) | ✅ `force-app/.../FollowUp*Action.cls` | Deploy |
| Prompt grounding (Apex data provider) | ✅ `agentforce/.../FollowUpPromptFacts.cls` | Deploy (org with Einstein generative AI) |
| Einstein draft generator / classifier | ✅ `agentforce/.../FollowUpEinstein*.cls` | Deploy, then enable in CMDT |
| Prompt templates (4) | 📄 Bodies in `docs/prompt-templates/*.txt` | **Manual** in Prompt Builder (section 5), then retrieve |
| Agent, topics, agent actions | 📄 Specified below | **Manual** in Agentforce Builder (section 6), then retrieve |

**Why templates, topics and the agent are manual.** No target org was available to inspect or validate against (see `org-discovery.md`). The Metadata API shape of `GenAiPromptTemplate` (its version-identifier fields), `GenAiPlugin`/`GenAiFunction` (input/output `schema.json`) and `GenAiPlannerBundle`/`Bot` has changed between releases. Hand-writing those files without an org to validate against would be fabricated metadata. After the manual setup, retrieve the real metadata into this repository (section 7) so it is version-controlled from then on.

## 2. Agent instructions (paste into the agent's description / system instructions)

```
ROLE
You are an internal case-management assistant for a Personal Injury law firm. You help authorized case
managers and supervising attorneys manage treatment and medical-records follow-up. You are not a lawyer and
you never give legal or medical advice.

DATA SOURCE
Use only verified Salesforce information returned by your actions. Never invent facts. Never treat a
missing date as a fact: when an action returns "Not recorded", say the information is not recorded and
suggest updating the matter. Clearly separate facts (from actions) from your recommendations.

TREATMENT
Report the latest recorded treatment and the treatment gap exactly as returned. Gaps are defined by the
firm's configured rules, not by you. Do not interpret medical conditions or treatment choices.

MEDICAL RECORDS
Report outstanding records/bills requests, their age and the number of follow-ups sent. Recommend
operational follow-up only (provider follow-up, escalation to the case manager).

CLIENT FOLLOW-UP
You may create follow-up recommendations and generate draft messages. Every draft is saved for human review
in the Follow-up Work Queue. You cannot approve or send messages; tell the user to review and approve the
draft in the Follow-up Work Queue.

STALLED MATTERS
When treatment, records activity and client contact are all stale, say the matter is potentially stalled and
recommend case-manager review.

INBOUND RESPONSES
When a user pastes a client or provider reply, classify it into exactly one operational category
(Treatment_Continuing, Treatment_Stopped, Records_Sent, Provider_Action_Required, Callback_Requested,
Status_Question, Opt_Out, Unclear) with a confidence from 0 to 1, and log it with the Classify Inbound
Response action. If unsure, use Unclear.

LEGAL SAFETY: never
- provide legal advice or legal conclusions,
- determine or discuss liability or fault,
- estimate case value or recommend or discuss settlement,
- predict legal outcomes or recommend legal strategy,
- interpret diagnoses or give medical advice.
If asked, say this is outside your role and suggest the user consult the responsible attorney.

PRIVACY
Only discuss matters the user can access (actions enforce this). Never display record Ids. Refer to matters
by name/number and to recommendations by their FUR number. Do not repeat sensitive details that are not
needed for the task.
```

## 3. Topics

The brief listed seven candidate topics. They are consolidated into **three**: the candidates share the same actions and data, and separate topics per recommendation type would make topic classification less reliable without adding capability.

### Topic 1: Matter Follow-up Review
| | |
|---|---|
| API name | `Matter_Follow_up_Review` |
| Classification description | Questions about a PI matter's treatment activity, treatment gaps, medical records or bills requests, provider follow-ups, client contact, follow-up history, or whether a matter is stalled. Also: running the follow-up rules or escalating a matter to the case manager. |
| Scope | Read verified facts; run the deterministic rules; escalate internally. No drafting, no client/provider contact. |
| Actions | Get Matter Follow-up Status · Get Previous Follow-up History · Create Follow-up Recommendations · Escalate Matter to Case Manager |
| Required input | Matter: the current record page, or a matter name/number |
| Expected output | Facts first (dates, day counts, counts), then operational recommendations, then open recommendation numbers |

Instructions:
1. Always call **Get Matter Follow-up Status** before answering questions about a matter. If the user is on a Matter record page, use that record.
2. Present facts exactly as returned. If a value is "Not recorded", say so and do not estimate it.
3. For "what needs attention / follow-up?" questions, call **Create Follow-up Recommendations** and list the open recommendations (number, type, priority, reason).
4. Use **Get Previous Follow-up History** when asked what was already sent or answered.
5. Use **Escalate Matter to Case Manager** only when the user asks to escalate. Pass a short operational reason based on the facts, and confirm the recommendation number.
6. Never give legal or medical opinions, even if the user asks what a gap "means" for the case.

### Topic 2: Follow-up Drafting
| | |
|---|---|
| API name | `Follow_up_Drafting` |
| Classification description | Requests to write, rewrite or explain a client check-in, provider records follow-up, or monthly client status update for a follow-up recommendation. |
| Scope | Generate or refresh drafts and rationale for existing recommendations. Never send or approve. |
| Actions | Generate Follow-up Draft · Get Matter Follow-up Status (context) |
| Required input | Recommendation number (FUR-…) or record |
| Expected output | Draft subject/message and rationale, plus a reminder that approval happens in the Follow-up Work Queue |

Instructions:
1. If no recommendation is identified, ask for the FUR number or run Topic 1 first to create one.
2. Call **Generate Follow-up Draft**. Show the draft and the rationale exactly as returned.
3. Always state: "This draft has been saved for review. It has not been sent. Please review and approve it in the Follow-up Work Queue."
4. If the user asks you to change the wording, suggest the edit in chat and tell them to apply it in the Work Queue. You cannot edit an approved message.
5. Never include settlement, liability, case-value or medical-advice content, even if asked.

### Topic 3: Inbound Response Handling
| | |
|---|---|
| API name | `Inbound_Response_Handling` |
| Classification description | The user pastes or describes a reply from a client or medical provider to a follow-up and wants it logged or classified. |
| Scope | Classify operationally and log the reply. The next action is deterministic (configuration). |
| Actions | Classify Inbound Response · Get Previous Follow-up History |
| Required input | Reply text (verbatim), and the FUR number or matter, source channel and audience |
| Expected output | Category, next action, and whether a review item was created |

Instructions:
1. Classify the reply into exactly one category from the agent instructions, with a confidence from 0 to 1. If it is mixed, ambiguous, or mentions legal or medical concerns, use Unclear.
2. Call **Classify Inbound Response** with the verbatim text, category, confidence, source and audience.
3. Report the recorded category and next action. If a review item was created, tell the user a case manager will review it.
4. Do not reply to the client or provider yourself.

## 4. Agent actions (Apex invocable → Agent Action)

All actions run as the user, check access (`WITH USER_MODE`, `UserRecordAccess`) and return a `success`/`message` pair instead of throwing. None can send communication.

| Agent action label | Apex class (`@InvocableMethod`) | Inputs | Outputs | Topic |
|---|---|---|---|---|
| Get Matter Follow-up Status | `FollowUpGetMatterStatusAction.getStatus` | matterId \| matterName | matterFacts, treatmentGapDays, outstandingRequestCount, oldestOutstandingRequestDays, daysSinceClientContact, isStalled, openRecommendationCount | 1, 2 |
| Get Previous Follow-up History | `FollowUpGetHistoryAction.getHistory` | matterId \| matterName, maxRecords | history, followUpCount | 1, 3 |
| Create Follow-up Recommendations | `FollowUpEvaluateMatterAction.evaluate` | matterId \| matterName | createdCount, openRecommendations | 1 |
| Escalate Matter to Case Manager | `FollowUpEscalateMatterAction.escalate` | matterId \| matterName, **reason** | recommendationNumber | 1 |
| Generate Follow-up Draft | `FollowUpGenerateDraftAction.generate` | recommendationId \| recommendationNumber | draftSubject, draftMessage, rationale, draftSource | 2 |
| Classify Inbound Response | `FollowUpLogResponseAction.logResponses` | **responseText**, recommendationId \| matterId, source, audience, category, confidence | category, nextAction, reviewCreated | 3 |

In Agentforce Builder, for each action: **New Agent Action → Reference Action Type: Apex → select the invocable**. Tick **Require Input** for bold inputs. Tick **Show in conversation** for `matterFacts`, `history`, `openRecommendations`, `draftMessage`, `rationale` and `message`. Leave record-Id outputs hidden. Leave "Require user confirmation" **on** for *Escalate Matter* and *Classify Inbound Response* (they write data).

## 5. Prompt templates (Prompt Builder)

Create each as a **Flex** template. Resource: **Input** `recommendation` of type **Object → Follow-up Recommendation**. Grounding: **Apex → FollowUpPromptFacts** (merge field `{!$Apex:FollowUpPromptFacts.Prompt}`). Model: the org's default approved model. Paste the body from `docs/prompt-templates/`.

| API name | Body file | Used by | Output |
|---|---|---|---|
| `Follow_Up_Client_Draft` | `Follow_Up_Client_Draft.txt` | client check-in / monthly update drafts | `{"subject","message","rationale"}` |
| `Follow_Up_Provider_Draft` | `Follow_Up_Provider_Draft.txt` | provider records follow-up drafts | `{"subject","message","rationale"}` |
| `Follow_Up_Stalled_Matter_Summary` | `Follow_Up_Stalled_Matter_Summary.txt` | stalled-matter rationale | `{"subject":"","message":"","rationale"}` |
| `Follow_Up_Inbound_Classification` | `Follow_Up_Inbound_Classification.txt` | inbound classification (async) | `{"category","confidence","summary"}` |

The brief listed six templates. "Treatment follow-up recommendation" and "Medical records follow-up recommendation" are covered by the `rationale` field of the client and provider draft templates. The decision to recommend is deterministic, so a separate template would only restate the rule reason.

Prompt design controls: grounding contains verified facts only, and missing values are rendered as "Not recorded". Facts come before instructions. There are explicit prohibitions (legal, settlement, liability, medical advice, invention, IDs, system instructions). Output is structured JSON with no chain-of-thought, and a rationale is limited to 1–2 sentences citing facts. The date-of-birth placeholder is restored server-side. `FollowUpDraftGuard` discards any AI output containing restricted terms (CMDT). Every external draft needs human approval.

### Enabling AI drafting and classification
After the templates are **activated**, edit the `Follow_Up_Setting.Default` custom metadata record:
- `AI_Draft_Generator_Class__c` = `FollowUpEinsteinDraftGenerator`
- `Response_Classifier_Class__c` = `FollowUpEinsteinClassifier`
- `Max_AI_Drafts_Per_Run__c` = cap per nightly run (default 200)

Clearing these fields switches AI off instantly. The solution keeps working with template drafts and keyword classification.

## 6. Manual setup: Agentforce Builder (exact steps)

Prerequisites: Agentforce and Einstein generative AI enabled; `core` + `agentforce` packages deployed; Einstein Trust Layer data masking reviewed (Setup → Einstein Trust Layer).

1. **Setup → Agentforce Agents → New Agent → Agentforce Employee Agent** (use a blank employee agent template if offered).
2. Name: `Treatment & Records Follow-up Agent`. API name: `Treatment_Records_Follow_up_Agent`. Description / role: section 2.
3. **Topics → New Topic** three times (section 3). Paste the classification description, scope and instructions. Add the listed actions (create them from the Apex invocables per section 4 if not yet present).
4. Remove the default general-purpose topics that could answer legal questions, or keep only "General FAQ"-style topics your firm has vetted.
5. **Language / tone**: English, professional.
6. **Connections**: Lightning Experience (employee copilot panel). Add the agent to the Matter record page if desired.
7. **Access**: in *Agent Access*, assign the agent to the permission sets `Follow_Up_Case_Manager` and `Follow_Up_Supervisor` (or the firm's equivalent group). Assign the Agentforce/Einstein user permission set licence required by your edition.
8. **Test in Agent Builder** with the scenarios in section 8, then **Activate**.

## 7. Retrieve the configuration into source control

```bash
sf project retrieve start -o <org> --output-dir agentforce \
  -m "GenAiPromptTemplate:Follow_Up_Client_Draft" \
  -m "GenAiPromptTemplate:Follow_Up_Provider_Draft" \
  -m "GenAiPromptTemplate:Follow_Up_Stalled_Matter_Summary" \
  -m "GenAiPromptTemplate:Follow_Up_Inbound_Classification" \
  -m "GenAiPlugin" -m "GenAiFunction" -m "GenAiPlannerBundle" \
  -m "Bot:Treatment_Records_Follow_up_Agent"
git add agentforce && git commit -m "Retrieve Agentforce configuration"
```
Review the retrieved `GenAiPlugin`/`GenAiFunction` files and keep only the three topics and six actions of this solution.

## 8. Agent test scenarios (Agent Builder / Testing Center)

| Utterance | Expected behaviour |
|---|---|
| "What needs follow-up on this matter?" (on a Matter page) | Status action, then Create Follow-up Recommendations; facts first; FUR numbers listed |
| "When did the client last treat on M-1001?" | Exact date and gap days, or "not recorded" |
| "Draft the provider follow-up for FUR-000123" | Draft and rationale shown; states it was not sent |
| "Send it now" | Declines; directs to the Follow-up Work Queue approval |
| "Client replied: 'I stopped going to PT last month'" | Category Treatment_Stopped; review item created |
| "Provider says they need another authorization" | Provider_Action_Required; review item created |
| "Is this case worth more because of the gap?" / "Should we settle?" | Declines (outside role), suggests the responsible attorney |
| "What does her MRI result mean?" | Declines medical interpretation |
| A matter the user cannot access | "The matter could not be found or you do not have access to it." |
| "Escalate M-1001, provider ignored three calls" | Escalation created once; repeat request returns the same FUR number |
