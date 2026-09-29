# Treatment & Records Follow-up Agent deployment for the Personal Injury org.
#
# IMPORTANT: Do not deploy force-app directly for a target org that is missing the
# prerequisite objects/CMDT types. Salesforce deployments are transactions, and
# dependent package directories sometimes must be deployed sequentially.
#
# Usage:
#   .\scripts\deploy-personal-injury.ps1 -TargetOrg Personal_Injury_Org
#
# The target org is expected to already contain Matter__c. This script adds only the
# required Matter fields plus the supporting Treatment_Event__c, Records_Request__c,
# and Medical_Provider__c objects; it never deploys the sample Matter__c object definition.
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
    Write-Host 'Stage 1/4: deploying full sample prerequisite data model...' -ForegroundColor Cyan

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
    Write-Host 'Stage 1/4: deploying required Matter fields...' -ForegroundColor Cyan

    # Matter__c already exists in the target org. Deploy only the fields required
    # by this solution; never deploy the sample Matter__c object definition.
    $matterFields = @(
        'prerequisites/main/default/objects/Matter__c/fields/Case_Manager__c.field-meta.xml',
        'prerequisites/main/default/objects/Matter__c/fields/Client__c.field-meta.xml',
        'prerequisites/main/default/objects/Matter__c/fields/Demand_Sent_Date__c.field-meta.xml',
        'prerequisites/main/default/objects/Matter__c/fields/Practice_Area__c.field-meta.xml',
        'prerequisites/main/default/objects/Matter__c/fields/Sign_Up_Date__c.field-meta.xml',
        'prerequisites/main/default/objects/Matter__c/fields/Status__c.field-meta.xml'
    )

    $fieldArgs = @('project', 'deploy', 'start')
    foreach ($field in $matterFields) {
        $fieldArgs += @('--source-dir', $field)
    }
    $fieldArgs += @('--target-org', $TargetOrg, '--wait', $Wait)

    Invoke-SfDeploy `
        -Arguments $fieldArgs `
        -FailureMessage 'Required Matter field deployment failed. Main package deployment was not started.'

    Write-Host 'Stage 2/4: deploying Treatment Event, Records Request, and Medical Provider objects...' -ForegroundColor Cyan

    Invoke-SfDeploy `
        -Arguments @(
            'project', 'deploy', 'start',
            '--source-dir', 'prerequisites/main/default/objects/Medical_Provider__c',
            '--source-dir', 'prerequisites/main/default/objects/Records_Request__c',
            '--source-dir', 'prerequisites/main/default/objects/Treatment_Event__c',
            '--target-org', $TargetOrg,
            '--wait', $Wait
        ) `
        -FailureMessage 'Required supporting data object deployment failed. Main package deployment was not started.'
}
else {
    Write-Host 'Stage 1/4: skipping prerequisites (-SkipPrerequisites).' -ForegroundColor Yellow
}

Write-Host 'Stage 3/4: deploying Follow-up Custom Metadata Types...' -ForegroundColor Cyan

# Deploy CMDT definitions before their records and Apex consumers.
# In particular, FollowUpConfig references Response_Classification_Rule__mdt.
Invoke-SfDeploy `
    -Arguments @(
        'project', 'deploy', 'start',
        '--source-dir', 'force-app/main/default/objects/Follow_Up_Rule__mdt',
        '--source-dir', 'force-app/main/default/objects/Follow_Up_Setting__mdt',
        '--source-dir', 'force-app/main/default/objects/Response_Classification_Rule__mdt',
        '--target-org', $TargetOrg,
        '--wait', $Wait
    ) `
    -FailureMessage 'Custom Metadata Type deployment failed. Main package deployment was not started.'

Write-Host 'Stage 4/4: deploying dependent solution, Agentforce Apex, and analytics...' -ForegroundColor Cyan

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
