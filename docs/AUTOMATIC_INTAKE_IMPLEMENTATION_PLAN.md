# Automatic Intake & Record Creation — Implementation Plan

**Status:** Planning only; no production behavior or existing Apex classes changed.  
**Source branch:** `updated`  
**Planning branch:** `feature/automatic-intake-implementation-plan`  
**Tracking issue:** [#1 — Implement automatic intake and creation of treatment, provider, and records-request records](https://github.com/vaibhavkhanekar12/Treatment-Records-Follow-up-Agent/issues/1)

## 1. Goal

Reduce manual data entry by processing client/provider emails and their attachments, extracting treatment and medical-record/billing facts, and creating validated Salesforce records automatically when the evidence is strong enough. Ambiguous matter/provider matches, missing required fields, conflicting evidence, and low-confidence extraction must go to a case-manager review queue.

This is an intake pipeline alongside the existing follow-up engine, not a replacement for it.

## 2. Existing implementation inspected

The following files on `updated` were inspected while preparing this plan:

- `docs/architecture.md` — describes the existing rule-evaluation, recommendation, work-queue, approval, and response flow.
- `force-app/main/default/classes/FollowUpMatterContext.cls` — assembles already-stored Matter, provider, treatment, records-request, client-contact, and recommendation facts for downstream logic.
- `force-app/main/default/classes/FollowUpEvaluationService.cls` — evaluates matter context, creates/supersedes recommendations, assigns escalation Tasks, and maintains stalled-matter flags.
- `force-app/main/default/triggers/TreatmentEventTrigger.trigger` — reevaluates follow-up after Treatment Event insert/update; it does not ingest email or extract attachments.

The current architecture therefore starts with Salesforce records already present. This plan adds the missing inbound intake and validated record-creation layer. Existing evaluation and outbound approval behavior should be reused, not rewritten.

## 3. Scope

### In scope for the first release

- Client and provider inbound emails and attachments.
- Treatment-related documents (for example, appointment/treatment information).
- Medical-record and medical-bill documents.
- Matter and provider matching, duplicate detection, source traceability, retries, and failure handling.
- Automatic creation/update of validated records in the existing `Medical_Provider__c`, `Treatment_Event__c`, and `Records_Request__c` data model where the document supports those records.
- Case-manager review for uncertain or incomplete items.
- Triggering existing follow-up evaluation after successful writes.

### Explicitly out of scope for this intake slice

- Replacing the existing follow-up rule engine or recommendation workflow.
- Automatically sending email, SMS, fax, or other external communications.
- Bypassing case-manager approval, approval stamps, or existing send-service validation.
- Introducing Data 360 or committing to a specific document-extraction vendor before org licensing and capabilities are verified.
- Destructive changes to the existing `Matter__c` object or deploying sample object definitions over the target Personal Injury org.

## 4. Proposed flow

1. **Capture** inbound email metadata and attachment references through an org-supported inbound channel. Separately support Salesforce Files explicitly submitted/linked for intake if that is enabled in the first release.
2. **Preserve source** — retain the original message/document reference, sender, received time, file metadata, and source checksum where available. Avoid duplicating large binaries unless required by the chosen Salesforce channel.
3. **Stage** — create a durable intake work item with a unique idempotency key, processing status, source links, retry count, timestamps, and safe error summary.
4. **Classify** — identify treatment/appointment, provider information, medical records, bill, records-request evidence, unrelated/unsupported, or needs-review.
5. **Extract** — produce a typed candidate payload plus per-field confidence, source/page evidence where supported, and extraction-provider/version metadata. Do not invent missing values.
6. **Resolve** — match the candidate to a Matter and provider using configured identifiers and verified relationships. A name-only or otherwise ambiguous match is not sufficient for automatic linking.
7. **Validate and deduplicate** — enforce required-field rules, date/value sanity, allowed relationships, duplicate checks, and source-level idempotency before DML.
8. **Apply policy**:
   - High-confidence extraction + unambiguous match + valid required fields + no conflicting duplicate: automatically create/update the appropriate existing record.
   - Low confidence, uncertain Matter/provider match, missing required fields, conflicting documents, or possible duplicate: route to case-manager review with evidence and proposed changes.
   - Unsupported document: mark as unsupported/reviewable; do not create guessed records.
9. **Re-evaluate** — after successful record writes, enqueue or invoke the existing follow-up evaluation for affected Matter IDs, with recursion and duplicate-run safeguards.
10. **Audit and recover** — record status transitions and outcome; support safe retries without duplicate records and visible failures for operations staff.

## 5. Components to design before coding

Names below are conceptual; final names and fields should follow the repository's naming conventions and the actual target-org schema.

- **Inbound adapter:** an Apex Email Service or another supported Salesforce inbound-email pattern. Choose only after verifying deliverability, routing, attachment limits, execution context, and target-org configuration. Do not assume a mailbox is already connected.
- **Intake work/staging record:** durable status, source message/file reference, checksum/idempotency key, extracted payload or protected payload reference, confidence, matched Matter/provider, review status, attempt count, and safe error details. Decide whether to add a dedicated custom object or use an existing approved intake/review mechanism after inspecting repository metadata and org constraints.
- **Extractor interface/adapter:** isolates document extraction from record creation. Verify available Salesforce document AI/IDP licensing and supported APIs first; if no supported capability is configured, keep the adapter unconfigured and route work to review rather than pretending extraction is operational.
- **Matching and validation service:** deterministic matching rules, field-level validation, duplicate detection, confidence thresholds in Custom Metadata where appropriate, and explicit no-match/ambiguous outcomes.
- **Record application service:** narrowly scoped create/update operations for existing `Medical_Provider__c`, `Treatment_Event__c`, and `Records_Request__c` records. It must not create a new Matter automatically unless a separately approved policy is added.
- **Review queue:** case-manager view of source, extracted candidates, confidence, match evidence, validation errors, and approve/edit/reject actions. Review approval authorizes record application only; it does not authorize outbound communication.
- **Evaluation adapter:** call the existing evaluation entry point after committed record creation, using asynchronous processing where appropriate to control limits and avoid trigger recursion.

## 6. Confidence and review policy

Automatic creation must require all of the following:

- Extraction confidence meets a configurable threshold for the document class and all critical fields.
- Matter and provider resolution is unambiguous using verified identifiers/relationships.
- Required fields for the target object are present and pass validation.
- No conflicting source facts or unresolved duplicate candidate exists.
- The current user/system context has the required access and the operation is auditable.

Route to review if any gate fails. Confidence alone is never enough to auto-link a document to a Matter. Store the source and rationale for the decision so a reviewer can verify it.

## 7. Security and safety guardrails

- Preserve source references and least-privilege access to emails, attachments, and extracted medical information.
- Do not log full document contents, medical details, credentials, or sensitive payloads in debug logs or user-facing errors.
- Validate file type, size, and supported document classes; handle malformed and unsupported files safely.
- Make retries idempotent and prevent repeated email delivery from creating duplicate records.
- Respect sharing/FLS and existing security conventions; document any intentional system-mode DML and its authorization checks.
- Never let the intake agent send or approve external messages. Existing case-manager approval and approved-send services remain the only outbound path.
- Do not silently overwrite conflicting clinical or billing facts. Surface conflicts for review.

## 8. Implementation slices

### Slice A — Schema and platform capability discovery
- Inspect object/field metadata, required fields, lookups, validation rules, duplicate rules, sharing, permissions, and existing review UI.
- Verify target-org inbound email configuration, attachment constraints, supported file types, and document extraction licensing/API availability.
- Decide staging persistence and source-retention strategy.
- Deliverable: schema map and a short architecture decision record.

### Slice B — Staging and inbound capture
- Add the minimal intake metadata model and inbound adapter.
- Persist source references and idempotency keys.
- Add safe status transitions, failure recording, and retry boundaries.
- Do not perform business-record creation in the email handler itself; enqueue bounded processing.

### Slice C — Extraction and classification
- Add an extractor interface and configured adapter only for a verified platform capability.
- Normalize outputs into typed candidate structures with field confidence and evidence.
- Route extraction failures/unsupported documents to review.

### Slice D — Matching, validation, and idempotent record application
- Implement deterministic Matter/provider matching and required-field validation.
- Add duplicate/replay protection.
- Create/update only approved target objects and only when every auto-create gate passes.
- Route all uncertain cases to review.

### Slice E — Review queue and existing-engine integration
- Surface review candidates and decisions for case managers.
- After successful writes, invoke the existing evaluation service asynchronously.
- Ensure evaluation failures are retryable and do not roll back an already-committed intake record without an explicit transaction design.

### Slice F — Hardening and rollout
- Add unit tests, integration tests, permissions tests, operational metrics, and runbook.
- Use sandbox/UAT with representative redacted documents and duplicate/replayed emails.
- Roll out behind configuration/feature flags; monitor before broad enablement.

## 9. Test and acceptance criteria

- Supported inbound email with one or multiple attachments is captured and traceable to the source.
- Duplicate delivery/retry of the same source does not create duplicate business records.
- High-confidence, valid, unambiguous candidates create the expected existing records.
- Low-confidence extraction, ambiguous Matter/provider match, missing required fields, conflicting facts, and unsupported documents go to review without auto-creating business records.
- Review can correct fields/matching and apply the validated result with an audit trail.
- Successful record creation causes the affected Matter to be reevaluated; failed evaluation can be retried.
- Bulk and governor-limit tests cover multiple emails/attachments and avoid SOQL/DML in loops.
- Access tests ensure only authorized reviewers can see and apply sensitive intake records.
- Existing follow-up rules, recommendations, send approval, approval stamps, and outbound channel tests continue to pass.
- No tests or implementation require destructive replacement of existing target-org Matter metadata.
- Documentation clearly distinguishes features implemented in code from org setup/licensing still required.

## 10. Rollout and deployment notes

- Build and review this work on a feature branch; merge into `updated` only after review and tests.
- Do not deploy this plan as if it were executable Apex.
- Deploy new metadata/classes only after target-org schema compatibility is checked. Use the repository's Personal Injury deployment path and do not deploy sample Matter definitions over the established org.
- Keep inbound capture disabled until routing, permissions, retention, and extraction capability have been explicitly configured and tested.
- Keep all external sends behind the existing case-manager approval workflow.

## 11. Open decisions before implementation

1. Which inbound-email route is approved in the target org (Apex Email Service, existing Salesforce email capture, or another supported route)?
2. Are Salesforce Files linked to a Matter included in the first release, or should inbound email be the only initial source?
3. Which document extraction capability is licensed and available in the target org?
4. Which exact fields and duplicate rules define a valid provider, treatment event, and records request in the target org?
5. What confidence thresholds and reviewer permissions should be configured per document class?

These are discovery gates, not assumptions. The implementation should not claim end-to-end automatic extraction until the required platform capability and org configuration are confirmed.
