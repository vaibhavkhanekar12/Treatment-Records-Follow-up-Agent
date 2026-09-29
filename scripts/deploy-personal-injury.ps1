# Treatment & Records Follow-up Agent deployment for the Personal Injury org.
#
# Deployment is intentionally staged because Salesforce compiles/deploys metadata
# dependencies in a transaction. Follow_Up_Recommendation__c and Apex reference
# Medical_Provider__c / Records_Request__c, while Apex also references
# Response_Classification_Rule__mdt. Deploy those dependencies first.
#
# Usage:
#   .\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
#
# If the target org already has the two prerequisite objects with the exact API names,
# use -SkipPrerequisites. Do NOT deploy the sample prerequisite model over an existing
# firm data model.
#
# For a scratch/developer org that is missing the complete sample data model:
#   .\scripts\deploy-personal-injury.ps1 -TargetOrg <alias> -DeployFullPrerequisites

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetOrg,

    [int]$Wait = 30,

    # Use only for a scratch/developer org that is missing the complete sample
    # Matter/Treatment Event/Records Request/Medical Provider data model.
    [switch]$DeployFullPrerequisites,

    # Use when Medical_Provider__c and Records_Request__c already exist in the target
    # org with the exact API names and compatible fields.
    [switch]$SkipPrerequisites
)

$ErrorActionPreference = 'Stop'

if ($DeployFullPrerequisites -and $SkipPrerequisites) {
    throw "Use either -DeployFullPrerequisites or -SkipPrerequisites, not both."
}

if ($DeployFullPrerequisites) {
    Write-Host "Deploying full sample prerequisite data model to $TargetOrg..." -ForegroundColor Cyan
    sf project deploy start --source-dir prerequisites --target-org $TargetOrg --wait $Wait

    if ($LASTEXITCODE -ne 0) {
        throw "Full prerequisite deployment failed. Main package deployment was not started."
    }
}
elseif (-not $SkipPrerequisites) {
    Write-Host "Deploying required Medical Provider and Records Request dependencies..." -ForegroundColor Cyan

    # Deploy the exact prerequisite source folders instead of relying on package-directory
    # ordering. This creates the lookup target objects before the main package is compiled.
    sf project deploy start --source-dir prerequisites/main/default/objects/Medical_Provider__c --source-dir prerequisites/main/default/objects/Records_Request__c --target-org $TargetOrg --wait $Wait

    if ($LASTEXITCODE -ne 0) {
        throw "Required prerequisite objects failed to deploy. Main package deployment was not started."
    }
}
else {
    Write-Host "Skipping prerequisite object deployment because -SkipPrerequisites was supplied." -ForegroundColor Yellow
}

Write-Host "Deploying Custom Metadata Types before their records and Apex consumers..." -ForegroundColor Cyan

# These are Custom Metadata Types. Deploy the type definitions first so Apex and
# custom metadata records can resolve Response_Classification_Rule__mdt fields.
sf project deploy start --source-dir force-app/main/default/objects/Follow_Up_Rule__mdt --source-dir force-app/main/default/objects/Follow_Up_Setting__mdt --source-dir force-app/main/default/objects/Response_Classification_Rule__mdt --target-org $TargetOrg --wait $Wait

if ($LASTEXITCODE -ne 0) {
    throw "Custom Metadata Type deployment failed. Main package deployment was not started."
}

Write-Host "Deploying main solution package..." -ForegroundColor Cyan

# The prerequisite objects and CMDT definitions now exist, so dependent lookups,
# Apex classes/tests, layouts, Agentforce metadata, and analytics can compile.
sf project deploy start --source-dir force-app --source-dir agentforce --source-dir analytics --target-org $TargetOrg --wait $Wait

if ($LASTEXITCODE -ne 0) {
    throw "Main package deployment failed. Review the Salesforce deployment errors above."
}

Write-Host "Treatment & Records Follow-up Agent deployment completed successfully." -ForegroundColor Green
