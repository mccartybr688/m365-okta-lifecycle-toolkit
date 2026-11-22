#Requires -Version 7.0
<#
.SYNOPSIS
    Offboards departing users across Microsoft Entra ID, Exchange Online, Intune and Okta.

.DESCRIPTION
    For each row in the CSV, in this order:
      1. Saves the user's current group memberships to a CSV (so access can be
         restored or audited later).
      2. Blocks sign-in and resets the password to a random value.
      3. Revokes all refresh tokens and sign-in sessions.
      4. Converts the mailbox to shared, grants the manager access, sets an
         auto-reply and hides it from the address list (unless -SkipExchange).
      5. Removes the user from every assigned Entra group.
      6. Removes directly assigned licenses (after the mailbox is shared).
      7. Retires the user's Intune devices (only with -RetireDevices).
      8. Clears Okta sessions and deactivates the Okta user, which deprovisions
         Okta-assigned apps (unless -SkipOkta).

    Steps are logged one by one. If a step fails, the rest still run and the
    failure shows up in the log.

    Run with -DryRun or (or -WhatIf, which does the same thing) first. Dry run needs no tenant connection.

.EXAMPLE
    ./scripts/Invoke-Offboarding.ps1 -CsvPath ./samples/departures.csv -ConfigPath ./config/roles.example.json -DryRun

.EXAMPLE
    ./scripts/Invoke-Offboarding.ps1 -CsvPath ./departures.csv -ConfigPath ./config/roles.json -RetireDevices

.EXAMPLE
    ./scripts/Invoke-Offboarding.ps1 -CsvPath ./samples/departures.csv -ConfigPath ./config/roles.example.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$DryRun,
    [switch]$SkipOkta,
    [switch]$SkipExchange,
    [switch]$RetireDevices,
    [string]$LogFolder = (Join-Path $PSScriptRoot '..' 'logs')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'src' 'LifecycleToolkit.psm1') -Force

$DryRun = $DryRun -or $WhatIfPreference
Initialize-LifecycleRun -DryRun:$DryRun
$config = Get-LifecycleConfig -Path $ConfigPath
$defaults = $config.Defaults
$departures = Import-Csv -Path $CsvPath

if ($departures.Count -gt 0 -and -not ($departures[0].PSObject.Properties.Name -contains 'UserPrincipalName')) {
    throw "CSV is missing the 'UserPrincipalName' column."
}

if (-not $DryRun) {
    $scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.ReadWrite.All')
    if ($RetireDevices) {
        $scopes += 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All'
    }
    Connect-MgGraph -Scopes $scopes -NoWelcome
    if (-not $SkipExchange) { Connect-ExchangeOnline -ShowBanner:$false }
    if (-not $SkipOkta) { Connect-OktaApi }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$mode = if ($DryRun) { 'dryrun' } else { 'live' }
$membershipRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in $departures) {
    $upn = $row.UserPrincipalName.Trim()

    if ($DryRun) {
        $user = [pscustomobject]@{ Id = '<user-id>'; DisplayName = $upn.Split('@')[0] }
        $groups = @()
    }
    else {
        try {
            $user = Get-MgUser -UserId $upn -Property Id, DisplayName, AssignedLicenses
        }
        catch {
            Write-LifecycleLog -User $upn -Step 'Find user' -Status Failed -Detail $_.Exception.Message
            continue
        }
        $groups = @(Get-MgUserMemberOf -UserId $user.Id -All |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
    }

    # 1. Save memberships before anything is removed
    if ($DryRun) {
        Write-LifecycleLog -User $upn -Step 'Save group memberships' -Status Planned -Detail 'to memberships CSV'
    }
    else {
        foreach ($g in $groups) {
            $membershipRows.Add([pscustomobject]@{
                User      = $upn
                GroupId   = $g.Id
                GroupName = $g.AdditionalProperties['displayName']
                Dynamic   = [bool]($g.AdditionalProperties['groupTypes'] -contains 'DynamicMembership')
            })
        }
        Write-LifecycleLog -User $upn -Step 'Save group memberships' -Status Done -Detail "$($groups.Count) groups"
    }

    # 2. Block sign-in and reset the password
    Invoke-LifecycleStep -User $upn -Step 'Block sign-in' -Action {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
    } | Out-Null

    Invoke-LifecycleStep -User $upn -Step 'Reset password' -Detail '(random, not logged)' -Action {
        Update-MgUser -UserId $user.Id -PasswordProfile @{
            password                      = (New-TempPassword -Length 24)
            forceChangePasswordNextSignIn = $true
        }
    } | Out-Null

    # 3. Revoke sessions
    Invoke-LifecycleStep -User $upn -Step 'Revoke sign-in sessions' -Action {
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
    } | Out-Null

    # 4. Mailbox
    if ($SkipExchange) {
        Write-LifecycleLog -User $upn -Step 'Exchange Online' -Status Skipped -Detail '-SkipExchange'
    }
    else {
        Invoke-LifecycleStep -User $upn -Step 'Convert mailbox to shared' -Action {
            Set-Mailbox -Identity $upn -Type Shared
        } | Out-Null

        if ($row.ManagerUpn) {
            Invoke-LifecycleStep -User $upn -Step 'Grant manager mailbox access' -Detail $row.ManagerUpn -Action {
                Add-MailboxPermission -Identity $upn -User $row.ManagerUpn -AccessRights FullAccess -AutoMapping $true | Out-Null
            } | Out-Null
        }

        $reply = $defaults.OffboardingAutoReply `
            -replace '\{DisplayName\}', $user.DisplayName `
            -replace '\{CompanyName\}', $defaults.CompanyName `
            -replace '\{ManagerEmail\}', $(if ($row.ManagerUpn) { $row.ManagerUpn } else { 'the main office' })
        Invoke-LifecycleStep -User $upn -Step 'Set auto-reply' -Action {
            Set-MailboxAutoReplyConfiguration -Identity $upn -AutoReplyState Enabled -InternalMessage $reply -ExternalMessage $reply
        } | Out-Null

        if ($row.PSObject.Properties.Name -contains 'ForwardMailTo' -and $row.ForwardMailTo) {
            Invoke-LifecycleStep -User $upn -Step 'Forward mail' -Detail $row.ForwardMailTo -Action {
                Set-Mailbox -Identity $upn -ForwardingSmtpAddress "smtp:$($row.ForwardMailTo)" -DeliverToMailboxAndForward $true
            } | Out-Null
        }

        Invoke-LifecycleStep -User $upn -Step 'Hide from address list' -Action {
            Set-Mailbox -Identity $upn -HiddenFromAddressListsEnabled $true
        } | Out-Null
    }

    # 5. Remove group memberships (dynamic groups drop the user on their own)
    if ($DryRun) {
        Write-LifecycleLog -User $upn -Step 'Remove from all assigned Entra groups' -Status Planned
    }
    foreach ($g in $groups) {
        $name = $g.AdditionalProperties['displayName']
        if ($g.AdditionalProperties['groupTypes'] -contains 'DynamicMembership') {
            Write-LifecycleLog -User $upn -Step 'Remove from group' -Status Skipped -Detail "$name (dynamic)"
            continue
        }
        Invoke-LifecycleStep -User $upn -Step 'Remove from group' -Detail $name -Action {
            Remove-MgGroupMemberDirectoryObjectByRef -GroupId $g.Id -DirectoryObjectId $user.Id
        } | Out-Null
    }

    # 6. Direct licenses (group-based licenses go away with the groups above)
    if ($DryRun) {
        Write-LifecycleLog -User $upn -Step 'Remove direct licenses' -Status Planned -Detail 'after mailbox is shared'
    }
    elseif ($user.AssignedLicenses.Count -gt 0) {
        Invoke-LifecycleStep -User $upn -Step 'Remove direct licenses' -Detail "$($user.AssignedLicenses.Count) license(s)" -Action {
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses @($user.AssignedLicenses.SkuId)
        } | Out-Null
    }

    # 7. Intune devices
    if ($RetireDevices) {
        if ($DryRun) {
            Write-LifecycleLog -User $upn -Step 'Retire Intune devices' -Status Planned
        }
        else {
            $devices = @(Get-MgDeviceManagementManagedDevice -Filter "userPrincipalName eq '$upn'" -All)
            foreach ($d in $devices) {
                Invoke-LifecycleStep -User $upn -Step 'Retire Intune device' -Detail $d.DeviceName -Action {
                    Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $d.Id
                } | Out-Null
            }
            if ($devices.Count -eq 0) {
                Write-LifecycleLog -User $upn -Step 'Retire Intune devices' -Status Skipped -Detail 'no devices found'
            }
        }
    }

    # 8. Okta
    if ($SkipOkta) {
        Write-LifecycleLog -User $upn -Step 'Okta' -Status Skipped -Detail '-SkipOkta'
    }
    else {
        $encoded = [uri]::EscapeDataString($upn)
        Invoke-LifecycleStep -User $upn -Step 'Clear Okta sessions' -Action {
            Invoke-OktaApi -Method DELETE -Path "/api/v1/users/$encoded/sessions"
        } | Out-Null
        Invoke-LifecycleStep -User $upn -Step 'Deactivate Okta user' -Detail '(deprovisions assigned apps)' -Action {
            Invoke-OktaApi -Method POST -Path "/api/v1/users/$encoded/lifecycle/deactivate"
        } | Out-Null
    }
}

if ($membershipRows.Count -gt 0) {
    if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
    $membershipPath = Join-Path $LogFolder "offboarding-memberships-$stamp.csv"
    $membershipRows | Export-Csv -Path $membershipPath -Encoding utf8
    Write-Host "Group memberships saved to $membershipPath"
}

Save-LifecycleLog -Path (Join-Path $LogFolder "offboarding-$mode-$stamp.csv")

$failed = @(Get-LifecycleLog | Where-Object Status -eq 'Failed')
if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) step(s) failed. Check the log and finish those by hand."
}
