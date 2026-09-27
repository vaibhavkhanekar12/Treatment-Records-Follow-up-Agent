# Org & Repository Discovery

Status: **Repository discovery complete. Salesforce org discovery was NOT possible from the build environment. It must be done before deployment (checklist below).**

This document records what was actually inspected, what could not be inspected, and the data contract the solution assumes. That contract has to be confirmed against the target org before anything is deployed.

---

## 1. Repository discovery (performed)

| Item | Finding |
|---|---|
| Repository | `Twopir-Support/Treatment-Records-Follow-up-Agent` |
| Commits on any branch | **None.** The repository was empty (no `main`, no other branches). |
| Existing Salesforce source | None. |
| Existing CI / DevOps config | None. |
| Existing naming conventions | None to inherit. The solution uses a `FollowUp*` Apex prefix and a `Follow_Up_*` metadata prefix so its components stay together. |

## 2. Salesforce org discovery (NOT performed: blocked)

The build environment had:

- no Salesforce CLI authentication (no `sf org list` targets, no auth URL, no JWT key),
- no Salesforce MCP/connector,
- no credentials supplied in the request.

So **nothing in this repository was retrieved from, validated against, or deployed to a Salesforce org.** Every object and field name below comes from the use-case specification (section 3.3 and its dependency on 3.2 "Treatment Events and Records Requests"). None of them come from the org.

To stay honest about this, the solution is split into three package directories:

| Directory | Purpose | Deploy to production? |
|---|---|---|
| `prerequisites/` | Minimal definitions of the objects this solution **reads** (Matter, Treatment Event, Records Request, Medical Provider). They exist only so a scratch/dev org can run the solution and its tests. | **No, if the org already has these objects.** Map them instead (section 4). |
| `force-app/` | The Follow-up solution itself: new object, fields, CMDT, Apex, LWC, Flows, permission sets, reports. | Yes, after the mapping is confirmed. |
| `agentforce/` | Agentforce topics/actions, Prompt Builder templates, and the Einstein-backed draft generator/classifier. | Yes, but only in an org with Agentforce + Einstein generative AI enabled. |

## 3. Assumed data contract (from the specification)

The Apex code references only the objects and fields below. Treat this as the contract to confirm.

### Matter (`Matter__c`): specified as existing
| Field | Type | Used for |
|---|---|---|
| `Name` | Text | Display, agent lookup by matter number/name |
| `Status__c` | Picklist | Open-matter filter (values configurable in `Follow_Up_Setting__mdt.Open_Matter_Statuses__c`) |
| `Practice_Area__c` | Picklist | PI filter (configurable `Practice_Area_Filter__c`) |
| `Client__c` | Lookup(Contact) | Client recipient, client-contact recency |
| `Case_Manager__c` | Lookup(User) | Assignment/escalation (falls back to `OwnerId`) |
| `Sign_Up_Date__c` | Date | Gap anchor when no treatment exists, KPI "sign-up to demand" |
| `Demand_Sent_Date__c` | Date | KPI only |

**Added by this solution** (`force-app`): `Stalled__c` (Checkbox), `Stalled_Since__c` (Date).

### Treatment Event (`Treatment_Event__c`): from 3.2
| Field | Type | Used for |
|---|---|---|
| `Matter__c` | Master-Detail/Lookup(Matter) | Parent |
| `Medical_Provider__c` | Lookup(Medical Provider) | Missing-bills check per provider |
| `Treatment_Date__c` | Date | Last-treatment date |
| `Status__c` | Picklist | Excluded statuses (e.g. Cancelled/No Show) configurable |

The solution **never reads** diagnosis, notes, CPT/ICD codes or any clinical field.

### Records Request (`Records_Request__c`): from 3.2
| Field | Type | Used for |
|---|---|---|
| `Matter__c` | Master-Detail/Lookup(Matter) | Parent |
| `Medical_Provider__c` | Lookup(Medical Provider) | Recipient of provider follow-ups |
| `Request_Type__c` | Picklist | Bills vs records (bill types configurable) |
| `Status__c` | Picklist | Outstanding statuses configurable |
| `Requested_Date__c` | Date | Request age |
| `Received_Date__c` | Date | Records activity |

The solution does **not** add fields to `Records_Request__c`. The follow-up count and last follow-up date are derived from `Follow_Up_Recommendation__c` history, so 3.2's object stays untouched.

### Medical Provider (`Medical_Provider__c`): specified as existing
`Name`, `Email__c`, `Fax__c`, `Phone__c`.

### Standard objects
`Contact` (client: `FirstName`, `Email`, `MobilePhone`, `Phone`), `Task` (activity log and client-contact recency), `User`, `OrgWideEmailAddress`.

`MessagingSession` and `EmailMessage` are **not read directly**. Enhanced Email and Salesforce Messaging both log `Task`s against the related record, which the recency logic already reads. Direct `MessagingSession` ingestion is an extension point (see `architecture.md`).

## 4. Pre-deployment discovery checklist (run against the target org)

Run these once an org is authorised (`sf org login web -a pi-prod`) and record the answers in this file.

```bash
# Data model
sf sobject describe -s Matter__c            -o pi-prod > discovery/Matter__c.json
sf sobject describe -s Treatment_Event__c   -o pi-prod > discovery/Treatment_Event__c.json
sf sobject describe -s Records_Request__c   -o pi-prod > discovery/Records_Request__c.json
sf sobject describe -s Medical_Provider__c  -o pi-prod > discovery/Medical_Provider__c.json
sf data query -o pi-prod -q "SELECT Status__c, COUNT(Id) FROM Matter__c GROUP BY Status__c"
sf data query -o pi-prod -q "SELECT Status__c, Request_Type__c, COUNT(Id) FROM Records_Request__c GROUP BY Status__c, Request_Type__c"

# Automation already present on these objects
sf data query -o pi-prod -t -q "SELECT ApiName, ProcessType, TriggerType, TriggerObjectOrEventLabel FROM FlowDefinitionView WHERE IsActive = true"
sf data query -o pi-prod -t -q "SELECT Name, TableEnumOrId, Status FROM ApexTrigger"
sf data query -o pi-prod -q "SELECT CronJobDetail.Name, NextFireTime FROM CronTrigger"

# Agentforce / Prompt Builder already present
sf project retrieve start -o pi-prod -m GenAiPlannerBundle -m GenAiPlugin -m GenAiFunction -m GenAiPromptTemplate -m Bot

# Security
sf data query -o pi-prod -q "SELECT Name, Label FROM PermissionSet WHERE IsOwnedByProfile = false"
sf data query -o pi-prod -q "SELECT SobjectType, InternalSharingModel FROM EntityDefinition WHERE QualifiedApiName IN ('Matter__c','Treatment_Event__c','Records_Request__c','Medical_Provider__c')" -t

# Integrations
sf data query -o pi-prod -t -q "SELECT DeveloperName, Endpoint FROM NamedCredential"
sf data query -o pi-prod -q "SELECT Address, DisplayName FROM OrgWideEmailAddress"
```

| Question | Expected by solution | Action if different |
|---|---|---|
| Do `Matter__c`, `Treatment_Event__c`, `Records_Request__c`, `Medical_Provider__c` exist? | Yes | If not, deploy `prerequisites/` (review first) |
| Field API names match section 3? | Yes | Rename references in `FollowUpMatterSelector` (all object/field access is centralised there and in the draft/grounding builders) |
| Matter open status values | `Open, Treating, Pre-Demand` (default) | Edit `Follow_Up_Setting.Default` CMDT record, no code change |
| Outstanding request statuses | `Requested, Partially Received` | Edit CMDT, no code change |
| Bill request types | `Bills, Records and Bills` | Edit CMDT, no code change |
| Existing treatment-gap / records follow-up Flows or scheduled jobs? | None | Deactivate or merge. Do **not** run two engines. |
| Existing Agentforce employee agent? | Unknown | Add the topics from `agentforce/` to it rather than creating a second agent |
| OWD of `Matter__c` | Private / Read | `Follow_Up_Recommendation__c` is Master-Detail and inherits it |
| Org-wide email address for provider/client mail | Unknown | Set `Follow_Up_Setting.Default.Org_Wide_Email_Address__c` |
| SMS (Salesforce Messaging / Twilio) or e-fax already integrated? | Unknown | Register an `IFollowUpChannel` implementation in CMDT |

## 5. Duplicate-functionality risk register

Because the org could not be inspected, these are the overlaps to check first:

1. **Records follow-up automation in 3.2.** If the Records Retrieval solution already chases providers, disable `Records_Follow_Up` / `Provider_Escalation` rules (`Active__c = false`) and keep only this solution's escalation and stalled-matter logic.
2. **Existing "stalled matter" or "days since last treatment" formula fields.** If they exist, the dashboards should use them, and the matching rule thresholds should be aligned.
3. **Existing client-update email alerts.** Disable the `Client_Status_Update` rule if a monthly update process already exists.
