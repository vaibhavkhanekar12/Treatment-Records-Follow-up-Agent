# Communication & Notification Model

## Purpose
The solution supports operational follow-up through Email, SMS, Fax, Phone/Task, plus internal Salesforce notifications. External communication is always subject to the existing server-side approval controls.

## Channel behavior
- Email: native Salesforce Messaging.SingleEmailMessage via FollowUpEmailChannel.
- SMS: integration point through IFollowUpChannel + External Credential/Named Credential. Until configured, a manual Task is created.
- Fax: integration point through IFollowUpChannel + External Credential/Named Credential. Until configured, a manual Task is created.
- Phone: manual Task for the case manager, preserving the approved draft/instructions.
- Internal Task: case-manager or supervisor action item.
- Salesforce Custom Notification: internal alert when a new recommendation is assigned; it never contacts a client or provider.

## Human-in-the-loop
Client/provider communication must remain Pending Review until a permitted user approves it. Only FollowUpSendService can deliver external communication.

## Suggested operational flow
Recommendation -> Salesforce notification -> Work Queue -> draft/edit -> approve -> send via configured channel -> log delivery -> log inbound response -> classify -> deterministic next action.

## Optional extensions
A firm may add Salesforce Messaging/WhatsApp or Slack as a separate adapter/event flow. Those integrations should write an auditable activity and reuse the same approval/recipient/opt-out controls rather than bypassing FollowUpSendService.
