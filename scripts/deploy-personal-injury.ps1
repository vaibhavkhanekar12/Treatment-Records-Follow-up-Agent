# Treatment & Records Follow-up Agent deployment for the Personal Injury org.
#
# This script intentionally deploys prerequisite metadata first. The main package
# contains lookups and Apex that reference Medical_Provider__c and Records_Request__c,
# so deploying everything in one transaction can produce cascading "type not found"
# errors when those objects do not already exist in the target org.
#
# Usage:
#   .\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
#
# If the target org already contains the prerequisite objects, skip this script's
# prerequisite step and deploy only the main package using the command in docs/deployment.md.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetOrg,
    [int]$Wait = 30,

    # Use this only for a scratch/developer org that is missing the entire sample
    # Matter/Treatment Event/Records Request/Medical Provider data model.
    [switch]$DeployFullPrerequisites
)

$ErrorActionPreference = 'Stop'

if ($DeployFullPrerequisites) {
    Write-Host "Deploying full sample prerequisite data model to $TargetOrg..." -ForegroundColor Cyan
    sf project deploy start --source-dir prerequisites --target-org $TargetOrg --wait $Wait
} else {
    # The current Personal Injury org errors are caused by these two missing objects.
    # Deploy only these dependencies so an existing Matter/Treatment Event model is
    # not overwritten by the sample prerequisite package.
    Write-Host "Deploying missing Medical Provider and Records Request dependencies..." -ForegroundColor Cyan
    sf project deploy start --metadata CustomObject:Medical_Provider__c --metadata CustomObject:Records_Request__c --target-org $TargetOrg --wait $Wait
}
if ($LASTEXITCODE -ne 0) {
    throw "Prerequisite dependency deployment failed. Main package deployment was not started."
}

Write-Host "Prerequisites deployed successfully. Deploying solution configuration types..." -ForegroundColor Cyan
# Create/update the Custom Metadata Types before their records and Apex consumers.
# This removes the "Custom metadata type ... is not available" cascade when the target
# org is being initialized from an empty configuration state.
sf project deploy start --metadata CustomObject:Follow_Up_Rule__mdt --metadata CustomObject:Follow_Up_Setting__mdt --metadata CustomObject:Response_Classification_Rule__mdt --target-org $TargetOrg --wait $Wait
if ($LASTEXITCODE -ne 0) {
    throw "Solution configuration metadata deployment failed. Main package deployment was not started."
}

Write-Host "Configuration types deployed successfully. Deploying main package..." -ForegroundColor Cyan
sf project deploy start --source-dir force-app --source-dir agentforce --source-dir analytics --target-org $TargetOrg --wait $Wait
if ($LASTEXITCODE -ne 0) {
    throw "Main package deployment failed. Review the Salesforce deployment errors above."
}

Write-Host "Treatment & Records Follow-up Agent deployment completed successfully." -ForegroundColor Green
