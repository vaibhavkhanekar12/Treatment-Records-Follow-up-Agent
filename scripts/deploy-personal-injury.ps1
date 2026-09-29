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
    [int]$Wait = 30
)

$ErrorActionPreference = 'Stop'

Write-Host "Deploying prerequisite metadata to $TargetOrg..." -ForegroundColor Cyan
sf project deploy start --source-dir prerequisites --target-org $TargetOrg --wait $Wait
if ($LASTEXITCODE -ne 0) {
    throw "Prerequisite deployment failed. Main package deployment was not started."
}

Write-Host "Prerequisites deployed successfully. Deploying main package..." -ForegroundColor Cyan
sf project deploy start --source-dir force-app --source-dir agentforce --source-dir analytics --target-org $TargetOrg --wait $Wait
if ($LASTEXITCODE -ne 0) {
    throw "Main package deployment failed. Review the Salesforce deployment errors above."
}

Write-Host "Treatment & Records Follow-up Agent deployment completed successfully." -ForegroundColor Green
