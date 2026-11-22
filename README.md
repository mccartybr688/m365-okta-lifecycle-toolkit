# M365 + Okta Lifecycle Toolkit

PowerShell scripts that onboard and offboard users across **Microsoft Entra ID, Exchange Online, Intune and Okta** from a CSV. Every run can be previewed with a dry run first, and every step is written to a log.

Onboarding and offboarding are where most access problems start: new hires waiting on their first day for apps they need, and people who have left still holding access weeks later. These scripts make both jobs repeatable, so every user gets the same steps in the same order and you have a record of what was done.

> **About this project:** I built this from scratch as a personal project, with help from Claude, based on the onboarding and offboarding work I have done as a senior systems administrator. It contains no employer code, tenant names or data. Everything in `samples/` and `config/` is made up (Contoso).

## What it does

**Onboarding** (`scripts/Invoke-Onboarding.ps1`), for each new hire in the CSV:

1. Looks up the role in `config/roles.json` to get Entra groups, Okta groups and licenses.
2. Builds a UPN (`firstname.lastname@domain`), removing accents and apostrophes, and adds a number if the name is taken.
3. Creates the Entra ID user with a random temporary password and *change at next sign-in*.
4. Sets the manager.
5. Adds the role's Entra groups. License groups handle licensing (group-based licensing).
6. Assigns direct licenses only for roles that list them.
7. Creates the Okta user and adds the role's Okta groups.
8. Shows a hand-off table with each temporary password **once on screen**. Passwords are never written to the log.

**Offboarding** (`scripts/Invoke-Offboarding.ps1`), for each departure in the CSV:

1. Saves the user's group memberships to a CSV before anything is removed, for audit or restore.
2. Blocks sign-in and resets the password to a random value.
3. Revokes refresh tokens and sign-in sessions.
4. Converts the mailbox to shared, gives the manager access, sets an auto-reply, optionally forwards mail, and hides it from the address list.
5. Removes the user from every assigned Entra group. Dynamic groups are skipped because they update on their own.
6. Removes direct licenses, after the mailbox is shared so no mail is lost.
7. Retires the user's Intune devices (`-RetireDevices`).
8. Clears Okta sessions and deactivates the Okta user, which deprovisions Okta-assigned apps.

If one step fails, the rest still run. The failure shows up in red and in the log, so you know exactly what to finish by hand.

## Quick start (no tenant needed)

```powershell
# PowerShell 7+
./scripts/Invoke-Onboarding.ps1  -CsvPath ./samples/new-hires.csv  -ConfigPath ./config/roles.example.json -DryRun
./scripts/Invoke-Offboarding.ps1 -CsvPath ./samples/departures.csv -ConfigPath ./config/roles.example.json -DryRun -RetireDevices
```

Sample dry-run output:

```
[DRY RUN] Planned  sam.carter@contoso.com - Save group memberships to memberships CSV
[DRY RUN] Planned  sam.carter@contoso.com - Block sign-in
[DRY RUN] Planned  sam.carter@contoso.com - Reset password (random, not logged)
[DRY RUN] Planned  sam.carter@contoso.com - Revoke sign-in sessions
[DRY RUN] Planned  sam.carter@contoso.com - Convert mailbox to shared
[DRY RUN] Planned  sam.carter@contoso.com - Grant manager mailbox access jordan.lee@contoso.com
[DRY RUN] Planned  sam.carter@contoso.com - Set auto-reply
[DRY RUN] Planned  sam.carter@contoso.com - Forward mail jordan.lee@contoso.com
[DRY RUN] Planned  sam.carter@contoso.com - Hide from address list
[DRY RUN] Planned  sam.carter@contoso.com - Remove from all assigned Entra groups
[DRY RUN] Planned  sam.carter@contoso.com - Remove direct licenses after mailbox is shared
[DRY RUN] Planned  sam.carter@contoso.com - Retire Intune devices
[DRY RUN] Planned  sam.carter@contoso.com - Clear Okta sessions
[DRY RUN] Planned  sam.carter@contoso.com - Deactivate Okta user (deprovisions assigned apps)
```

Run the tests:

```powershell
./tests/Run-Tests.ps1
```

## Running against a real tenant

**Modules**

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser   # offboarding only
```

**Microsoft Graph permissions** (delegated, requested at sign-in):

| Script | Scopes |
|---|---|
| Onboarding | `User.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.Read.All` |
| Offboarding | `User.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.ReadWrite.All` |
| Offboarding with `-RetireDevices` | adds `DeviceManagementManagedDevices.Read.All`, `DeviceManagementManagedDevices.PrivilegedOperations.All` |

Offboarding also needs an Exchange Online role that can manage mailboxes. Run it with a dedicated admin account, not a daily-use account.

**Okta**: create an API token for a dedicated service admin with the least privilege that covers user and group management. Set it as an environment variable. Never put it in the config or in the repo.

```powershell
$env:OKTA_ORG_URL   = 'https://yourorg.okta.com'
$env:OKTA_API_TOKEN = '<token>'
```

If Okta users are provisioned from Entra ID or your HR system, run onboarding with `-SkipOkta` and let provisioning create them.

**Config**: copy `config/roles.example.json` to `config/roles.json` (ignored by git) and change the domain, groups and roles to match your tenant. Every user gets the `AllStaff` role's groups plus their own role's groups.

**Suggested first live run**: put one test user in the CSV, review the dry run, run it live, then check the log and the user in each admin center.

## CSV formats

`new-hires.csv`

| Column | Required | Notes |
|---|---|---|
| FirstName, LastName | yes | used for the display name and UPN |
| Role | yes | must match a role in the config |
| Department, JobTitle | no | copied to Entra ID and Okta |
| ManagerUpn | no | sets the manager |
| StartDate | no | shown in the hand-off table |

`departures.csv`

| Column | Required | Notes |
|---|---|---|
| UserPrincipalName | yes | |
| ManagerUpn | no | gets mailbox access; used in the auto-reply |
| ForwardMailTo | no | forwards new mail while keeping a copy |
| LastDay | no | for your records |

## Project layout

```
config/    roles.example.json      role -> groups and licenses
samples/   new-hires.csv, departures.csv
scripts/   Invoke-Onboarding.ps1, Invoke-Offboarding.ps1
src/       LifecycleToolkit.psm1   shared helpers (logging, dry run, UPNs, passwords, Okta API)
tests/     Run-Tests.ps1           helper tests and both dry runs
docs/      index.html              project page (GitHub Pages)
logs/      created at run time, ignored by git
```

## Design choices

- **Dry run first.** Every tenant change goes through one function, so a dry run can't accidentally change anything.
- **Group-based licensing.** Licenses follow groups, so removing groups at offboarding also frees licenses. Direct licenses are supported for exceptions.
- **Order matters at offboarding.** Sign-in is blocked and sessions are revoked before anything else, and licenses are removed only after the mailbox is shared.
- **Keep going on errors.** A missing group should not leave a departed user half offboarded. Failures are logged clearly instead.
- **No secrets on disk.** Okta tokens come from environment variables. Temporary passwords appear on screen once and are never logged.

## Limitations

- Delegated sign-in only. For scheduled runs, switch `Connect-MgGraph` to certificate-based app-only auth.
- Does not handle OneDrive file transfer, hardware returns, or app-specific accounts outside Okta.
- Group names must be unique in Entra ID and Okta.

## License

MIT
