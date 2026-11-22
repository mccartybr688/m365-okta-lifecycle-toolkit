#Requires -Version 7.0
<#
    Lightweight tests for the helper functions and both dry runs.
    No tenant or extra modules needed:  pwsh ./tests/Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src' 'LifecycleToolkit.psm1') -Force

$script:passed = 0
$script:failed = 0
function Test-That([string]$Name, [scriptblock]$Check) {
    try {
        $ok = & $Check
        if ($ok) { $script:passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
        else     { $script:failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
    }
    catch {
        $script:failed++
        Write-Host "  FAIL  $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host 'UPN building'
Test-That 'simple name' { (New-UpnFromName -FirstName 'Avery' -LastName 'Johnson' -Domain 'contoso.com') -eq 'avery.johnson@contoso.com' }
Test-That 'accents and apostrophes are removed' { (New-UpnFromName -FirstName 'José' -LastName "O'Brien" -Domain 'contoso.com') -eq 'jose.obrien@contoso.com' }
Test-That 'spaces in last name are removed' { (New-UpnFromName -FirstName 'Ana' -LastName 'De La Cruz' -Domain 'contoso.com') -eq 'ana.delacruz@contoso.com' }
Test-That 'hyphenated last name is kept' { (New-UpnFromName -FirstName 'Lee' -LastName 'Smith-Jones' -Domain 'contoso.com') -eq 'lee.smith-jones@contoso.com' }
Test-That 'collision adds a number' {
    $taken = @('avery.johnson@contoso.com', 'avery.johnson2@contoso.com')
    (New-UpnFromName -FirstName 'Avery' -LastName 'Johnson' -Domain 'contoso.com' -ExistsCheck { param($u) $taken -contains $u }) -eq 'avery.johnson3@contoso.com'
}
Test-That 'empty name throws' {
    try { New-UpnFromName -FirstName '!!' -LastName 'Smith' -Domain 'contoso.com' | Out-Null; $false } catch { $true }
}

Write-Host 'Temporary passwords'
Test-That 'default length is 16' { (New-TempPassword).Length -eq 16 }
Test-That 'has upper, lower, digit and symbol' {
    $all = 1..50 | ForEach-Object { New-TempPassword }
    -not ($all | Where-Object { $_ -cnotmatch '[A-Z]' -or $_ -cnotmatch '[a-z]' -or $_ -notmatch '\d' -or $_ -notmatch '[^A-Za-z0-9]' })
}
Test-That 'passwords are not repeated' { (1..200 | ForEach-Object { New-TempPassword } | Select-Object -Unique).Count -eq 200 }

Write-Host 'Role mapping'
$config = Get-LifecycleConfig -Path (Join-Path $root 'config' 'roles.example.json')
Test-That 'AllStaff groups are added to every role' {
    $a = Get-RoleAssignment -Config $config -Role 'Finance'
    ($a.EntraGroups -contains 'SG-All-Staff') -and ($a.EntraGroups -contains 'SG-Finance') -and ($a.OktaGroups -contains 'ERP-Users')
}
Test-That 'role names are case-insensitive' { (Get-RoleAssignment -Config $config -Role 'it').Role -eq 'IT' }
Test-That 'no duplicate groups' {
    $a = Get-RoleAssignment -Config $config -Role 'IT'
    $a.EntraGroups.Count -eq ($a.EntraGroups | Select-Object -Unique).Count
}
Test-That 'unknown role throws' {
    try { Get-RoleAssignment -Config $config -Role 'Astronaut' | Out-Null; $false } catch { $true }
}

Write-Host 'Step runner'
Test-That 'dry run does not run the action' {
    Initialize-LifecycleRun -DryRun
    $script:ran = $false
    Invoke-LifecycleStep -User 'x' -Step 'test' -Action { $script:ran = $true } | Out-Null
    (-not $script:ran) -and ((Get-LifecycleLog)[-1].Status -eq 'Planned')
}
Test-That 'live run runs the action and logs Done' {
    Initialize-LifecycleRun
    $value = 'from caller'
    $out = Invoke-LifecycleStep -User 'x' -Step 'test' -Action { "got $value" }
    ($out -eq 'got from caller') -and ((Get-LifecycleLog)[-1].Status -eq 'Done')
}
Test-That 'a failing step is logged and does not stop the run' {
    Initialize-LifecycleRun
    Invoke-LifecycleStep -User 'x' -Step 'boom' -Action { throw 'nope' } | Out-Null
    Invoke-LifecycleStep -User 'x' -Step 'after' -Action { 1 } | Out-Null
    $log = Get-LifecycleLog
    ($log[0].Status -eq 'Failed') -and ($log[0].Detail -match 'nope') -and ($log[1].Status -eq 'Done')
}

Write-Host 'Dry runs'
$tmpLogs = Join-Path ([IO.Path]::GetTempPath()) "lifecycle-test-$([guid]::NewGuid())"
Test-That 'onboarding dry run plans every step for every hire' {
    & (Join-Path $root 'scripts' 'Invoke-Onboarding.ps1') -CsvPath (Join-Path $root 'samples' 'new-hires.csv') `
        -ConfigPath (Join-Path $root 'config' 'roles.example.json') -DryRun -LogFolder $tmpLogs *> $null
    $log = Import-Csv (Get-ChildItem $tmpLogs -Filter 'onboarding-dryrun-*.csv' | Select-Object -First 1).FullName
    ($log | Where-Object Step -eq 'Create Entra ID user').Count -eq 3 -and
        -not ($log | Where-Object Status -eq 'Failed') -and
        ($log | Where-Object { $_.User -eq 'jose.obrien@contoso.com' })
}
Test-That 'offboarding dry run plans every step for every departure' {
    & (Join-Path $root 'scripts' 'Invoke-Offboarding.ps1') -CsvPath (Join-Path $root 'samples' 'departures.csv') `
        -ConfigPath (Join-Path $root 'config' 'roles.example.json') -DryRun -RetireDevices -LogFolder $tmpLogs *> $null
    $log = Import-Csv (Get-ChildItem $tmpLogs -Filter 'offboarding-dryrun-*.csv' | Select-Object -First 1).FullName
    $steps = $log | Where-Object User -eq 'sam.carter@contoso.com' | Select-Object -ExpandProperty Step
    ('Block sign-in', 'Revoke sign-in sessions', 'Convert mailbox to shared', 'Deactivate Okta user', 'Retire Intune devices' |
        Where-Object { $steps -notcontains $_ }).Count -eq 0
}
Remove-Item $tmpLogs -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
