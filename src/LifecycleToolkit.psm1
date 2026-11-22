#Requires -Version 7.0
<#
    LifecycleToolkit.psm1
    Shared helpers for the onboarding and offboarding scripts.

    Everything that talks to a real tenant goes through Invoke-LifecycleStep, so a
    -DryRun run prints the planned action instead of calling Microsoft Graph,
    Exchange Online or Okta.
#>

Set-StrictMode -Version Latest

$script:DryRun   = $false
$script:LogRows  = [System.Collections.Generic.List[object]]::new()
$script:OktaBase = $null
$script:OktaHeaders = $null

function Initialize-LifecycleRun {
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )
    $script:DryRun = [bool]$DryRun
    $script:LogRows.Clear()
}

function Write-LifecycleLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('Planned', 'Done', 'Skipped', 'Failed')][string]$Status,
        [string]$Detail = ''
    )
    $row = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        User      = $User
        Step      = $Step
        Status    = $Status
        Detail    = $Detail
    }
    $script:LogRows.Add($row)

    $color = switch ($Status) {
        'Planned' { 'Cyan' }
        'Done'    { 'Green' }
        'Skipped' { 'DarkGray' }
        'Failed'  { 'Red' }
    }
    $prefix = if ($script:DryRun -and $Status -eq 'Planned') { '[DRY RUN] ' } else { '' }
    Write-Host ("{0}{1,-8} {2} - {3} {4}" -f $prefix, $Status, $User, $Step, $Detail) -ForegroundColor $color
}

function Invoke-LifecycleStep {
    <#
        Runs one action, or only logs it when -DryRun is on.
        A failed step is logged and the run continues, so one bad group name
        does not stop the rest of an offboarding.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Detail = ''
    )
    if ($script:DryRun) {
        Write-LifecycleLog -User $User -Step $Step -Status Planned -Detail $Detail
        return $null
    }
    try {
        $result = & $Action
        Write-LifecycleLog -User $User -Step $Step -Status Done -Detail $Detail
        return $result
    }
    catch {
        Write-LifecycleLog -User $User -Step $Step -Status Failed -Detail "$Detail $($_.Exception.Message)".Trim()
        return $null
    }
}

function Save-LifecycleLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $script:LogRows | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8
    Write-Host "Log saved to $Path"
}

function Get-LifecycleLog {
    $script:LogRows.ToArray()
}

function ConvertTo-AsciiName {
    # Strips accents and anything that is not a letter, digit or hyphen,
    # so "José O'Brien" becomes "Jose" / "OBrien".
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($ch in $normalized.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    ($sb.ToString() -replace '[^A-Za-z0-9-]', '')
}

function New-UpnFromName {
    <#
        Builds firstname.lastname@domain. If that UPN is already taken
        (checked with -ExistsCheck), adds a number: firstname.lastname2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$Domain,
        [scriptblock]$ExistsCheck = { param($upn) $false }
    )
    $first = (ConvertTo-AsciiName $FirstName).ToLower()
    $last  = (ConvertTo-AsciiName $LastName).ToLower()
    if (-not $first -or -not $last) {
        throw "Cannot build a UPN from '$FirstName $LastName'."
    }
    $base = "$first.$last"
    $upn  = "$base@$Domain"
    $n = 2
    while (& $ExistsCheck $upn) {
        $upn = "$base$n@$Domain"
        $n++
        if ($n -gt 50) { throw "Could not find a free UPN for $base." }
    }
    $upn
}

function New-TempPassword {
    <#
        Random 16-character password with upper, lower, digit and symbol,
        built from a cryptographic random source.
    #>
    [CmdletBinding()]
    param([ValidateRange(12, 64)][int]$Length = 16)
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_=+?'
    )
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) {
        $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)])
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    # Shuffle so the guaranteed characters are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function Get-LifecycleConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    $config = Get-Content -Raw -Path $Path | ConvertFrom-Json -AsHashtable
    foreach ($key in 'Defaults', 'Roles') {
        if (-not $config.ContainsKey($key)) { throw "Config is missing the '$key' section." }
    }
    $config
}

function Get-RoleAssignment {
    <#
        Returns the Entra groups, Okta groups and licenses for a role.
        Every user also gets the groups listed under the "AllStaff" role.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Role
    )
    $roles = $Config.Roles
    $match = $roles.Keys | Where-Object { $_ -ieq $Role } | Select-Object -First 1
    if (-not $match) {
        throw "Role '$Role' is not defined in the config. Known roles: $($roles.Keys -join ', ')"
    }
    $entra = [System.Collections.Generic.List[string]]::new()
    $okta  = [System.Collections.Generic.List[string]]::new()
    $skus  = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('AllStaff', $match) | Select-Object -Unique) {
        if (-not $roles.ContainsKey($name)) { continue }
        $r = $roles[$name]
        foreach ($g in @($r.EntraGroups)) { if ($g -and -not $entra.Contains($g)) { $entra.Add($g) } }
        foreach ($g in @($r.OktaGroups))  { if ($g -and -not $okta.Contains($g))  { $okta.Add($g) } }
        foreach ($s in @($r.LicenseSkus)) { if ($s -and -not $skus.Contains($s))  { $skus.Add($s) } }
    }
    [pscustomobject]@{
        Role        = $match
        EntraGroups = $entra.ToArray()
        OktaGroups  = $okta.ToArray()
        LicenseSkus = $skus.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Okta API (REST). Token comes from the OKTA_API_TOKEN environment variable,
# never from a file in the repo.
# ---------------------------------------------------------------------------

function Connect-OktaApi {
    [CmdletBinding()]
    param(
        [string]$OrgUrl = $env:OKTA_ORG_URL,
        [string]$Token  = $env:OKTA_API_TOKEN
    )
    if (-not $OrgUrl -or -not $Token) {
        throw 'Set OKTA_ORG_URL and OKTA_API_TOKEN environment variables, or run with -SkipOkta.'
    }
    $script:OktaBase = $OrgUrl.TrimEnd('/')
    $script:OktaHeaders = @{
        Authorization = "SSWS $Token"
        Accept        = 'application/json'
    }
}

function Invoke-OktaApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [object]$Body
    )
    if (-not $script:OktaBase) { throw 'Call Connect-OktaApi first.' }
    $params = @{
        Method      = $Method
        Uri         = "$script:OktaBase$Path"
        Headers     = $script:OktaHeaders
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 6) }
    Invoke-RestMethod @params
}

function Get-OktaGroupId {
    param([Parameter(Mandatory)][string]$Name)
    $q = [uri]::EscapeDataString($Name)
    $groups = @(Invoke-OktaApi -Method GET -Path "/api/v1/groups?q=$q&limit=20")
    $exact = $groups | Where-Object { $_.profile.name -eq $Name } | Select-Object -First 1
    if (-not $exact) { throw "Okta group '$Name' not found." }
    $exact.id
}

Export-ModuleMember -Function `
    Initialize-LifecycleRun, Write-LifecycleLog, Invoke-LifecycleStep, Save-LifecycleLog, Get-LifecycleLog, `
    ConvertTo-AsciiName, New-UpnFromName, New-TempPassword, Get-LifecycleConfig, Get-RoleAssignment, `
    Connect-OktaApi, Invoke-OktaApi, Get-OktaGroupId
