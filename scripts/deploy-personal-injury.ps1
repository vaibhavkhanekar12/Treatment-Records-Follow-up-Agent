# Treatment & Records Follow-up Agent deployment for the Personal Injury org.
#
# IMPORTANT: Do not deploy force-app directly for a target org that is missing the
# prerequisite objects/CMDT types. Salesforce deployments are transactions, and
# dependent package directories sometimes must be deployed sequentially.
#
# Usage:
#   .\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
#
# If the target org already has Medical_Provider__c and Records_Request__c with
# compatible fields, use -SkipPrerequisites.
#
# For a scratch/developer org missing the complete sample data model:
#   .\scripts\deploy-personal-injury.ps1 -TargetOrg <alias> -DeployFullPrerequisites

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetOrg,

    [int]$Wait = 30,

    [switch]$DeployFullPrerequisites,

    [switch]$SkipPrerequisites
)

$ErrorActionPreference = 'Stop'

if ($DeployFullPrerequisites -and $SkipPrerequisites) {
    throw 'Use either -DeployFullPrerequisites or -SkipPrerequisites, not both.'
}

function Invoke-SfDeploy {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & sf @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

if ($DeployFullPrerequisites) {
    Write-Host 'Stage 1/3: deploying full sample prerequisite data model...' -ForegroundColor Cyan

    Invoke-SfDeploy `
        -Arguments @(
            'project', 'deploy', 'start',
            '--source-dir', 'prerequisites',
            '--target-org', $TargetOrg,
            '--wait', $Wait
        ) `
        -FailureMessage 'Full prerequisite deployment failed. Main package deployment was not started.'
}
elseif (-not $SkipPrerequisites) {
    Write-Host 'Stage 1/3: deploying Medical_Provider__c and Records_Request__c...' -ForegroundColor Cyan

    Invoke-SfDeploy `
        -Arguments @(
            'project', 'deploy', 'start',
            '--metadata', 'CustomObject:Medical_Provider__c',
            '--metadata', 'CustomObject:Records_Request__c',
            '--target-org', $TargetOrg,
            '--wait', $Wait
        ) `
        -FailureMessage 'Required prerequisite object deployment failed. Main package deployment was not started.'
}
else {
    Write-Host 'Stage 1/3: skipping prerequisite objects (-SkipPrerequisites).' -ForegroundColor Yellow
}

Write-Host 'Stage 2/3: deploying Follow-up Custom Metadata Types...' -ForegroundColor Cyan

# Deploy CMDT definitions before their records and Apex consumers.
# In particular, FollowUpConfig references Response_Classification_Rule__mdt.
Invoke-SfDeploy `
    -Arguments @(
        'project', 'deploy', 'start',
        '--metadata', 'CustomObject:Follow_Up_Rule__mdt',
        '--metadata', 'CustomObject:Follow_Up_Setting__mdt',
        '--metadata', 'CustomObject:Response_Classification_Rule__mdt',
        '--target-org', $TargetOrg,
        '--wait', $Wait
    ) `
    -FailureMessage 'Custom Metadata Type deployment failed. Main package deployment was not started.'

Write-Host 'Stage 3/3: deploying dependent solution, Agentforce Apex, and analytics...' -ForegroundColor Cyan

Invoke-SfDeploy `
    -Arguments @(
        'project', 'deploy', 'start',
        '--source-dir', 'force-app',
        '--source-dir', 'agentforce',
        '--source-dir', 'analytics',
        '--target-org', $TargetOrg,
        '--wait', $Wait
    ) `
    -FailureMessage 'Main solution deployment failed. Review the Salesforce deployment errors above.'

Write-Host 'Treatment & Records Follow-up Agent deployment completed successfully.' -ForegroundColor Green
