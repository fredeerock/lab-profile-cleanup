#Requires -Version 5.1
<#
.SYNOPSIS
    Removes cached user profiles that have not been used on this computer since a cutoff date.

.DESCRIPTION
    Intended for shared lab machines where cached AD profiles accumulate and consume disk
    space. This script removes the LOCAL CACHED PROFILE only. It does not touch Active
    Directory, and the user's domain account remains fully valid -- if they log into this
    machine again they simply receive a fresh profile.

    Profiles are removed through the Win32_UserProfile CIM class, which deletes both the
    profile folder and its ProfileList registry entry. Deleting C:\Users\<name> by hand
    leaves the registry entry behind and breaks future logons for that user, so never do
    that instead of running this.

    SAFETY: This script reports only. It deletes nothing unless you pass -Execute.

.PARAMETER CutoffDate
    Profiles last used strictly before this date are considered stale. Default: 2026-08-15.

.PARAMETER Execute
    Actually delete the stale profiles. Without this switch the script performs a dry run
    and only writes the report.

.PARAMETER ExcludeUser
    Additional account names or SIDs to protect, beyond the built-in exclusions and
    anything listed in protected-accounts.txt next to the script.
    Matched case-insensitively against the SID, the resolved DOMAIN\user name, the bare
    user name, and the profile folder name.

.PARAMETER LogPath
    Directory for the CSV report and transcript. Default: C:\ProgramData\LabProfileCleanup.
    Point this at a UNC share to collect fleet-wide results in one place.

.PARAMETER SkipSizeCalculation
    Skip measuring profile sizes. Much faster on machines with large profiles, but the
    report will not show how much space was reclaimed.

.EXAMPLE
    .\Remove-StaleProfiles.ps1
    Dry run with the default 2026-08-15 cutoff. Review the CSV before doing anything else.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -Execute
    Delete profiles unused since 2026-08-15.

.EXAMPLE
    .\Remove-StaleProfiles.ps1 -CutoffDate '2026-06-01' -ExcludeUser 'labtech','imaging' -Execute -LogPath '\\files\labadmin\cleanup'
#>

[CmdletBinding()]
param(
    [datetime] $CutoffDate = '2026-08-15',

    [switch]   $Execute,

    [string[]] $ExcludeUser = @(),

    [string]   $LogPath = 'C:\ProgramData\LabProfileCleanup',

    [switch]   $SkipSizeCalculation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------------------
# Accounts that must never be touched, regardless of how long they have been idle.
#
# Site-specific admin and service accounts do NOT belong in this file. Put them in
# protected-accounts.txt next to the script (one name or SID per line, # starts a
# comment) and they load automatically, or pass them with -ExcludeUser. Keeping them in
# a separate file means protection never depends on someone remembering a flag.
# --------------------------------------------------------------------------------------
$BuiltInProtected = @(
    'Administrator'
    'DefaultAccount'
    'WDAGUtilityAccount'
    'defaultuser0'
)

$protectedFile     = if ($PSScriptRoot) { Join-Path -Path $PSScriptRoot -ChildPath 'protected-accounts.txt' } else { $null }
$protectedFileUsed = $false
$ProtectedFromFile = @()

if ($protectedFile -and (Test-Path -LiteralPath $protectedFile)) {
    $protectedFileUsed = $true
    $ProtectedFromFile = @(
        Get-Content -LiteralPath $protectedFile |
            ForEach-Object { ($_ -split '#')[0].Trim() } |
            Where-Object { $_ -ne '' }
    )
}

$ProtectedAccounts = @($BuiltInProtected + $ProtectedFromFile + $ExcludeUser | Select-Object -Unique)

# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FolderSizeBytes {
    param([string] $Path)

    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer } |
                    Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return [int64] 0 }
        return [int64] $sum
    }
    catch {
        return [int64] -1   # unreadable; reported as unknown
    }
}

function Resolve-AccountName {
    param(
        [string] $Sid,
        [string] $ProfilePath
    )

    # Translate can be slow or fail when no DC is reachable, or when the AD object is gone.
    # Falling back to the folder name is fine -- it is only used for reporting and matching.
    try {
        $sidObject = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $sidObject.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        return (Split-Path -Path $ProfilePath -Leaf)
    }
}

function Test-IsProtected {
    param(
        [string] $Sid,
        [string] $AccountName,
        [string] $ProfilePath
    )

    $bareName   = ($AccountName -split '\\')[-1]
    $folderName = Split-Path -Path $ProfilePath -Leaf
    $candidates = @($Sid, $AccountName, $bareName, $folderName)

    foreach ($protected in $ProtectedAccounts) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        foreach ($candidate in $candidates) {
            if ($candidate -and $candidate -ieq $protected) { return $true }
        }
    }
    return $false
}

function Get-LastUseDate {
    <#
        Takes the MOST RECENT of Win32_UserProfile.LastUseTime and the NTUSER.DAT write
        time. Each signal is unreliable on its own -- LastUseTime can be stale, and
        NTUSER.DAT can be touched by background servicing -- so taking the newer of the
        two biases toward keeping a profile. That is the direction we want to be wrong in.
        Returns $null when neither signal is available.
    #>
    param($UserProfile)

    $dates = @()

    if ($UserProfile.PSObject.Properties['LastUseTime'] -and $UserProfile.LastUseTime -is [datetime]) {
        # Unset LastUseTime shows up as an epoch-ish value on some builds.
        if ($UserProfile.LastUseTime.Year -gt 1980) { $dates += $UserProfile.LastUseTime }
    }

    $ntuser = Join-Path -Path $UserProfile.LocalPath -ChildPath 'NTUSER.DAT'
    if (Test-Path -LiteralPath $ntuser) {
        try   { $dates += (Get-Item -LiteralPath $ntuser -Force).LastWriteTime }
        catch { }
    }

    if ($dates.Count -eq 0) { return $null }
    return ($dates | Sort-Object -Descending | Select-Object -First 1)
}

function Get-SystemDriveFreeGB {
    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    return [math]::Round($drive.FreeSpace / 1GB, 2)
}

# --------------------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------------------

if (-not (Test-IsElevated)) {
    Write-Error "This script must run elevated (Run as Administrator, or as SYSTEM via GPO/SCCM)."
    exit 1
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}

$stamp          = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportFile     = Join-Path $LogPath "$env:COMPUTERNAME`_$stamp`_profiles.csv"
$transcriptFile = Join-Path $LogPath "$env:COMPUTERNAME`_$stamp`_transcript.log"

Start-Transcript -Path $transcriptFile -Force | Out-Null

$mode         = if ($Execute) { 'EXECUTE (profiles will be deleted)' } else { 'DRY RUN (nothing will be deleted)' }
$freeBefore   = Get-SystemDriveFreeGB
$currentUser  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

Write-Host ''
Write-Host "Stale profile cleanup" -ForegroundColor Cyan
Write-Host "  Computer   : $env:COMPUTERNAME"
Write-Host "  Mode       : $mode" -ForegroundColor $(if ($Execute) { 'Yellow' } else { 'Green' })
Write-Host "  Cutoff     : $($CutoffDate.ToString('yyyy-MM-dd')) (profiles last used before this are stale)"
Write-Host "  Protected  : $($ProtectedAccounts -join ', ')"
if ($protectedFileUsed) {
    Write-Host "               (incl. $($ProtectedFromFile.Count) from $protectedFile)"
}
elseif ($protectedFile) {
    Write-Host "               no protected-accounts.txt found next to the script" -ForegroundColor DarkYellow
}
Write-Host "  Free space : $freeBefore GB on $env:SystemDrive"
Write-Host "  Report     : $reportFile"
Write-Host ''

# --------------------------------------------------------------------------------------
# Pass 1: evaluate every profile. Nothing is deleted here -- this pass only classifies
# each profile as Skipped or Stale so the rundown below can show the full picture before
# any destructive action is taken.
# --------------------------------------------------------------------------------------

$results = New-Object System.Collections.Generic.List[object]

$userProfiles = Get-CimInstance -ClassName Win32_UserProfile | Sort-Object -Property LocalPath

foreach ($userProfile in $userProfiles) {

    $sid         = $userProfile.SID
    $path        = $userProfile.LocalPath
    $accountName = Resolve-AccountName -Sid $sid -ProfilePath $path

    $record = [pscustomobject]@{
        Computer    = $env:COMPUTERNAME
        RunTime     = (Get-Date).ToString('s')
        AccountName = $accountName
        SID         = $sid
        ProfilePath = $path
        LastUsed    = $null      # [datetime] or $null
        DaysIdle    = $null
        SizeMB      = $null
        Action      = ''
        Reason      = ''
        CimInstance = $userProfile   # stripped before export
    }

    # ---- Hard exclusions, in order of how badly you would regret skipping them ---------

    $skipReason = $null

    $usersRoot  = Join-Path $env:SystemDrive 'Users'
    $folderName = if ([string]::IsNullOrWhiteSpace($path)) { '' } else { Split-Path -Path $path -Leaf }

    if     ($userProfile.Special)                { $skipReason = 'System profile' }
    elseif ($sid -notmatch '^S-1-5-21-')         { $skipReason = 'Not a user SID' }
    elseif ($sid -eq $currentUser)               { $skipReason = 'Profile of the account running this script' }
    elseif ($userProfile.Loaded)                 { $skipReason = 'Profile is loaded (user is signed in)' }
    elseif ([string]::IsNullOrWhiteSpace($path)) { $skipReason = 'Empty profile path' }
    elseif (-not $path.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                                                   $skipReason = "Profile outside $usersRoot" }
    elseif (@('Default', 'Default User', 'Public', 'All Users') -contains $folderName) {
                                                   $skipReason = 'Shared/template profile' }
    elseif (Test-IsProtected -Sid $sid -AccountName $accountName -ProfilePath $path) {
                                                   $skipReason = 'Protected account' }
    elseif (-not (Test-Path -LiteralPath $path)) {
        # Orphaned registry entry. Removing it frees no space, so it is reported only.
        $skipReason = 'Profile folder missing (orphaned registry entry)'
    }

    if ($skipReason) {
        $record.Action = 'Skipped'
        $record.Reason = $skipReason
        $results.Add($record)
        continue
    }

    # ---- Age test ---------------------------------------------------------------------

    $lastUsed = Get-LastUseDate -UserProfile $userProfile

    if ($null -eq $lastUsed) {
        $record.Action = 'Skipped'
        $record.Reason = 'No usage data available (never logged in)'
        $results.Add($record)
        continue
    }

    $record.LastUsed = $lastUsed
    $record.DaysIdle = [int] ((Get-Date) - $lastUsed).TotalDays

    if ($lastUsed -ge $CutoffDate) {
        $record.Action = 'Skipped'
        $record.Reason = 'Used on or after cutoff'
        $results.Add($record)
        continue
    }

    $sizeBytes = if ($SkipSizeCalculation) { [int64] -1 } else { Get-FolderSizeBytes -Path $path }
    if ($sizeBytes -ge 0) { $record.SizeMB = [math]::Round($sizeBytes / 1MB, 1) }

    $record.Action = 'Stale'
    $record.Reason = "Last used $($lastUsed.ToString('yyyy-MM-dd')), before cutoff"
    $results.Add($record)
}

# --------------------------------------------------------------------------------------
# Rundown: what is about to be deleted (or would be, in a dry run)
# --------------------------------------------------------------------------------------

$stale     = @($results | Where-Object { $_.Action -eq 'Stale' })
$staleMB   = ($stale | Where-Object { $null -ne $_.SizeMB } | Measure-Object -Property SizeMB -Sum).Sum
if ($null -eq $staleMB) { $staleMB = 0 }
$staleGB   = [math]::Round($staleMB / 1024, 2)

$verb = if ($Execute) { 'will be deleted' } else { 'would be deleted' }

Write-Host ('-' * 78)
Write-Host "Accounts that $verb ($($stale.Count) of $($results.Count) profiles)" -ForegroundColor Cyan
Write-Host ('-' * 78)

if ($stale.Count -eq 0) {
    Write-Host '  Nothing is stale. No profile has been idle since the cutoff.' -ForegroundColor Green
}
else {
    $stale |
        Sort-Object -Property LastUsed |
        Format-Table -AutoSize -Property @(
            @{ Label = 'Account';    Expression = { $_.AccountName } }
            @{ Label = 'Last logon'; Expression = { $_.LastUsed.ToString('yyyy-MM-dd HH:mm') } }
            @{ Label = 'Idle days';  Expression = { $_.DaysIdle }; Align = 'Right' }
            @{ Label = 'Size (MB)';  Expression = { if ($null -eq $_.SizeMB) { 'n/a' } else { '{0:N1}' -f $_.SizeMB } }; Align = 'Right' }
        ) | Out-Host

    Write-Host ("  Total: {0} profiles, {1:N1} MB ({2:N2} GB) to reclaim" -f $stale.Count, $staleMB, $staleGB) -ForegroundColor Cyan
    Write-Host ''
}

# --------------------------------------------------------------------------------------
# Pass 2: delete (only with -Execute)
# --------------------------------------------------------------------------------------

if (-not $Execute) {
    foreach ($record in $stale) { $record.Action = 'WouldDelete' }
}
elseif ($stale.Count -gt 0) {

    Write-Host 'Deleting...' -ForegroundColor Yellow

    foreach ($record in $stale) {
        try {
            Remove-CimInstance -InputObject $record.CimInstance -ErrorAction Stop

            if (Test-Path -LiteralPath $record.ProfilePath) {
                $record.Action = 'PartiallyDeleted'
                $record.Reason = 'Registry entry removed but folder remains (files may be locked)'
                Write-Warning "$($record.AccountName) - profile folder still present at $($record.ProfilePath)"
            }
            else {
                $record.Action = 'Deleted'
                Write-Host ("  deleted  {0}" -f $record.AccountName) -ForegroundColor Yellow
            }
        }
        catch {
            $record.Action = 'Failed'
            $record.Reason = $_.Exception.Message
            Write-Warning "$($record.AccountName) - removal failed: $($_.Exception.Message)"
        }
    }
    Write-Host ''
}

# --------------------------------------------------------------------------------------
# Report + summary
# --------------------------------------------------------------------------------------

$results |
    Select-Object Computer, RunTime, AccountName, SID, ProfilePath,
                  @{ N = 'LastUsed'; E = { if ($_.LastUsed) { $_.LastUsed.ToString('yyyy-MM-dd HH:mm') } else { '' } } },
                  DaysIdle, SizeMB, Action, Reason |
    Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8

$deleted   = @($results | Where-Object { $_.Action -eq 'Deleted' })
$failed    = @($results | Where-Object { @('Failed', 'PartiallyDeleted') -contains $_.Action })
$skipped   = @($results | Where-Object { $_.Action -eq 'Skipped' })

$reclaimedMB = ($deleted | Where-Object { $null -ne $_.SizeMB } | Measure-Object -Property SizeMB -Sum).Sum
if ($null -eq $reclaimedMB) { $reclaimedMB = 0 }

$freeAfter = Get-SystemDriveFreeGB

Write-Host 'Summary' -ForegroundColor Cyan
Write-Host "  Profiles examined : $($results.Count)"
Write-Host "  Skipped           : $($skipped.Count)"

if ($Execute) {
    Write-Host "  Deleted           : $($deleted.Count)" -ForegroundColor Yellow
    Write-Host "  Failed/partial    : $($failed.Count)" -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Gray' })
    Write-Host ("  Space reclaimed   : {0:N2} GB   (free space {1} GB -> {2} GB)" -f ($reclaimedMB / 1024), $freeBefore, $freeAfter)
}
else {
    Write-Host "  Would delete      : $($stale.Count)" -ForegroundColor Green
    Write-Host ("  Would reclaim     : {0:N2} GB   (free space now {1} GB)" -f $staleGB, $freeBefore)
    Write-Host ''
    Write-Host "  DRY RUN - nothing was deleted. Re-run with -Execute to apply." -ForegroundColor Green
}

Write-Host ''
Write-Host "  Report     : $reportFile"
Write-Host "  Transcript : $transcriptFile"
Write-Host ''

Stop-Transcript | Out-Null
