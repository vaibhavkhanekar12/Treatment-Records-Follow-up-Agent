# Complete Use Cases

1. Treatment gap: identify configured treatment gap and create client check-in recommendation.
2. Records delay: identify outstanding records request and create provider follow-up.
3. Provider escalation: raise escalation after configured unanswered follow-ups.
4. Missing bills: identify missing bill request after treatment activity.
5. Stalled matter: combine treatment, records and client-contact staleness and flag the Matter.
6. Monthly client status update: create a scheduled recommendation when cadence threshold is reached; keep it configurable and approval-controlled.
7. Case-manager notification: create an internal Salesforce notification for newly assigned recommendations.
8. Work Queue review: filter, inspect facts/history, edit drafts, approve, reject, override, complete, send, and log response.
9. Inbound response: capture verbatim client/provider response, classify to an operational category, and create review/re-check action according to Custom Metadata.
10. Channel fallback: use Email/SMS/Fax when configured; otherwise create a manual Task so no recommendation disappears.
11. Audit: record approval, send result, delivery note, response, and next-follow-up information on the recommendation.
12. Agentforce conversational review: answer matter follow-up questions from verified Salesforce facts and invoke the same deterministic actions.
13. Reporting: surface pending approvals, open follow-ups, provider escalations, stalled matters, treatment gaps and response rate through Salesforce reports/dashboard.

## Boundary
The agent does not provide legal advice, medical advice, case valuation, liability conclusions, settlement recommendations, or autonomous client/provider sending.
## Requirement traceability — Treatment & Records Follow-up Agent

| Business requirement | Repository implementation |
|---|---|
| Monitor every open PI matter daily | FollowUpNightlyScheduler → FollowUpEvaluationBatch → FollowUpEvaluationService |
| Treatment gap vs today | Follow_Up_Rule.Treatment_Gap + FollowUpRuleEngine.evaluateTreatmentGap |
| Records requested vs received | Records_Request__c facts + Follow_Up_Rule.Records_Follow_Up |
| Bills vs treatment events | Follow_Up_Rule.Missing_Bills + evaluateMissingBills |
| Client contact recency | Completed client Task history in FollowUpMatterSelector |
| Provider misses second follow-up | Follow_Up_Rule.Provider_Escalation with Escalate_After_Count__c = 2 |
| Case-manager escalation Task | Auto_Create_Task__c = true + FollowUpEvaluationService task creation |
| Stalled matter / at-risk signal | Treatment + records + client-contact staleness in evaluateStalledMatter; writes Matter__c.Stalled__c |
| Monthly client update | Follow_Up_Rule.Client_Status_Update + client-facing draft |
| Human approval before external send | FollowUpRecommendationService approve/bulkApprove + FollowUpApprovedSendBatch |
| Approved messages sent on schedule | FollowUpApprovedSendScheduler |
| Inbound response classification | Response_Classification_Rule__mdt + response/AI classification services |
| Audit and reporting | Follow_Up_Recommendation__c, reports and dashboard |
| ROI: treatment gap / records turnaround | Gap_Days__c, Records_Age_Days__c, recommendation/report data |
| AI generation and summarization | Agentforce/Prompt Builder adapters; deterministic rules remain authoritative |
