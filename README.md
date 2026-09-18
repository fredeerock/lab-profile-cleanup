# Lab profile cleanup

`Remove-StaleProfiles.ps1` reclaims disk space on shared lab machines by deleting cached
user profiles that haven't been used on that machine since a cutoff date (default
**2026-08-15**).

## What it does and does not do

- **Does:** delete the local cached profile — the `C:\Users\<name>` folder *and* its
  `ProfileList` registry entry — via the `Win32_UserProfile` CIM class.
- **Does not:** touch Active Directory. The user's domain account stays completely valid.
  If they sign into that machine again they just get a fresh, empty profile.

Because it measures last use *per machine*, someone who is active on the domain but
hasn't touched this particular PC since July counts as stale here. That is the intended behavior
for reclaiming space, but it's worth knowing before you read the report.

> Never delete `C:\Users\<name>` by hand instead of running this. That leaves the registry
> entry behind and breaks the next logon for that user.

## Usage

Run elevated. Dry run is the default — **the script deletes nothing without `-Execute`.**

```powershell
# 1. See what would go. Nothing is deleted.
.\Remove-StaleProfiles.ps1

# 2. Same list, actually deleted.
.\Remove-StaleProfiles.ps1 -Execute
```

Both modes print the same rundown before acting:

```
------------------------------------------------------------------------------
Accounts that would be deleted (3 of 27 profiles)
------------------------------------------------------------------------------

Account            Last logon        Idle days  Size (MB)
-------            ----------        ---------  ---------
CAMPUS\jdoe1          2026-03-02 09:14        200   4,120.6
CAMPUS\asmith22       2026-05-19 14:41        122   1,884.2
CAMPUS\bwilliams4     2026-07-30 11:07         50     932.8

  Total: 3 profiles, 6,937.6 MB (6.78 GB) to reclaim
```

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-CutoffDate` | `2026-08-15` | Profiles last used before this are stale. |
| `-Execute` | off | Required to actually delete anything. |
| `-ExcludeUser` | — | Extra accounts to protect, on top of `protected-accounts.txt`. |
| `-LogPath` | `C:\ProgramData\LabProfileCleanup` | Set to a UNC share to collect fleet-wide reports. |
| `-SkipSizeCalculation` | off | Much faster; the report won't show space figures. |

## Always protected

Never deleted, no matter how idle: `Administrator`, `DefaultAccount`, `WDAGUtilityAccount`,
`defaultuser0`, every system/service profile, any profile currently loaded (someone is
signed in), anything outside `C:\Users`, `Default`/`Public`, and the account running the
script. Profiles with **no** logon history are reported and skipped rather than deleted.

### Your own admin and service accounts

Copy `protected-accounts.example.txt` to **`protected-accounts.txt`** next to the script
and list them, one name or SID per line:

```
labadmin
imaging
```

The script loads that file automatically on every run and prints what it picked up, so
protection doesn't depend on anyone remembering a command-line flag. Deploying from a
share? Put the file next to the script on the share. It's gitignored, so site-specific
account names stay out of the repo.

If the file is missing the script says so in its header — worth glancing at, since a
missing file means only the Windows built-ins are protected.

## Rolling it out

1. Run the dry run on **one** lab machine. Read the CSV. Confirm the list is what you expect.
2. Run with `-Execute` on that same machine and confirm the space came back.
3. Only then deploy to the fleet — GPO startup script, SCCM, or PDQ:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "\\files\labadmin\Remove-StaleProfiles.ps1" -Execute -LogPath "\\files\labadmin\cleanup"
```

Every run writes a timestamped CSV and transcript to `-LogPath`, so pointing the whole
fleet at one share gives you a complete audit trail of what was removed where.

## Notes

- Requires PowerShell 5.1 (in-box on Windows 10/11) and elevation.
- Age is the **more recent** of `LastUseTime` and the `NTUSER.DAT` write time. Both are
  unreliable alone, so taking the newer of the two errs toward keeping a profile.
- Failures are per-profile — one locked profile doesn't stop the run. Anything that fails
  is logged as `Failed` or `PartiallyDeleted` in the CSV.
