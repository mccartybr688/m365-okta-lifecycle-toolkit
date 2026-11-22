#Requires -Version 7.0
<#
.SYNOPSIS
    Onboards new hires from a CSV into Microsoft Entra ID and Okta.

.DESCRIPTION
    For each row in the CSV:
      1. Looks up the role in the config to get groups and licenses.
      2. Builds a UPN (firstname.lastname@domain) and adds a number if it is taken.
      3. Creates the Entra ID user with a random temporary password.
      4. Sets the manager.
      5. Adds the user to the role's Entra groups (group-based licensing does the rest).
      6. Assigns any direct licenses listed for the role.
      7. Creates the Okta user and adds the role's Okta groups (unless -SkipOkta).

    Run with -DryRun or (or -WhatIf, which does the same thing) first. Dry run needs no tenant connection and prints
    every step it would take.

.EXAMPLE
    ./scripts/Invoke-Onboarding.ps1 -CsvPath ./samples/new-hires.csv -ConfigPath ./config/roles.example.json -DryRun

.EXAMPLE
    ./scripts/Invoke-Onboarding.ps1 -CsvPath ./new-hires.csv -ConfigPath ./config/roles.json -SkipOkta

.EXAMPLE
    ./scripts/Invoke-Onboarding.ps1 -CsvPath ./samples/new-hires.csv -ConfigPath ./config/roles.example.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$DryRun,
    [switch]$SkipOkta,
    [string]$LogFolder = (Join-Path $PSScriptRoot '..' 'logs')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'LifecycleToolkit.psm1') -Force

$DryRun = $DryRun -or $WhatIfPreference
Initialize-LifecycleRun -DryRun:$DryRun
$config = Get-LifecycleConfig -Path $ConfigPath
$defaults = $config.Defaults
$hires = Import-Csv -Path $CsvPath

$required = 'FirstName', 'LastName', 'Role'
foreach ($col in $required) {
    if ($hires.Count -gt 0 -and -not ($hires[0].PSObject.Properties.Name -contains $col)) {
        throw "CSV is missing the '$col' column."
    }
}

if (-not $DryRun) {
    Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All' -NoWelcome
    if (-not $SkipOkta) { Connect-OktaApi }
}

# Cache lookups so 20 new hires do not mean 20 searches for the same group.
$groupIdCache = @{}
function Get-EntraGroupId([string]$Name) {
    if (-not $groupIdCache.ContainsKey($Name)) {
        $escaped = $Name.Replace("'", "''")
        $group = Get-MgGroup -Filter "displayName eq '$escaped'" -Top 2
        if (@($group).Count -ne 1) { throw "Expected exactly one Entra group named '$Name'." }
        $groupIdCache[$Name] = $group.Id
    }
    $groupIdCache[$Name]
}

$skuIdCache = $null
function Get-SkuId([string]$PartNumber) {
    if (-not $script:skuIdCache) {
        $script:skuIdCache = @{}
        Get-MgSubscribedSku | ForEach-Object { $script:skuIdCache[$_.SkuPartNumber] = $_.SkuId }
    }
    if (-not $script:skuIdCache.ContainsKey($PartNumber)) { throw "License SKU '$PartNumber' is not in this tenant." }
    $script:skuIdCache[$PartNumber]
}

$handoff = [System.Collections.Generic.List[object]]::new()

foreach ($hire in $hires) {
    $label = "$($hire.FirstName) $($hire.LastName)"
    try {
        $assignment = Get-RoleAssignment -Config $config -Role $hire.Role
    }
    catch {
        Write-LifecycleLog -User $label -Step 'Resolve role' -Status Failed -Detail $_.Exception.Message
        continue
    }

    $exists = if ($DryRun) {
        { param($upn) $false }
    } else {
        { param($upn) [bool](Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue) }
    }
    $upn = New-UpnFromName -FirstName $hire.FirstName -LastName $hire.LastName -Domain $defaults.Domain -ExistsCheck $exists
    $mailNickname = $upn.Split('@')[0]
    $displayName = "$($hire.FirstName) $($hire.LastName)"
    $tempPassword = New-TempPassword

    # 1. Create the Entra ID user
    $newUser = Invoke-LifecycleStep -User $upn -Step 'Create Entra ID user' -Detail "($($assignment.Role), $($hire.Department))" -Action {
        New-MgUser -BodyParameter @{
            accountEnabled    = $true
            displayName       = $displayName
            givenName         = $hire.FirstName
            surname           = $hire.LastName
            userPrincipalName = $upn
            mailNickname      = $mailNickname
            department        = $hire.Department
            jobTitle          = $hire.JobTitle
            companyName       = $defaults.CompanyName
            usageLocation     = $defaults.UsageLocation
            passwordProfile   = @{
                password                      = $tempPassword
                forceChangePasswordNextSignIn = [bool]$defaults.ForceChangePasswordNextSignIn
            }
        }
    }
    if (-not $DryRun -and -not $newUser) { continue }   # creation failed; already logged
    $userId = if ($DryRun) { '<new-user-id>' } else { $newUser.Id }

    # 2. Manager
    if ($hire.PSObject.Properties.Name -contains 'ManagerUpn' -and $hire.ManagerUpn) {
        Invoke-LifecycleStep -User $upn -Step 'Set manager' -Detail $hire.ManagerUpn -Action {
            $manager = Get-MgUser -UserId $hire.ManagerUpn
            Set-MgUserManagerByRef -UserId $userId -BodyParameter @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
            }
        } | Out-Null
    }

    # 3. Entra groups (includes license groups for group-based licensing)
    foreach ($groupName in $assignment.EntraGroups) {
        Invoke-LifecycleStep -User $upn -Step 'Add to Entra group' -Detail $groupName -Action {
            New-MgGroupMember -GroupId (Get-EntraGroupId $groupName) -DirectoryObjectId $userId
        } | Out-Null
    }

    # 4. Direct licenses, only for roles that list them
    foreach ($sku in $assignment.LicenseSkus) {
        Invoke-LifecycleStep -User $upn -Step 'Assign license' -Detail $sku -Action {
            Set-MgUserLicense -UserId $userId -AddLicenses @(@{ SkuId = (Get-SkuId $sku) }) -RemoveLicenses @()
        } | Out-Null
    }

    # 5. Okta
    if ($SkipOkta) {
        Write-LifecycleLog -User $upn -Step 'Okta' -Status Skipped -Detail '-SkipOkta'
    }
    else {
        $oktaUser = Invoke-LifecycleStep -User $upn -Step 'Create Okta user' -Action {
            Invoke-OktaApi -Method POST -Path '/api/v1/users?activate=true' -Body @{
                profile = @{
                    firstName  = $hire.FirstName
                    lastName   = $hire.LastName
                    email      = $upn
                    login      = $upn
                    department = $hire.Department
                    title      = $hire.JobTitle
                }
            }
        }
        $oktaId = if ($DryRun) { '<okta-user-id>' } elseif ($oktaUser) { $oktaUser.id } else { $null }
        if ($oktaId) {
            foreach ($groupName in $assignment.OktaGroups) {
                Invoke-LifecycleStep -User $upn -Step 'Add to Okta group' -Detail $groupName -Action {
                    $gid = Get-OktaGroupId -Name $groupName
                    Invoke-OktaApi -Method PUT -Path "/api/v1/groups/$gid/users/$oktaId"
                } | Out-Null
            }
        }
    }

    $handoff.Add([pscustomobject]@{
        DisplayName       = $displayName
        UserPrincipalName = $upn
        StartDate         = $hire.StartDate
        Manager           = $hire.ManagerUpn
        TempPassword      = if ($DryRun) { '(not created in dry run)' } else { $tempPassword }
    })
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$mode = if ($DryRun) { 'dryrun' } else { 'live' }
Save-LifecycleLog -Path (Join-Path $LogFolder "onboarding-$mode-$stamp.csv")

# Temporary passwords are shown once on screen and never written to the log.
Write-Host ''
Write-Host 'Hand-off summary (share each temporary password with the manager through a secure channel):' -ForegroundColor Yellow
$handoff | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
