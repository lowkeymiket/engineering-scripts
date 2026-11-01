# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

<#
.SYNOPSIS
    Reports on, or applies, the OneNote "Automatically back up my notebook"
    setting (off) and "Number of backup copies to keep" (0) for every user
    profile on the machine.

.DESCRIPTION
    Written for an RMM that runs scripts as SYSTEM, non-interactively, under
    Windows PowerShell 5.1. For every real user profile listed under
    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList (domain,
    Entra and local accounts, by SID family) plus the Default profile (so new
    users inherit the setting), the script looks at these values under
    Software\Microsoft\Office\<version key>\OneNote\Options\Save (the version
    key is a placeholder in this listing; 16.0 is the current Office family):

      BackupEnableAutoBackup       = 0 (DWORD)   "Automatically back up" unchecked
      BackupNumberOfBackupsToKeep  = 0 (DWORD)   keep 0 backup copies

    REPORT ONLY IS THE DEFAULT. Without -Apply no registry value is created or
    changed, and no hive is unloaded except the temporary hives this run loaded
    itself. Each profile is reported as compliant or non-compliant, and the
    script exits 1 if any profile is non-compliant or unreadable, or if a stale
    temporary hive is present (see below), so it can be used as an RMM monitor
    or detection script. Pass -Apply to write the values. With -Apply, -WhatIf
    and -Confirm work: each value write asks ShouldProcess first, and the key
    is created only after a write is approved.

    Per profile:

      1. If the user's hive is already loaded in HKEY_USERS (signed-in user),
         the values are read or written there.
      2. Otherwise NTUSER.DAT is loaded under a temporary name, read or
         written, then unloaded (with retries). Profiles whose NTUSER.DAT is
         missing or locked are skipped and logged; a skip is not a failure.
      3. With -Apply the Save key is created if missing (OneNote may never have
         run for that user).

    Stale temporary hives: before the profile loop the script looks for any
    temporary hive left loaded by an earlier interrupted run (recognized by this
    script's temporary-name prefix). With -Apply (and ShouldProcess approving)
    it unloads each one, because a stale mount keeps that profile's file
    locked. In report mode it unloads nothing: each one is reported as a
    StaleMount row (tag STALE) and left alone, and the profile whose file it
    holds is skipped with a message that points at it, because that file cannot
    be loaded a second time.

    The script is idempotent: each profile is logged as already correct or
    changed (with old -> new values). One output line per profile, then a
    summary and a final SUCCESS/ERROR line with a matching exit code.

    Added in this copy, not in the private original: this help block, the
    default of report only with a -Apply switch (the original applied by
    default and had a -CheckOnly switch), SupportsShouldProcess on the write
    path, the WouldChange result, and the stale-hive cleanup running only under
    -Apply (the original unloaded stale hives in both modes; report mode here
    reports them as StaleMount instead). The hive loading and the unload retry
    logic are unchanged.

.PARAMETER Apply
    Write the two values and unload stale temporary hives. Without it the
    script only reports.

.NOTES
    Requires administrator rights or SYSTEM (loads other users' hives). If run
    without either, it prints an ERROR line and exits 1 before touching any
    profile, in both modes. Never uses HKCU, because under SYSTEM it points at
    the SYSTEM account's hive.

    Applies to Office 16.0 (Microsoft 365, 2016, 2019, 2021).

    Exit codes:
      0  Report mode: every readable profile is compliant and no stale
         temporary hive is present.
         Apply mode: no profile failed to be written.
      1  Not elevated and not SYSTEM (nothing is touched).
         Report mode: at least one profile is non-compliant or unreadable, or
         at least one stale temporary hive is present (StaleMount, not
         unloaded in report mode).
         Apply mode: at least one profile failed (including a hive that could
         not be unloaded after writing).
      A skipped profile does not change the exit code.

.EXAMPLE
    .\Disable-OneNoteAutoBackup.ps1
    Reports current values per profile; exit code 1 if any are non-compliant
    or a stale temporary hive is present.

.EXAMPLE
    .\Disable-OneNoteAutoBackup.ps1 -Apply
    Applies the settings to every profile and the Default profile, and unloads
    stale temporary hives.

.EXAMPLE
    .\Disable-OneNoteAutoBackup.ps1 -Apply -WhatIf
    Shows which values would be written and which stale hives would be
    unloaded, and changes nothing.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Apply
)

# Startup guard: this must stay the first executable code in the file.
function Assert-ReferenceListing {
    # The marker is built from two pieces so that this function does not match its own text.
    $marker = '<<REPL' + 'ACE:'
    $self = $null
    if ($PSCommandPath) { $self = Get-Content -LiteralPath $PSCommandPath -Raw -ErrorAction SilentlyContinue }
    if (-not $self -or $self.Contains($marker)) {
        Write-Host 'Reference listing. Replace every placeholder and review the logic before running.'
        exit 2
    }
}
Assert-ReferenceListing

# Settings to enforce (relative to the root of each user hive)
$KeyRel  = 'Software\Microsoft\Office\<<REPLACE: Office version key under the registry Office folder, 16.0 for current Microsoft 365>>\OneNote\Options\Save'
$Desired = [ordered]@{
    BackupEnableAutoBackup      = 0
    BackupNumberOfBackupsToKeep = 0
}

$ProfileListPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$TempPrefix      = 'TmpOneNoteAB_'
$script:RegOutput = ''
$script:Cmdlet    = $PSCmdlet
$script:StaleLeft = 0     # stale temporary hives seen and not unloaded this run

function New-Result {
    param([string]$Status, [string]$Detail)
    [pscustomobject]@{ Status = $Status; Detail = $Detail }
}

# Flattens reg.exe output (stdout lines and stderr ErrorRecords) into one line.
function Get-RegText {
    param($Output)
    $lines = foreach ($o in @($Output)) {
        if ($o -is [System.Management.Automation.ErrorRecord]) { $o.Exception.Message } else { [string]$o }
    }
    return (($lines | Where-Object { $_ -and $_.Trim() }) -join ' ').Trim()
}

# Loads an NTUSER.DAT under HKEY_USERS\<HiveName>. Returns $true on success.
function Mount-Hive {
    param([string]$HiveName, [string]$NtUserPath)
    $script:RegOutput = Get-RegText (& reg.exe load "HKU\$HiveName" $NtUserPath 2>&1)
    return ($LASTEXITCODE -eq 0)
}

# Unloads HKEY_USERS\<HiveName>. Collects garbage first so no managed registry
# handle keeps the hive busy, and retries a few times. Returns $true on success.
function Dismount-Hive {
    param([string]$HiveName)
    for ($i = 1; $i -le 5; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $script:RegOutput = Get-RegText (& reg.exe unload "HKU\$HiveName" 2>&1)
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# Enumerates real user profiles plus the Default profile.
function Get-ProfileTargets {
    $targets = @()
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    try {
        $plKey = $hklm.OpenSubKey($ProfileListPath)
        if (-not $plKey) { return $targets }
        try {
            foreach ($sid in $plKey.GetSubKeyNames()) {
                # Domain/local (S-1-5-21-*) and Entra (S-1-12-1-*) accounts only.
                # Skips service accounts and ".bak" duplicates.
                if ($sid -notmatch '^S-1-(5-21|12-1)(-\d+)+$') { continue }

                $sub = $plKey.OpenSubKey($sid)
                $profilePath = $null
                try { $profilePath = $sub.GetValue('ProfileImagePath') } finally { $sub.Close() }
                if (-not $profilePath) { continue }
                $profilePath = [Environment]::ExpandEnvironmentVariables([string]$profilePath)

                $targets += [pscustomobject]@{
                    Label  = '{0} [{1}]' -f (Split-Path $profilePath -Leaf), $sid
                    Sid    = $sid
                    NtUser = Join-Path $profilePath 'NTUSER.DAT'
                }
            }

            $defaultPath = $plKey.GetValue('Default')
            if ($defaultPath) {
                $defaultPath = [Environment]::ExpandEnvironmentVariables([string]$defaultPath)
            }
            else {
                $defaultPath = Join-Path $env:SystemDrive 'Users\Default'
            }
            $targets += [pscustomobject]@{
                Label  = 'Default profile (new users)'
                Sid    = $null
                NtUser = Join-Path $defaultPath 'NTUSER.DAT'
            }
        }
        finally { $plKey.Close() }
    }
    finally { $hklm.Close() }
    return $targets
}

# Reads (report) or writes (-Apply) the OneNote values under HKEY_USERS\<HiveName>.
function Invoke-HiveSettings {
    param([string]$HiveName, [string]$Label)

    $changes  = New-Object System.Collections.Generic.List[string]
    $drift    = New-Object System.Collections.Generic.List[string]
    $pending  = New-Object System.Collections.Generic.List[string]
    $writable = $false
    $key      = $null

    try {
        $subPath = "$HiveName\$KeyRel"
        # Always open read-only first. $null means the key does not exist.
        # The key is created (or reopened for writing) only after a write is approved.
        $key = $HKU.OpenSubKey($subPath, $false)

        foreach ($name in $Desired.Keys) {
            $want = [int]$Desired[$name]
            $cur  = $null
            $kind = $null
            if ($key) {
                $cur = $key.GetValue($name, $null)
                if ($null -ne $cur) { $kind = $key.GetValueKind($name).ToString() }
            }

            if (($null -ne $cur) -and ($kind -eq 'DWord') -and ($cur -eq $want)) { continue }

            if ($null -eq $cur)           { $curText = '<not set>' }
            elseif ($kind -eq 'DWord')    { $curText = [string]$cur }
            else                          { $curText = "$cur ($kind)" }

            if (-not $Apply) {
                $drift.Add("$name = $curText (want $want)")
                continue
            }

            if ($script:Cmdlet.ShouldProcess($Label, "set $name to $want")) {
                if (-not $writable) {
                    if ($key) { $key.Close() }
                    $key = $HKU.CreateSubKey($subPath)
                    $writable = $true
                }
                $key.SetValue($name, $want, [Microsoft.Win32.RegistryValueKind]::DWord)
                $changes.Add("$name $curText -> $want")
            }
            else {
                $pending.Add("$name $curText -> $want")
            }
        }
    }
    finally {
        if ($key) { $key.Close() }
    }

    if (-not $Apply) {
        if ($drift.Count -gt 0) { return (New-Result 'NonCompliant' ($drift -join '; ')) }
        return (New-Result 'Compliant' 'already correct')
    }
    if ($changes.Count -gt 0) {
        $detail = $changes -join '; '
        if ($pending.Count -gt 0) { $detail = "$detail; not applied: " + ($pending -join '; ') }
        return (New-Result 'Changed' $detail)
    }
    if ($pending.Count -gt 0) { return (New-Result 'WouldChange' ($pending -join '; ')) }
    return (New-Result 'Compliant' 'already correct')
}

# Resolves the hive for one profile (loaded, or temporarily loaded from
# NTUSER.DAT), applies Invoke-HiveSettings, and always unloads what it loaded.
function Invoke-Target {
    param($Target)

    $hiveName   = $null
    $loadedHere = $false
    $source     = 'hive loaded'

    if ($Target.Sid) {
        $probe = $HKU.OpenSubKey($Target.Sid)
        if ($probe) {
            $probe.Close()
            $hiveName = $Target.Sid
        }
    }

    if (-not $hiveName) {
        if (-not (Test-Path -LiteralPath $Target.NtUser)) {
            return (New-Result 'Skipped' "NTUSER.DAT not found ($($Target.NtUser))")
        }
        $tmpName = $TempPrefix + [guid]::NewGuid().ToString('N').Substring(0, 8)
        if (-not (Mount-Hive -HiveName $tmpName -NtUserPath $Target.NtUser)) {
            $why = "could not load NTUSER.DAT, in use or access denied ($($script:RegOutput))"
            if ($script:StaleLeft -gt 0) {
                $why = "$why; a stale temporary hive is still loaded and may be holding this file, see the STALE or WARN line above"
            }
            return (New-Result 'Skipped' $why)
        }
        $hiveName   = $tmpName
        $loadedHere = $true
        $source     = 'NTUSER.DAT'
    }

    $result = $null
    try {
        $result = Invoke-HiveSettings -HiveName $hiveName -Label $Target.Label
    }
    catch {
        $result = New-Result 'Failed' $_.Exception.Message
    }
    finally {
        if ($loadedHere) {
            $unloaded = Dismount-Hive -HiveName $hiveName
        }
    }

    if ($loadedHere -and -not $unloaded) {
        return (New-Result 'Failed' "$($result.Detail); hive unload failed, left loaded as HKU\$hiveName ($($script:RegOutput))")
    }
    $result.Detail = "$($result.Detail) (source: $source)"
    return $result
}

# ---------------------------------------------------------------- main

$Mode = 'report'
if ($Apply) { $Mode = 'apply' }
Write-Output "Starting OneNote auto-backup configuration (mode: $Mode)..."

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin  = ([Security.Principal.WindowsPrincipal]$Identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not ($IsAdmin -or $Identity.IsSystem)) {
    # Without elevation other users' hives cannot be loaded, so every profile
    # except the current user's would be skipped and the run would look clean.
    Write-Output "ERROR: must run elevated (administrator) or as SYSTEM. No profiles were touched."
    exit 1
}

$Results = @()
$HKU = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Registry64')
try {
    # Temporary hives left loaded by an earlier interrupted run. -Apply unloads
    # them (behind ShouldProcess). Report mode never unloads one: it records a
    # StaleMount row and leaves the mount alone, so report mode only ever
    # unloads the hives it loaded itself.
    foreach ($stale in $HKU.GetSubKeyNames()) {
        if ($stale -notlike "$TempPrefix*") { continue }

        if (-not $Apply) {
            $script:StaleLeft++
            $s = New-Result 'StaleMount' 'temporary hive left loaded by an earlier interrupted run; report mode does not unload it, so the profile whose file it holds is skipped; run with -Apply to clear it'
            Write-Output "[STALE] HKU\${stale}: $($s.Detail)"
            $Results += $s
            continue
        }

        if ($script:Cmdlet.ShouldProcess("HKU\$stale", 'unload stale temporary hive')) {
            if (Dismount-Hive -HiveName $stale) {
                Write-Output "[INFO] Unloaded stale temporary hive HKU\$stale"
            }
            else {
                $script:StaleLeft++
                Write-Output "[WARN] Could not unload stale temporary hive HKU\$stale ($($script:RegOutput))"
            }
        }
        else {
            $script:StaleLeft++
        }
    }

    $Targets = @(Get-ProfileTargets)
    Write-Output "Found $($Targets.Count) profile(s) to process (including Default)."

    foreach ($Target in $Targets) {
        $r = $null
        try {
            $r = Invoke-Target -Target $Target
        }
        catch {
            $r = New-Result 'Failed' $_.Exception.Message
        }

        $Tag = switch ($r.Status) {
            'Compliant'    { 'OK' }
            'Changed'      { 'CHANGED' }
            'WouldChange'  { 'WHATIF' }
            'NonCompliant' { 'NONCOMPLIANT' }
            'Skipped'      { 'SKIP' }
            default        { 'FAIL' }
        }
        Write-Output "[$Tag] $($Target.Label): $($r.Detail)"
        $Results += $r
    }
}
finally {
    $HKU.Close()
}

$Compliant    = @($Results | Where-Object { $_.Status -eq 'Compliant' }).Count
$Changed      = @($Results | Where-Object { $_.Status -eq 'Changed' }).Count
$WouldChange  = @($Results | Where-Object { $_.Status -eq 'WouldChange' }).Count
$NonCompliant = @($Results | Where-Object { $_.Status -eq 'NonCompliant' }).Count
$Skipped      = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
$Failed       = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
$StaleMount   = @($Results | Where-Object { $_.Status -eq 'StaleMount' }).Count
$ProfileRows  = $Results.Count - $StaleMount

if (-not $Apply) {
    Write-Output "Summary: $ProfileRows profile(s): $Compliant compliant, $NonCompliant non-compliant, $Skipped skipped, $Failed unreadable; $StaleMount stale mount(s)."
    if (($NonCompliant -gt 0) -or ($Failed -gt 0) -or ($StaleMount -gt 0)) {
        Write-Output "ERROR: OneNote auto-backup is not fully disabled, or a stale mount is present ($NonCompliant non-compliant, $Failed unreadable, $StaleMount stale)."
        exit 1
    }
    Write-Output "SUCCESS: all readable profiles are compliant ($Skipped skipped)."
    exit 0
}

Write-Output "Summary: $ProfileRows profile(s): $Compliant already correct, $Changed changed, $WouldChange would change, $Skipped skipped, $Failed failed."
if ($Failed -gt 0) {
    Write-Output "ERROR: $Failed profile(s) failed to be written."
    exit 1
}
if ($WouldChange -gt 0) {
    Write-Output "SUCCESS: nothing was written for $WouldChange profile(s) ($Changed changed, $Compliant already correct, $Skipped skipped)."
    exit 0
}
Write-Output "SUCCESS: OneNote auto-backup disabled and backup copies set to 0 ($Changed changed, $Compliant already correct, $Skipped skipped)."
exit 0
