# Lab profile cleanup

Frees disk space on shared Windows machines by deleting cached user profiles that haven't
been used on that machine since a date you pick.

It shows you what it found, asks before deleting, then deletes.

```
Account            Last logon        Idle days  Size (MB)
-------            ----------        ---------  ---------
CAMPUS\jdoe1       2026-03-02 09:14        200   4,120.6
CAMPUS\asmith22    2026-05-19 14:41        122   1,884.2
CAMPUS\bwilliams4  2026-07-30 11:07         50     932.8

3 profiles, 6.78 GB to reclaim

Delete these profiles? This cannot be undone [y/N]:
```

## Usage

Run in an elevated PowerShell window. The cutoff date is required — there's no default.

```powershell
.\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15
.\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15 -Protect labadmin,imaging
.\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15 -Force   # skip the prompt
```

Leave off `-CutoffDate` and the script prints the usage and exits without touching anything.

## What it deletes

The **local cached profile** — the `C:\Users\<name>` folder and its registry entry, removed
together via `Win32_UserProfile`. Active Directory is not touched. The user's domain account
stays valid; if they sign into that machine again they get a fresh profile.

Last use is measured **per machine**, so someone active on the domain who hasn't touched
this particular PC since the cutoff counts as stale here.

> Don't delete `C:\Users\<name>` by hand instead. That leaves the registry entry behind and
> breaks the next logon for that user.

## What it never deletes

System and service profiles, any profile currently signed in, anything outside `C:\Users`,
`Default`/`Public`, the account running the script, `Administrator`, `DefaultAccount`,
`WDAGUtilityAccount`, `defaultuser0`, and profiles with no logon history at all.

To protect your own admin and service accounts, either pass `-Protect labadmin,imaging`, or
add them to the list near the top of the script so nobody has to remember the flag:

```powershell
$protected = @(
    'Administrator'
    'DefaultAccount'
    'WDAGUtilityAccount'
    'defaultuser0'
    'labadmin'
)
```

## Notes

- Needs PowerShell 5.1 (in-box on Windows 10/11) and elevation.
- Profile age is the more recent of `LastUseTime` and the `NTUSER.DAT` write time. Each is
  unreliable alone, so taking the newer of the two errs toward keeping a profile.
- Deletions are logged to `C:\ProgramData\LabProfileCleanup\` in case anyone asks later.
- One locked profile doesn't stop the run; failures are reported at the end.
