# Org & Repository Discovery

Status: **Repository discovery complete. Salesforce org discovery must still be run against the target org before production deployment.**

This document records the repository data contract and the deployment assumptions. The target org must be checked for conflicting objects/fields before deployment.

## 1. Repository discovery

The solution uses a `FollowUp*` Apex prefix and `Follow_Up_*` metadata prefix. The foundational `Treatment_Visits__c` object is now included under `prerequisites/` so an org that does not have it can receive the object and fields before the dependent automation is compiled.

## 2. Package model

| Directory | Purpose | Deployment |
|---|---|---|
| `prerequisites/` | Foundational Matter fields plus Treatment Visits, Records Request and Medical Provider objects/fields | Deploy when those solution-owned objects are missing. Do not deploy the sample Matter object over an existing Matter model. |
| `force-app/` | Follow-up solution: Apex, flows/UI, permission sets, Custom Metadata and supporting components | After prerequisites |
| `agentforce/` | Agentforce/Einstein adapters and related metadata | Only when enabled/licensed |

## 3. Assumed data contract

### Matter (`Matter__c`): existing org object
| Field | Type | Used for |
|---|---|---|
| `Name` | Text | Display / matter lookup |
| `Status__c` | Picklist | Open-matter filter |
| `Practice_Area__c` | Picklist | PI filter |
| `Client__c` | Lookup(Contact) | Client recipient / contact recency |
| `Case_Manager__c` | Lookup(User) | Assignment / escalation |
| `Sign_Up_Date__c` | Date | Treatment-gap anchor |
| `Demand_Sent_Date__c` | Date | KPI |

### Treatment Visits (`Treatment_Visits__c`): deployable solution object
| Field | Type | Used for |
|---|---|---|
| `Matter__c` | Lookup(Matter) | Parent Matter |
| `Provider__c` | Lookup(Medical Provider) | Treatment provider / missing-bills mapping |
| `Visit_Start__c` | DateTime | Last completed / next scheduled treatment |
| `Visit_End__c` | DateTime | Visit information |
| `Visit_Attended__c` | Checkbox | Determines completed treatment |
| `Visit_Type__c` | Picklist | Treatment visit classification |
| `Medical__c` | Checkbox | Identifies medical treatment visit |
| `Involved_Party__c` | Lookup(Contact) | Person involved in visit |

The Apex engine reads treatment history from `Treatment_Visits__c`. It does not use `Treatment_Event__c`.

### Records Request (`Records_Request__c`)
| Field | Type | Used for |
|---|---|---|
| `Matter__c` | Lookup/Master-Detail(Matter) | Parent |
| `Medical_Provider__c` | Lookup(Medical Provider) | Provider follow-ups |
| `Request_Type__c` | Picklist | Bills vs records |
| `Status__c` | Picklist | Outstanding state |
| `Requested_Date__c` | Date | Request age |
| `Received_Date__c` | Date | Completion |

### Medical Provider (`Medical_Provider__c`)
`Name`, `Email__c`, `Fax__c`, `Phone__c`.

## 4. Pre-deployment discovery

Before deployment, check whether the target org already contains objects with these exact API names:

```bash
sf sobject describe -s Matter__c -o pi-prod
sf sobject describe -s Treatment_Visits__c -o pi-prod
sf sobject describe -s Records_Request__c -o pi-prod
sf sobject describe -s Medical_Provider__c -o pi-prod
```

If `Treatment_Visits__c` does not exist, deploy the staged script. If it exists but has different field API names/types, do not deploy the sample definition over it; map the Apex implementation first.

Also check existing active Flows, Apex triggers and scheduled jobs to avoid duplicate follow-up automation.

## 5. Security

The `Follow_Up_Automation` permission set includes read/View All access to `Treatment_Visits__c` and read access to all Treatment Visit fields used by the evaluator. Assign it only to the automation user.

## 6. Duplicate-functionality risk

Check for existing treatment-gap, records-follow-up, missing-bill, stalled-matter and client-update automations. Disable or merge overlapping rules before enabling the nightly evaluator.
