# Simple Treatment & Records Follow-up Agent

## Purpose

This branch keeps the core law-firm workflow focused on monitoring existing open Personal Injury matters and helping case managers act on genuine follow-up needs.

## Core workflow

1. Maintain existing Matter, Treatment Visit, Records Request, Medical Provider, and client-contact records in Salesforce.
2. Evaluate open matters using the configured follow-up rules.
3. Create a recommendation only when a treatment gap, outstanding records/bills, a required client status update, or a stalled-matter condition needs attention.
4. Suppress duplicate recommendations and respect repeat/snooze cadence.
5. Show actionable items in the Follow-up Work Queue with the reason and relevant matter/provider facts.
6. Require case-manager review/approval before client-facing or provider-facing communication is sent.
7. Log the follow-up outcome and evaluate the matter again on the next run.

## Optional inbound-email capture

The `Automatic_Intake__c` feature is deliberately limited to capturing inbound email metadata/body and attachments for case-manager review. It does not perform AI extraction, automatically match Matter/Provider records, create Treatment Visits/Records Requests, or send messages. The core follow-up engine does not depend on Automatic Intake.

If an intake email contains verified information, a case manager should verify the Matter/provider and update the existing Treatment Visit or Records Request. That saved business record will then be considered by the normal follow-up evaluation.

## Why this is intentionally small

- Date thresholds, request status, follow-up counts, duplicate prevention, and escalation are deterministic Salesforce logic.
- AI/document extraction is not required for the core use case and is not enabled in this branch.
- Ambiguous records are not linked automatically.
- No client-facing communication is sent without the existing approval workflow.
- No recommendation is created for a matter when no follow-up action is required.

## Salesforce test checklist

1. Create/use an open Matter with a Treatment Visit older than the configured treatment-gap threshold and no upcoming treatment. Run the evaluation. Expect one Client Check-In recommendation.
2. Create/use an open Matter with an outstanding Records Request older than the configured records follow-up threshold. Run the evaluation. Expect a Provider Follow-up recommendation.
3. Verify a request with the configured prior-follow-up count and elapsed cadence creates an internal escalation Task/recommendation.
4. Run evaluation again without changing the facts. Expect no duplicate open recommendation.
5. Use a healthy Matter with recent treatment and no overdue records. Expect no recommendation.
6. Approve/edit a draft using the existing Work Queue workflow and verify the existing send-approval controls are enforced.
7. Optionally email the configured intake address. Expect one `Automatic_Intake__c` review record with attachments linked, without automatic Treatment Visit/Records Request creation.

## Deployment notes

Deploy the Salesforce DX `force-app` package to a sandbox first, then run the relevant Apex tests. Email Service routing and allowed-sender policy must be configured in the target org if optional intake capture is used. This repository update has not been deployed into or runtime-tested in the target Salesforce org.
