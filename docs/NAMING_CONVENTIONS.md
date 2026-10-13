# Salesforce Naming Conventions and Metadata Audit

**Scope:** Repository-wide conventions, with an explicit review of the automatic-intake additions on `feature/automatic-intake-implementation-plan`.

## Convention to follow in this repository

This repository already uses two intentional naming styles: Apex types use concatenated PascalCase, while Salesforce object/field API names use underscores between words. Do not apply one style to both.

| Component | Repository convention | Example |
|---|---|---|
| Apex class | PascalCase, no underscores in type name | `FollowUpEvaluationService`, `AutomaticIntakeService` |
| Apex test class | Tested class name + `Test` | `AutomaticIntakeServiceTest` |
| Apex interface | `I` prefix + descriptive PascalCase | `IFollowUpDraftGenerator`, `IAutomaticIntakeExtractor` |
| Custom object API name | PascalCase words separated by underscores + `__c` | `Follow_Up_Recommendation__c`, `Automatic_Intake__c` |
| Custom Metadata Type | Underscored API name + `__mdt` | `Follow_Up_Setting__mdt`, `Automatic_Intake_Extraction_Setting__mdt` |
| Custom field API name | Underscored words + `__c` | `Matched_Matter__c`, `Extraction_Confidence__c` |
| Custom relationship traversal in SOQL | Relationship API name ends in `__r` | `Matter__r.Name` |
| Apex metadata companion | Exact Apex basename + `.cls-meta.xml` | `AutomaticIntakeService.cls-meta.xml` |
| LWC bundle | camelCase directory and matching HTML/JS basename | `automaticIntakeReview/automaticIntakeReview.js` |
| Custom Metadata record file | Type name without `__mdt`, dot, record DeveloperName, `.md-meta.xml` | `Automatic_Intake_Extraction_Setting.Default.md-meta.xml` |
| Permission set file | API name + `.permissionset-meta.xml` | `Automatic_Intake_Reviewer.permissionset-meta.xml` |

Salesforce suffixes are semantic, not stylistic: custom objects/fields use `__c`; Custom Metadata Types use `__mdt`; custom relationship traversal uses `__r`. Do not remove or interchange these suffixes. See the [Salesforce Object/Field API name guidance](https://trailhead.salesforce.com/content/learn/modules/apex_database/apex_database_sobjects) and [Custom Metadata Types guidance](https://trailhead.salesforce.com/content/learn/modules/custom_metadata_types_dec/cmt_overview).

## Audit findings

The following names in the automatic-intake change set conform to the patterns above:

- `AutomaticIntakeEmailService.cls` and its `.cls-meta.xml` companion use the same basename.
- `AutomaticIntakeProcessingQueueable.cls`, `AutomaticIntakeService.cls`, and `AutomaticIntakeReviewController.cls` use PascalCase without underscores.
- `AutomaticIntakeEmailServiceTest.cls` and `AutomaticIntakeServiceTest.cls` follow the repository's `ClassNameTest` pattern.
- `IAutomaticIntakeExtractor.cls` follows the existing interface-prefix pattern.
- `Automatic_Intake__c` and `Automatic_Intake_Extraction_Setting__mdt` use the correct Salesforce suffixes.
- The extraction setting record filename `Automatic_Intake_Extraction_Setting.Default.md-meta.xml` correctly omits `__mdt` from the record filename and uses the `Default` DeveloperName.
- The `automaticIntakeReview` LWC bundle uses the same camelCase basename for its JS and HTML files.
- `Automatic_Intake_Reviewer.permissionset-meta.xml` follows the permission-set metadata filename pattern.

### Confirmed inconsistency corrected

The new `docs/CONFIGURATION_GUIDE.md` contained doubled backslashes in its PowerShell command (`.\\scripts\\deploy-personal-injury.ps1`). The command has been corrected to the normal PowerShell relative path:

```powershell
.\scripts\deploy-personal-injury.ps1 -TargetOrg pi-uat
```

## Important API-name rule

Do **not** rename existing object or field API names merely to make them visually prettier. Those names are referenced by Apex, SOQL, Flow, permissions, layouts, reports and potentially installed orgs. An API rename requires a dependency review and a migration plan. The current established model includes names such as `Follow_Up_Recommendation__c`; new metadata should be consistent with that established model unless the project deliberately approves a breaking schema change.

## Review checklist for future metadata

- [ ] The file basename matches the API name declared inside the metadata.
- [ ] Every Apex class has a matching `.cls-meta.xml` file.
- [ ] Every LWC bundle's HTML/JS names match its directory name.
- [ ] Custom objects/fields use `__c`, Custom Metadata Types use `__mdt`, and relationship traversal uses `__r`.
- [ ] Custom Metadata record filenames use `TypeWithout__mdt.RecordDeveloperName.md-meta.xml`.
- [ ] Apex references match actual field/object API names in the target org; labels are not substituted for API names.
- [ ] Existing `Matter__c` and other target-org objects are mapped before deployment; sample prerequisite metadata is not blindly deployed over an established schema.
- [ ] CI, metadata validation and Apex tests are run after changes. Naming review alone does not prove compilation or deployment success.
