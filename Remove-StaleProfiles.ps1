#Requires -Version 5.1
<#
.SYNOPSIS
    Deletes cached user profiles that haven't been used on this computer since a cutoff date.

.DESCRIPTION
    Frees disk space on shared machines. Shows you the profiles it found, asks before
    deleting, then deletes.

    This removes the LOCAL CACHED PROFILE only -- the folder and its registry entry.
    Active Directory is not touched. The user's domain account stays valid; if they log
    into this machine again they get a fresh profile.

.PARAMETER CutoffDate
    Required. Profiles last used before this date are stale. Format: yyyy-MM-dd.

.PARAMETER Protect
    Accounts to never delete, on top of the built-in list. Names or SIDs.

.PARAMETER Force
    Skip the confirmation prompt. Needed when running non-interactively.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15 -Protect labadmin,imaging
#>

[CmdletBinding()]
param(
    [string]   $CutoffDate,
    [string[]] $Protect = @(),
    [switch]   $Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Cutoff is required and has no default -- deleting profiles against a date nobody chose
# is exactly the kind of accident this script should not enable.
function Show-Usage {
    param([string] $Problem)

    Write-Host ''
    Write-Host $Problem -ForegroundColor Red
    Write-Host ''
    Write-Host 'Profiles not used on this machine since the cutoff date will be deleted.'
    Write-Host ''
    Write-Host '  Usage:    .\Remove-StaleProfiles.ps1 -CutoffDate <yyyy-MM-dd>'
    Write-Host ''
    Write-Host '  Example:  .\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15'
    Write-Host '            .\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15 -Protect labadmin'
    Write-Host '            .\Remove-StaleProfiles.ps1 -CutoffDate 2026-08-15 -Force   (no confirmation prompt)'
    Write-Host ''
}

if ([string]::IsNullOrWhiteSpace($CutoffDate)) {
    Show-Usage -Problem 'No cutoff date given.'
    exit 1
}

$cutoff = [datetime]::MinValue
if (-not [datetime]::TryParse($CutoffDate, [ref] $cutoff)) {
    Show-Usage -Problem "Could not read '$CutoffDate' as a date."
    exit 1
}

# A future date makes every profile stale. Usually a typo in the year.
if ($cutoff -gt (Get-Date)) {
    Write-Host ''
    Write-Host "Warning: $($cutoff.ToString('yyyy-MM-dd')) is in the future, so every profile counts as stale." -ForegroundColor Yellow
}

# Accounts that are never deleted, no matter how long they've been idle.
#
# Add your own admin and service accounts to this list, or pass them at run time with
# -Protect. Either works. Editing the list means nobody has to remember the flag.
#
# Names are matched against the SID, the DOMAIN\user name, the bare user name, and the
# profile folder name, case-insensitively.
$protected = @(
    'Administrator'
    'DefaultAccount'
    'WDAGUtilityAccount'
    'defaultuser0'
    # 'labadmin'
    # 'imaging'
) + $Protect

# --------------------------------------------------------------------------------------

function Get-FolderSizeBytes {
    param([string] $Path)
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer } |
                    Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return [int64] 0 }
        return [int64] $sum
    }
    catch { return [int64] 0 }
}

function Resolve-AccountName {
    param([string] $Sid, [string] $ProfilePath)
    # Translate fails when no DC is reachable or the AD object is gone. The folder name is
    # a fine fallback -- it's only used for display and matching.
    try {
        return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate(
                   [System.Security.Principal.NTAccount]).Value
    }
    catch { return (Split-Path -Path $ProfilePath -Leaf) }
}

function Get-LastUseDate {
    # The more recent of LastUseTime and the NTUSER.DAT write time. Each is unreliable
    # alone, so taking the newer of the two errs toward keeping a profile.
    param($UserProfile)

    $dates = @()
    if ($UserProfile.LastUseTime -is [datetime] -and $UserProfile.LastUseTime.Year -gt 1980) {
        $dates += $UserProfile.LastUseTime
    }
    $ntuser = Join-Path $UserProfile.LocalPath 'NTUSER.DAT'
    if (Test-Path -LiteralPath $ntuser) {
        try { $dates += (Get-Item -LiteralPath $ntuser -Force).LastWriteTime } catch { }
    }

    if ($dates.Count -eq 0) { return $null }
    return ($dates | Sort-Object -Descending | Select-Object -First 1)
}

function Test-IsProtected {
    param([string] $Sid, [string] $AccountName, [string] $ProfilePath)
    $names = @($Sid, $AccountName, ($AccountName -split '\\')[-1], (Split-Path $ProfilePath -Leaf))
    foreach ($p in $protected) {
        foreach ($n in $names) { if ($n -and $n -ieq $p) { return $true } }
    }
    return $false
}

# --------------------------------------------------------------------------------------

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Run this as Administrator.' -ForegroundColor Red
    exit 1
}

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$usersRoot   = Join-Path $env:SystemDrive 'Users'

Write-Host ''
Write-Host "Checking profiles on $env:COMPUTERNAME not used since $($cutoff.ToString('yyyy-MM-dd'))..." -ForegroundColor Cyan
Write-Host ''

# Find stale profiles -------------------------------------------------------------------

$stale = New-Object System.Collections.Generic.List[object]

foreach ($userProfile in Get-CimInstance -ClassName Win32_UserProfile) {

    $sid  = $userProfile.SID
    $path = $userProfile.LocalPath

    # Skip anything we must not touch: system profiles, non-user SIDs, the account running
    # this script, profiles currently signed in, odd locations, and shared/template profiles.
    if ($userProfile.Special)                { continue }
    if ($sid -notmatch '^S-1-5-21-')         { continue }
    if ($sid -eq $currentUser)               { continue }
    if ($userProfile.Loaded)                 { continue }
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    if (-not $path.StartsWith($usersRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $folder = Split-Path -Path $path -Leaf
    if (@('Default', 'Default User', 'Public', 'All Users') -contains $folder) { continue }

    $account = Resolve-AccountName -Sid $sid -ProfilePath $path
    if (Test-IsProtected -Sid $sid -AccountName $account -ProfilePath $path) { continue }

    # No logon history means no evidence it's stale, so leave it alone.
    $lastUsed = Get-LastUseDate -UserProfile $userProfile
    if ($null -eq $lastUsed)      { continue }
    if ($lastUsed -ge $cutoff) { continue }

    $stale.Add([pscustomobject]@{
        Account     = $account
        LastUsed    = $lastUsed
        DaysIdle    = [int] ((Get-Date) - $lastUsed).TotalDays
        SizeMB      = [math]::Round((Get-FolderSizeBytes -Path $path) / 1MB, 1)
        ProfilePath = $path
        CimInstance = $userProfile
    })
}

if ($stale.Count -eq 0) {
    Write-Host 'Nothing to delete. No profile has been idle since the cutoff.' -ForegroundColor Green
    Write-Host ''
    return
}

# Show what was found -------------------------------------------------------------------

$totalMB = ($stale | Measure-Object -Property SizeMB -Sum).Sum

$stale |
    Sort-Object -Property LastUsed |
    Format-Table -AutoSize -Property @(
        @{ Label = 'Account';    Expression = { $_.Account } }
        @{ Label = 'Last logon'; Expression = { $_.LastUsed.ToString('yyyy-MM-dd HH:mm') } }
        @{ Label = 'Idle days';  Expression = { $_.DaysIdle }; Align = 'Right' }
        @{ Label = 'Size (MB)';  Expression = { '{0:N1}' -f $_.SizeMB }; Align = 'Right' }
    ) | Out-Host

Write-Host ("{0} profiles, {1:N2} GB to reclaim" -f $stale.Count, ($totalMB / 1024)) -ForegroundColor Cyan
Write-Host ''

# Confirm -------------------------------------------------------------------------------

if (-not $Force) {
    $answer = Read-Host 'Delete these profiles? This cannot be undone [y/N]'
    if ($answer -notmatch '^\s*y(es)?\s*$') {
        Write-Host 'Cancelled. Nothing was deleted.' -ForegroundColor Green
        Write-Host ''
        return
    }
    Write-Host ''
}

# Delete --------------------------------------------------------------------------------

$deleted = New-Object System.Collections.Generic.List[object]
$failed  = 0

foreach ($item in $stale) {
    try {
        # Removing via the CIM instance clears the folder and the ProfileList registry
        # entry together. Deleting the folder by hand would break the user's next logon.
        Remove-CimInstance -InputObject $item.CimInstance -ErrorAction Stop

        if (Test-Path -LiteralPath $item.ProfilePath) {
            throw 'registry entry removed but folder remains (files may be locked)'
        }

        $deleted.Add($item)
        Write-Host ("  deleted  {0}" -f $item.Account) -ForegroundColor Yellow
    }
    catch {
        $failed++
        Write-Warning "$($item.Account) - $($_.Exception.Message)"
    }
}

# Summary + log -------------------------------------------------------------------------

$reclaimedMB = ($deleted | Measure-Object -Property SizeMB -Sum).Sum
if ($null -eq $reclaimedMB) { $reclaimedMB = 0 }

Write-Host ''
Write-Host ("Deleted {0} profiles, reclaimed {1:N2} GB" -f $deleted.Count, ($reclaimedMB / 1024)) -ForegroundColor Cyan
if ($failed -gt 0) { Write-Host "$failed failed - see warnings above" -ForegroundColor Red }

# Keep a record of what was removed, in case anyone asks later.
if ($deleted.Count -gt 0) {
    $logDir = 'C:\ProgramData\LabProfileCleanup'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

    $logFile = Join-Path $logDir ("{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $deleted |
        Select-Object @{ N = 'Computer'; E = { $env:COMPUTERNAME } },
                      @{ N = 'Deleted';  E = { (Get-Date).ToString('s') } },
                      Account,
                      @{ N = 'LastUsed'; E = { $_.LastUsed.ToString('yyyy-MM-dd HH:mm') } },
                      DaysIdle, SizeMB, ProfilePath |
        Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8

    Write-Host "Log: $logFile"
}
Write-Host ''
