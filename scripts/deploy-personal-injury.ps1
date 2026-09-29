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

    Write-Host 'Stage 2/6: creating supporting custom objects...' -ForegroundColor Cyan

    # Create the object definitions first. Fields are deployed in a separate
    # transaction so lookup/reference fields never depend on an object that is
    # only being created in the same deployment.
    Invoke-SfDeploy `
        -Arguments @(
            'project', 'deploy', 'start',
            '--source-dir', 'prerequisites/main/default/objects/Medical_Provider__c/Medical_Provider__c.object-meta.xml',
            '--source-dir', 'prerequisites/main/default/objects/Records_Request__c/Records_Request__c.object-meta.xml',
            '--source-dir', 'prerequisites/main/default/objects/Treatment_Event__c/Treatment_Event__c.object-meta.xml',
            '--target-org', $TargetOrg,
            '--wait', $Wait
        ) `
        -FailureMessage 'Supporting custom object definition deployment failed. Main package deployment was not started.'

    Write-Host 'Stage 3/6: deploying supporting custom object fields...' -ForegroundColor Cyan

    Invoke-SfDeploy `
        -Arguments @(
            'project', 'deploy', 'start',
            '--source-dir', 'prerequisites/main/default/objects/Medical_Provider__c/fields',
            '--source-dir', 'prerequisites/main/default/objects/Records_Request__c/fields',
            '--source-dir', 'prerequisites/main/default/objects/Treatment_Event__c/fields',
            '--target-org', $TargetOrg,
            '--wait', $Wait
        ) `
        -FailureMessage 'Supporting custom object field deployment failed. Main package deployment was not started.'
}
else {
    Write-Host 'Stage 1/4: skipping prerequisites (-SkipPrerequisites).' -ForegroundColor Yellow
}

Write-Host 'Stage 4/6: creating Follow-up Custom Metadata Types...' -ForegroundColor Cyan

# Deploy CMDT object definitions first. Salesforce must have the
# Custom Metadata Type entity before its CustomField components can resolve it.
Invoke-SfDeploy `
    -Arguments @(
        'project', 'deploy', 'start',
        '--source-dir', 'force-app/main/default/objects/Follow_Up_Rule__mdt/Follow_Up_Rule__mdt.object-meta.xml',
        '--source-dir', 'force-app/main/default/objects/Follow_Up_Setting__mdt/Follow_Up_Setting__mdt.object-meta.xml',
        '--source-dir', 'force-app/main/default/objects/Response_Classification_Rule__mdt/Response_Classification_Rule__mdt.object-meta.xml',
        '--target-org', $TargetOrg,
        '--wait', $Wait
    ) `
    -FailureMessage 'Custom Metadata Type definition deployment failed. Main package deployment was not started.'

Write-Host 'Stage 5/6: deploying Custom Metadata Type fields...' -ForegroundColor Cyan

Invoke-SfDeploy `
    -Arguments @(
        'project', 'deploy', 'start',
        '--source-dir', 'force-app/main/default/objects/Follow_Up_Rule__mdt/fields',
        '--source-dir', 'force-app/main/default/objects/Follow_Up_Setting__mdt/fields',
        '--source-dir', 'force-app/main/default/objects/Response_Classification_Rule__mdt/fields',
        '--target-org', $TargetOrg,
        '--wait', $Wait
    ) `
    -FailureMessage 'Custom Metadata Type field deployment failed. Main package deployment was not started.'

Write-Host 'Stage 5/6: deploying Custom Metadata Type records...' -ForegroundColor Cyan

Invoke-SfDeploy `
    -Arguments @(
        'project', 'deploy', 'start',
        '--source-dir', 'force-app/main/default/customMetadata',
        '--target-org', $TargetOrg,
        '--wait', $Wait
    ) `
    -FailureMessage 'Custom Metadata record deployment failed. Main package deployment was not started.'

Write-Host 'Stage 6/6: deploying dependent solution, Agentforce Apex, and analytics...' -ForegroundColor Cyan

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
