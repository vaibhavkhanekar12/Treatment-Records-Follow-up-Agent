# Treatment & Records Follow-up Agent — Final Org Implementation Guide

## 1. Purpose

This solution is an internal Salesforce + Agentforce assistant for a Personal Injury law firm. It identifies operational follow-up needs around treatment, medical records, bills, provider responses, client contact, and stalled matters.

The solution is designed for case managers and supervising attorneys. It does not provide legal or medical advice and does not make liability, settlement, or case-value decisions.

## 2. Current repository status

The `updated` branch contains the Salesforce automation, follow-up recommendation lifecycle, notification service, approved-message sender, delivery/response services, LWC console, AI drafting/classification support, permissions, documentation, analytics, and Agentforce Apex support.

The repository is implementation-ready for target-org deployment, but the following must still be configured and validated in the target Salesforce org:

- Agentforce Builder agent/topics/actions
- Prompt Builder templates and activation
- Real Matter/Treatment/Records/Provider field mappings
- User permissions and permission-set assignments
- Named/External Credentials for external SMS/e-fax providers, if required
- Target-org Apex tests and deployment validation
- UAT and production activation

## 3. Architecture

```
Open PI Matters
      |
      v
FollowUpEvaluationBatch
      |
      v
FollowUpRuleEngine + Custom Metadata
      |
      v
Follow_Up_Recommendation__c
      |
      +--> Internal Custom Notification
      |
      v
Case Manager Work Queue
      |
      +--> Draft / Edit
      |
      +--> Approve / Reject / Override
      |
      v
Approved Follow-up
      |
      +--> Manual Send
      |
      +--> Optional Scheduled Sender
      |
      v
Email / SMS / eFax / Manual Task
      |
      v
Inbound Response
      |
      v
AI Classification + Deterministic Re-check
      |
      +--> Complete
      +--> Schedule next follow-up
      +--> Case Manager Review
```

Eligibility is deterministic. AI is limited to drafting, rationale and inbound-response classification.

## 4. Main Salesforce components

### Apex
- FollowUpEvaluationBatch
- FollowUpNightlyScheduler
- FollowUpRuleEngine
- FollowUpEvaluationService
- FollowUpNotificationService
- FollowUpApprovedSendBatch
- FollowUpApprovedSendScheduler
- FollowUpSendService
- FollowUpDeliveryService
- FollowUpResponseService
- FollowUpEinsteinDraftGenerator
- FollowUpEinsteinClassifier
- Agentforce action classes
- Supporting test classes

### UI
- `treatmentRecordsFollowUpConsole`
- Follow-up Work Queue
- Matter follow-up workspace
- Reports/dashboard

### Data
- `Follow_Up_Recommendation__c`
- Matter status/stalled fields
- Treatment Events
- Records Requests
- Medical Providers
- Follow-up rules/settings Custom Metadata

## 5. Agentforce configuration

Create an internal employee-facing Agentforce agent named:

**Treatment & Records Follow-up Agent**

Recommended functional areas/topics:

### Matter Follow-up Review
Purpose: review a Matter and explain outstanding follow-up work.

Actions:
- Get Matter Follow-up Status
- Get Previous Follow-up History
- Create Follow-up Recommendations
- Escalate Matter to Case Manager

Example request:
> Review follow-ups for this Matter and tell me what requires attention.

Expected behavior:
1. Identify the Matter.
2. Retrieve deterministic follow-up status.
3. Review previous follow-up history.
4. Present outstanding items with reason, priority and recommended date.
5. Offer escalation when configured rules require it.

### Follow-up Drafting
Purpose: prepare a communication draft for human review.

Actions:
- Generate Follow-up Draft

Example:
> Draft a provider follow-up for the outstanding medical records.

Rules:
- Use only Salesforce facts supplied to the action.
- Do not invent provider, treatment, date, record or bill information.
- Do not provide legal or medical advice.
- Do not send directly.
- Return a draft for human editing and approval.

### Inbound Response Handling
Purpose: classify a provider/client response and determine the operational next step.

Actions:
- Classify Inbound Response
- Get Previous Follow-up History

Expected outcomes can include:
- Response received / action complete
- Records promised
- Additional information required
- No response / continue follow-up
- Escalate to case manager
- Needs human review

## 6. Prompt Builder

Configure the repository-supported templates in the target org:

- `Follow_Up_Client_Draft`
- `Follow_Up_Provider_Draft`
- `Follow_Up_Stalled_Matter_Summary`
- `Follow_Up_Inbound_Classification`

Activate only after validating grounding data and output behavior.

Prompt rules:
- Ground output only in supplied Salesforce facts.
- Do not invent missing information.
- Do not make legal conclusions.
- Do not make medical recommendations.
- Do not discuss settlement value.
- Keep external drafts operational and professional.
- Treat AI output as a draft requiring human review.

## 7. Follow-up lifecycle

Recommended lifecycle:

```
Recommendation Created
        |
        v
Drafted (optional)
        |
        +--> Rejected
        |
        +--> Edited
        |
        v
Approved
        |
        +--> Manual Send
        |
        +--> Scheduled Send when due
        |
        v
Sent
        |
        v
Response / No Response
        |
        +--> Complete
        +--> Re-check
        +--> Escalate
```

The approved-message scheduler only processes recommendations that are already approved and due. It does not approve messages.

## 8. Communication channels

Internal:
- Salesforce Custom Notification
- Work Queue
- Task

External:
- Salesforce Email
- SMS through a configured channel adapter
- eFax through a configured channel adapter

SMS/eFax require the target organization's provider, Named/External Credential and implementation of the corresponding channel adapter. Until configured, a manual Task can be used as the fallback.

## 9. Security and human control

The implementation must enforce:

- Authorized internal users only
- CRUD/FLS and sharing controls
- Human approval before external communication
- No direct external send from an AI response
- No legal/medical advice
- No liability conclusion
- No settlement/case-value recommendation
- No fabricated facts
- No unnecessary exposure of Salesforce record IDs

The approval and send checks must remain server-side.

## 10. Scheduling

Nightly evaluation:

```apex
FollowUpNightlyScheduler.schedule(null);
```

Optional approved-message sender:

```apex
FollowUpApprovedSendScheduler.schedule(null);
```

Use the approved-message scheduler only after approval workflow, permissions and delivery behavior are validated.

## 11. Permissions

Assign the appropriate permission set to case managers and other authorized users.

The permission set must cover the required objects, fields, Apex classes, custom notifications and send-related permissions.

Do not give broader permissions than required.

## 12. Deployment sequence

1. Confirm the target org and Salesforce edition/features.
2. Map the real Matter, Treatment Event, Records Request and Medical Provider data model.
3. Deploy `force-app/main/default`.
4. Deploy analytics/reporting metadata.
5. Deploy optional Agentforce Apex support.
6. Assign permission sets.
7. Configure Custom Metadata.
8. Configure Prompt Builder templates.
9. Configure Agentforce Builder topics/actions.
10. Activate the Agentforce agent only after validation.
11. Configure scheduled jobs.
12. Configure external communication credentials/adapters if needed.
13. Execute Apex tests in the target org.
14. Execute UAT with representative matters.
15. Validate audit/history and approval behavior.
16. Enable production scheduling.

## 13. UAT scenarios

### Treatment gap
Create a matter with a treatment gap beyond the configured threshold and verify that a recommendation is created.

### Records delay
Create an outstanding records request beyond its threshold and verify the recommendation and work-queue item.

### Provider escalation
Simulate repeated unanswered provider follow-ups and verify the configured escalation behavior.

### Approval
Create a draft, edit it, approve it and verify that the approved record can be sent.

### Send safety
Verify that an unapproved recommendation cannot be sent by the scheduled sender.

### Inbound response
Provide a representative response and verify classification plus the resulting operational recommendation.

### AI safety
Test missing facts, ambiguous facts and prohibited questions. The agent must not invent facts or provide legal/medical advice.

### Permissions
Test the workflow with a case-manager user and verify access boundaries.

## 14. Production checklist

- [ ] Real data model mapped
- [ ] Custom Metadata reviewed
- [ ] Permission set assigned
- [ ] Agentforce agent configured
- [ ] Agent actions configured
- [ ] Prompt Builder templates configured and activated
- [ ] AI output validated
- [ ] Notification type deployed
- [ ] Nightly scheduler configured
- [ ] Approved sender reviewed
- [ ] Email delivery validated
- [ ] SMS/eFax credentials configured if required
- [ ] Apex tests pass in target org
- [ ] UAT complete
- [ ] Audit/history validated
- [ ] Human approval verified
- [ ] Production monitoring/reporting enabled

## 15. Known limitations

The repository cannot create a firm's external communication provider contract or target-org credentials. SMS/eFax therefore require org-specific integration configuration.

Agentforce Builder and Prompt Builder are Salesforce-org configuration steps and must be completed in the target org.

The repository's automated/static checks do not replace target-org Apex tests and deployment validation.

## 16. Final implementation principle

The system should operate as a controlled case-management assistant:

**Detect -> Recommend -> Notify -> Draft -> Human Approve -> Send -> Record -> Classify -> Re-check/Escalate**

The Agentforce conversational layer should help employees understand and act on the deterministic follow-up workflow, while server-side automation remains responsible for eligibility, approval enforcement, delivery controls and auditability.
## 17. Deployment compatibility notes

The repository has been aligned with the Salesforce CLI source metadata requirements identified during target-org deployment validation:

- `sfdx-project.json` contains only package directories that exist in the repository.
- The Custom Notification Type uses the Salesforce source suffix `notiftype-meta.xml` and includes the required `masterLabel`.
- Task contact recency is calculated in Apex instead of using `MAX(ActivityDate)` in SOQL.
- The scheduled approved-message batch does not filter the long-text `Draft_Message__c` field in SOQL.
- The Prompt Builder Apex provider does not use the retired Flex `CapabilityType` binding.
- Analytics report filter language metadata has been removed to avoid an unnecessary Translation Workbench dependency.
- The Stalled Matters report no longer references the unsupported `Matter__c$CreatedDate` custom time-frame filter.
- Dashboard Metric components include indicator color metadata.
- The LWC console does not reference the internal `--lwc-fontFamilyMonospace` token.

Recommended deployment command:

    sf project deploy start --source-dir force-app --source-dir agentforce --source-dir analytics --target-org Personal_Injury_Org --wait 30

These repository changes address the source/metadata errors identified during deployment. A successful deployment still depends on the target org's available features, metadata, permissions, existing configuration, and Salesforce API behavior. Target-org deployment and Apex tests must be run before production activation.
