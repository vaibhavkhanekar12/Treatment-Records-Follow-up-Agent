# Org & Repository Discovery

Status: **Repository discovery complete. Salesforce org discovery was NOT possible from the build environment. The target org should still be validated before production deployment.**

This document records the repository data contract and the existing Treatment Visits object used by the automation.

---

## 1. Repository discovery

| Item | Finding |
|---|---|
| Repository | `vaibhavkhanekar12/Treatment-Records-Follow-up-Agent` |
| Automation source | `force-app/` |
| Existing Treatment object used by automation | `Treatment_Visits__c` |
| Follow-up solution prefix | `FollowUp*` Apex and `Follow_Up_*` metadata |

## 2. Salesforce org discovery

The build environment does not have Salesforce CLI authentication to the target org, so deployment tests cannot be executed here. The Treatment Visits object and field API names used by the final branch are the following contract and should be confirmed in Object Manager before deployment.

## 3. Data contract

### Matter (`Matter__c`)

| Field | Used for |
|---|---|
| `Name` | Display / matter lookup |
| `Status__c` | Open-matter filter |
| `Practice_Area__c` | Personal Injury filter |
| `Client__c` | Client recipient and contact history |
| `Case_Manager__c` | Assignment and escalation |
| `Sign_Up_Date__c` | Treatment-gap fallback anchor |
| `Stalled__c` | Automation-owned stalled flag |
| `Stalled_Since__c` | Automation-owned stalled date |

### Existing Treatment Visits (`Treatment_Visits__c`)

The automation **does not create or replace this object**. It reads the existing Treatment Visit records already present in the org.

| Treatment Visit field | API Name used by automation | Used for |
|---|---|---|
| Matter | `Matter__c` | Parent Matter |
| Provider | `Provider__c` | Treatment provider / missing-bills grouping |
| Visit Start | `Visit_Start__c` | Last completed treatment and next scheduled visit |
| Visit End | `Visit_End__c` | Relevant visit-change detection |
| Visit Attended | `Visit_Attended__c` | Determines whether a past visit counts as completed treatment |
| Visit Type | `Visit_Type__c` | Relevant visit-change detection |
| Medical | `Medical__c` | Existing relationship; not used by the rule engine |
| Involved Party | `Involved_Party__c` | Existing relationship; not used by the rule engine |

The automation does **not** read diagnosis, notes, CPT/ICD codes, or other clinical fields.

### Records Request (`Records_Request__c`)

| Field | Used for |
|---|---|
| `Matter__c` | Parent Matter |
| `Medical_Provider__c` | Provider follow-ups |
| `Request_Type__c` | Bills vs records |
| `Status__c` | Outstanding status |
| `Requested_Date__c` | Request age |
| `Received_Date__c` | Records activity |

### Medical Provider (`Medical_Provider__c`)

`Name`, `Email__c`, `Fax__c`, `Phone__c`, and `Matter__c` are used for provider resolution and delivery.

## 4. Pre-deployment discovery checklist

Run these against the target org after authentication:

```bash
sf sobject describe -s Matter__c -o pi-prod > discovery/Matter__c.json
sf sobject describe -s Treatment_Visits__c -o pi-prod > discovery/Treatment_Visits__c.json
sf sobject describe -s Records_Request__c -o pi-prod > discovery/Records_Request__c.json
sf sobject describe -s Medical_Provider__c -o pi-prod > discovery/Medical_Provider__c.json

sf data query -o pi-prod -q "SELECT Status__c, COUNT(Id) FROM Matter__c GROUP BY Status__c"
sf data query -o pi-prod -q "SELECT Status__c, Request_Type__c, COUNT(Id) FROM Records_Request__c GROUP BY Status__c, Request_Type__c"

sf data query -o pi-prod -t -q "SELECT Name, TableEnumOrId, Status FROM ApexTrigger"
sf data query -o pi-prod -q "SELECT CronJobDetail.Name, NextFireTime FROM CronTrigger"
```

### Deployment checks

| Check | Expected |
|---|---|
| `Treatment_Visits__c` exists | Yes |
| Treatment Visit Matter field | `Matter__c` |
| Treatment Visit Provider field | `Provider__c` |
| Treatment Visit start field | `Visit_Start__c` |
| Treatment Visit attended field | `Visit_Attended__c` |
| Treatment Visit end field | `Visit_End__c` |
| Treatment Visit type field | `Visit_Type__c` |
| Existing Treatment Visit trigger | Check for conflicts before deployment |
| Existing treatment-gap automation | Deactivate/merge duplicate automation before enabling this trigger |

The final branch intentionally does **not** deploy a sample Treatment Visits object. It uses the existing org object shown in the target configuration.
