# Treatment & Records Follow-up Agent

Salesforce + Agentforce solution for a **Personal Injury law firm**. It monitors open matters, identifies treatment gaps, medical-record/bill delays, stale client contact and potentially stalled matters, then prepares an operational follow-up for human review.

> The agent is an internal case-management assistant, not a lawyer. It never gives legal or medical advice, never discusses liability, case value or settlement, and never sends external communication without the required server-side approval.

## End-to-end workflow

Nightly evaluator scans open PI matters → deterministic rule engine evaluates treatment gaps, records age, missing bills, client-contact recency and stalled-risk conditions → Follow_Up_Recommendation__c stores the recommendation and facts → Salesforce in-app notification alerts the assigned case manager → optional AI/template drafting prepares the message and rationale → Follow-up Work Queue supports edit/approve/reject/override/send/log-response → only human-approved external messages can be sent, including the optional scheduled sender → delivery is recorded → inbound response can be classified → deterministic re-check/review action is scheduled.

## Follow-up use cases

- Treatment gap / client check-in
- Outstanding medical-records follow-up
- Provider escalation after repeated unanswered follow-ups
- Missing bills
- Potentially stalled matter / rule-based at-risk signal
- Monthly plain-language client status update (approval-controlled)
- Case-manager in-app notification
- Email delivery
- SMS/Fax integration points with Task fallback
- Phone/internal Tasks
- Inbound response classification and case-manager review
- Audit/history and operational reporting

## Communication model

**Internal:** Salesforce Custom Notification → Work Queue / Task.

**External:** Email is native Salesforce delivery. SMS and e-fax use the pluggable IFollowUpChannel interface and Named/External Credentials; until an adapter is configured, the system creates a manual delivery Task. The optional scheduled sender delivers only recommendations that were already approved by an authorized human.

## Core architecture

```
Daily/Nightly Schedule
        ↓
FollowUpEvaluationBatch
        ↓
FollowUpRuleEngine + Custom Metadata
        ↓
Follow_Up_Recommendation__c
        ↓
Custom Notification
        ↓
Case Manager Work Queue
        ↓
Draft → Edit → Approve
        ↓
Scheduled Send / Manual Send
        ↓
Email / SMS / Fax / Task
        ↓
Inbound Response
        ↓
Classification
        ↓
Complete / Re-check / Case Manager Review
```

AI is used for drafting, rationale and inbound classification only. Eligibility is deterministic and configured in Custom Metadata.

## Salesforce components

- Core custom object: Follow_Up_Recommendation__c
- Matter fields: Stalled__c, Stalled_Since__c
- Custom Metadata: follow-up rules, global settings, response classification rules
- LWC: treatmentRecordsFollowUpConsole
- Apex: batch evaluator, schedulers, recommendation workflow, delivery service, response service, Agentforce actions
- Custom notification: Follow-up Recommendation Notification
- Reports/dashboard: Follow-up Operations
- Agentforce: Matter Follow-up Review, Follow-up Drafting, Inbound Response Handling

## Deployment

If the target org does not already contain the repository's prerequisite data model, deploy it **first**, then deploy the solution. Do not deploy the sample prerequisite objects into an established org that already has its own Matter / Treatment Event / Records Request / Medical Provider data model.

For the Personal Injury org on Windows, use the ordered deployment script:

```powershell
.\\scripts\\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
```

The script stops if the prerequisite deployment fails, preventing cascading `Medical_Provider__c`, `Records_Request__c`, custom metadata, and dependent Apex compiler errors.

If the target org already has those objects, skip `prerequisites/` and follow `docs/deployment.md` to map the existing data model before deploying the solution.

Complete Agentforce Builder/Prompt Builder configuration manually in the target org.

Schedule the recurring jobs:
```apex
FollowUpNightlyScheduler.schedule(null);
FollowUpApprovedSendScheduler.schedule(null);
```

The second scheduler is optional. It runs as the dedicated automation user and sends only due recommendations with Status__c = Approved.

## Known limitations / required integration setup

- The repository cannot configure a firm's external SMS/fax/telephony provider without the target org's Named/External Credential and provider contract.
- Agentforce topics, actions and Prompt Builder templates are manual configuration that should be retrieved from the validated org after setup.
- The existing solution should be mapped to the real Matter__c, Treatment_Event__c, Records_Request__c and Medical_Provider__c data contract before deployment.
