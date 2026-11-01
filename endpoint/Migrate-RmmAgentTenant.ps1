# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

<#
.SYNOPSIS
Swap the Level RMM agent from an old tenant to a new one (derived copy of a published note).

.DESCRIPTION
Report-only by default: without -Apply the script prints each step and changes nothing.
(It still reads the registry and the file system, so the report can name what it found.)

With -Apply the script copies itself into a private work directory and relaunches that copy as a
detached, hidden PowerShell process. That relaunch is the point of the design: the agent that delivers
the script is the agent the script removes, so the work has to continue after that agent and its
terminal session are gone.

Blocks marked ADDED are not in the published note: the report-only default, the exit-code checks, the
read-back, the key handling, the private work directory and the installer integrity check.
The step order is the published order.

Before -Apply:
  - set $env:RMM_TENANT_KEY to the new tenant's key for that device group (the key is never stored in this file);
  - give -InstallerSha256 (the pinned SHA-256 of the installer) or -ExpectedSignerThumbprint (the 40 hex
    characters of the signer certificate thumbprint, which this listing holds as a placeholder). The hash wins when both are given. Without one of them the script refuses to start.
#>
param(
    [switch]$Apply,      # ADDED: nothing is changed without it
    [switch]$Detached,   # ADDED: set by the launcher on the relaunch, do not pass it by hand
    [string]$WorkDir,    # ADDED: set by the launcher, the private work directory
    [string]$InstallerUrl = '<<REPLACE: vendor installer download URL>>',            # ADDED: placeholder for the vendor's installer address
    [string]$ExpectedSignerThumbprint = '<<REPLACE: 40 hex characters, thumbprint of the installer signer certificate>>',      # ADDED: placeholder for the expected signer certificate thumbprint
    [string]$InstallerSha256 = ''                               # ADDED: optional pinned SHA-256 of the installer
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

$ErrorActionPreference = 'Continue'
# ADDED: this sentinel stands for "no key supplied". Replace the placeholder with any fixed text that is not a key;
# the key itself always comes from the environment variable, never from this file.
$keyUnset     = '<<REPLACE: sentinel text meaning no tenant key was supplied>>'
$tenantKey    = if ($env:RMM_TENANT_KEY) { $env:RMM_TENANT_KEY } else { $keyUnset }   # ADDED
$programFiles = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
$failures     = 0   # ADDED: count of failed checks

# ADDED: the published script uses fixed file names in the shared Windows Temp folder. This copy keeps the
# installer, the logs and the script copy in one per-run directory that only SYSTEM and Administrators can use.
# In report-only mode the name below is a label; the directory is created only by the launcher.
$wd           = if ($WorkDir) { $WorkDir } else { Join-Path $env:ProgramData 'rmm-swap-RANDOM' }
$log          = Join-Path $wd 'swap.log'
$uninstallLog = Join-Path $wd 'rmm-agent-uninstall.log'   # ADDED: MSI logs are normal level (/l*), not verbose (/l*v), because verbose MSI logging records property values; they stay in the work directory
$installLog   = Join-Path $wd 'rmm-agent-install.log'
$msi          = Join-Path $wd 'rmm-agent.msi'
$installerReady = $false   # ADDED

function Log($m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    if ($Apply) { Add-Content -Path $log -Value $line }
    Write-Host $line
}

# ADDED: every change goes through Step, which only prints unless -Apply was given.
function Step([string]$Description, [scriptblock]$Action) {
    if (-not $Apply) { Write-Host "[report-only] $Description"; return }
    Log $Description
    & $Action
}

# ADDED: the published script waits for msiexec and discards the result; this one checks it.
function Test-ExitCode([int]$Code, [string]$What, [int[]]$Ok = @(0)) {
    if ($Ok -contains $Code) { Log "$What finished, exit code $Code"; return }
    Log "FAILED: $What, exit code $Code"
    $script:failures++
}

# ADDED: create the per-run work directory with a random name, then limit it to SYSTEM and Administrators.
# The name is unguessable and the directory is empty until the ACL is set, so the short gap is harmless.
function New-PrivateWorkDir {
    $path = Join-Path $env:ProgramData ('rmm-swap-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)   # no inherited rules
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {   # SYSTEM, Administrators
        $who  = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
    $path
}

# ADDED: quote one value for the relaunch command line.
function ConvertTo-QuotedArg([string]$s) { '"' + ($s -replace '"', '\"') + '"' }

# ADDED: the published script runs whatever it downloaded. This copy refuses unless the installer matches the
# pinned SHA-256 or carries a valid Authenticode signature from the signer with the pinned certificate thumbprint.
function Test-Installer([string]$Path) {
    if ($InstallerSha256) {
        $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        if ($actual -eq $InstallerSha256) { Log 'Installer SHA-256 matches the pinned value'; return $true }
        Log 'FAILED: installer SHA-256 does not match the pinned value'
        return $false
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { Log "FAILED: installer signature status is $($sig.Status)"; return $false }
    if ($ExpectedSignerThumbprint -notmatch '^[0-9A-Fa-f]{40}$') { Log 'FAILED: -ExpectedSignerThumbprint is not 40 hex characters'; return $false }
    if (-not ($sig.SignerCertificate.Thumbprint -ceq $ExpectedSignerThumbprint.ToUpperInvariant())) { Log 'FAILED: installer signer certificate thumbprint is not the pinned thumbprint'; return $false }
    Log 'Installer signature is valid and the signer thumbprint matches'
    return $true
}

function Get-LevelServices {
    Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'level' -or $_.DisplayName -match 'level' }
}

# Step 1: stop and disable the services and processes.
function Stop-Level {
    Step 'Stop and disable services whose name matches "level", then stop the level process' {
        Get-LevelServices | ForEach-Object {
            try { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue } catch {}
            try { Set-Service $_.Name -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
        }
        foreach ($p in @('level', 'Level')) { try { Stop-Process -Name $p -Force -ErrorAction SilentlyContinue } catch {} }
    }
}

# Decode the packed product code used as a key name under HKLM:\SOFTWARE\Classes\Installer\Products.
# The first three groups are byte-reversed, the last two have the two digits of each byte swapped.
function Convert-PackedGuidToGuid([string]$packed) {
    if (-not $packed -or $packed.Length -ne 32) { return $null }

    function SwapPairs($s) { ($s -split '(.{2})' | Where-Object { $_ })[-1..0] -join '' }

    $a = SwapPairs($packed.Substring(0, 8))
    $b = SwapPairs($packed.Substring(8, 4))
    $c = SwapPairs($packed.Substring(12, 4))

    function NibbleSwapPairs($s) {
        $out = ''
        for ($i = 0; $i -lt $s.Length; $i += 2) {
            $pair = $s.Substring($i, 2)
            $out += ($pair.Substring(1, 1) + $pair.Substring(0, 1))
        }
        $out
    }

    $d = NibbleSwapPairs($packed.Substring(16, 4))
    $e = NibbleSwapPairs($packed.Substring(20, 12))

    '{0}-{1}-{2}-{3}-{4}' -f $a, $b, $c, $d, $e
}

function Find-LevelMsiProductCodes {
    $codes = @()
    $roots = @(
        'HKLM:\SOFTWARE\Classes\Installer\Products',
        'HKLM:\SOFTWARE\WOW6432Node\Classes\Installer\Products'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.ProductName -and ($props.ProductName -match '^Level($|\s)')) {
                $guid = Convert-PackedGuidToGuid $_.PSChildName
                if ($guid) { $codes += '{' + $guid + '}' }
            }
        }
    }
    $codes | Select-Object -Unique
}

# Steps 1 to 4: stop, vendor uninstall, MSI removal by product code, folder cleanup.
function Uninstall-Level {
    Stop-Level

    # Step 2: vendor uninstall. A failure is logged and the swap carries on to the MSI removal.
    $levelExe = $programFiles | ForEach-Object { Join-Path $_ 'Level\level.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($levelExe) {
        Step "Vendor uninstall: $levelExe --action uninstall, then wait 10 seconds" {
            $global:LASTEXITCODE = 0
            try { & $levelExe --action uninstall | Out-Null } catch { Log "Vendor uninstall error: $_" }
            Test-ExitCode $LASTEXITCODE 'vendor uninstall' @(0)   # ADDED
            Start-Sleep 10
        }
    } else {
        Log 'level.exe not found in the Program Files paths'
    }

    Stop-Level

    # Step 3: MSI removal by product code (covers installs whose uninstall string was blank).
    $codes = @(Find-LevelMsiProductCodes)
    if ($codes.Count -gt 0) {
        foreach ($code in $codes) {
            Step "msiexec /x $code /qn /norestart, normal-level log in the work directory" {
                $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/x $code /qn /norestart /l* `"$uninstallLog`""
                Test-ExitCode $p.ExitCode "msiexec /x $code" @(0, 1605, 3010)   # ADDED: 1605 = not installed, 3010 = reboot needed
            }
        }
    } else {
        Log 'No MSI product codes found (may already be removed).'
    }

    Stop-Level

    # Step 4: remove the identity and config folders. A stale identity re-enrolls the device in the old tenant.
    $folders = @($programFiles | ForEach-Object { Join-Path $_ 'Level' }) + (Join-Path $env:ProgramData 'Level')
    # ADDED: this step runs as SYSTEM, and a user can pre-create one of these folders as a junction or symlink to somewhere else.
    # Each folder must be a real directory (not a reparse point) owned by SYSTEM, Administrators or TrustedInstaller, and is deleted
    # with .NET (PowerShell 7 / .NET Core does not traverse junctions) instead of Remove-Item -Recurse. A refusal counts as a failure.
    # Report-only mode still only lists the folders: the checks and the delete are inside Step.
    $trustedOwners = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'NT SERVICE\TrustedInstaller')
    foreach ($f in $folders) {
        if (Test-Path -LiteralPath $f) {
            Step "Remove folder $f" {
                $item = Get-Item -LiteralPath $f -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Log "Refusing to delete reparse point: $f"; $script:failures++; return }
                $owner = (Get-Acl -LiteralPath $f).Owner
                if ($trustedOwners -notcontains $owner) { Log "Refusing: folder owner is $owner"; $script:failures++; return }
                try { [System.IO.Directory]::Delete($f, $true) } catch { Log "Remove failed: $_" }
                if (Test-Path -LiteralPath $f) { Log "FAILED: folder still exists: $f"; $script:failures++ }   # ADDED
            }
        }
    }
}

# Step 5: download the installer, verify it, install it silently with the new tenant's key.
# ADDED over the note: a private work directory, no leftover installer file, an early stop on a failed download,
# and a verification that must pass before msiexec runs. The note downloads to a fixed Temp path and installs unchecked.
function Install-NewTenant {
    Step "Delete any installer file at $msi, then download the installer from $InstallerUrl (TLS 1.2)" {
        Remove-Item -Path $msi -Force -ErrorAction SilentlyContinue
        if (Test-Path $msi) { Log "FAILED: could not remove the existing installer file: $msi"; $script:failures++; return }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try { Invoke-WebRequest -Uri $InstallerUrl -OutFile $msi -ErrorAction Stop }
        catch { Log "FAILED: download: $_"; $script:failures++; return }
        if (-not (Test-Path $msi)) { Log 'FAILED: the download left no installer file'; $script:failures++; return }
        $script:installerReady = $true
    }
    Step 'Verify the installer: it must match the pinned SHA-256, or have a valid signature from the signer with the pinned thumbprint' {
        if (-not $script:installerReady) { Log 'Verification skipped: there is no installer'; return }
        if (-not (Test-Installer $msi)) {
            $script:installerReady = $false
            $script:failures++
            Remove-Item -Path $msi -Force -ErrorAction SilentlyContinue
        }
    }
    # The published script writes the install property, key included, to its log. This copy does not (ADDED).
    Step 'msiexec /i the verified package silently with LEVEL_API_KEY set to the new tenant key (value not logged, MSI log at normal level)' {
        if (-not $script:installerReady) { Log 'FAILED: no verified installer, install not run'; $script:failures++; return }
        # ADDED: normal-level log (/l*), not verbose (/l*v): verbose MSI logging records property values, and the key is a property.
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$msi`" /qn /norestart /l* `"$installLog`" LEVEL_API_KEY=$tenantKey"
        Test-ExitCode $p.ExitCode 'msiexec /i' @(0, 3010)   # ADDED
    }
    Step "Delete the installer file $msi (the work directory and its logs stay for review)" {
        Remove-Item -Path $msi -Force -ErrorAction SilentlyContinue
    }
}

# Step 6: re-enable and start the services, best effort.
function Enable-Level {
    Step 'Set services whose name matches "level" to Automatic and start them' {
        Get-LevelServices | ForEach-Object {
            try { Set-Service $_.Name -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
            try { Start-Service $_.Name -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# ADDED: the published script has no read-back. This one checks that a matching product is registered
# and a matching service is running. It cannot tell which tenant the agent enrolled in.
function Test-ReadBack {
    Step 'Read back: a matching MSI product is registered and a matching service is running' {
        Start-Sleep 15
        if (@(Find-LevelMsiProductCodes).Count -eq 0) { Log 'FAILED read-back: no matching MSI product is registered'; $script:failures++ }
        if (@(Get-LevelServices | Where-Object { $_.Status -eq 'Running' }).Count -eq 0) { Log 'FAILED read-back: no matching service is running'; $script:failures++ }
        Log 'Read-back cannot show which tenant the agent enrolled in: confirm that in the new tenant console.'
    }
}

# ADDED: refuse to apply without a supplied key, or without an installer check to run later.
$integrityConfigured = if ($InstallerSha256) { $InstallerSha256 -match '^[0-9A-Fa-f]{64}$' } else { $ExpectedSignerThumbprint -match '^[0-9A-Fa-f]{40}$' }
if ($Apply) {
    if ($tenantKey -eq $keyUnset) {
        Write-Host 'Refusing to run: set $env:RMM_TENANT_KEY to the new tenant key first.'
        exit 2
    }
    if (-not $integrityConfigured) {
        Write-Host 'Refusing to run: give -InstallerSha256 (64 hex digits) or -ExpectedSignerThumbprint (40 hex digits) first.'
        exit 2
    }
}

# The launch: copy this script into a new private work directory and run the copy in a detached, hidden
# process. The launcher returns at once and reports nothing about the result; the log file in the work
# directory and the read-back are the only record. Running the copy also means the script that runs is not
# a file in a shared folder that someone else could replace after it was written.
if ($Apply -and -not $Detached) {
    try {
        $dir  = New-PrivateWorkDir
        $copy = Join-Path $dir 'swap.ps1'
        Copy-Item -Path $PSCommandPath -Destination $copy -ErrorAction Stop
    } catch {
        Write-Host "Refusing to run: cannot prepare the private work directory: $_"
        exit 2
    }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -Apply -Detached -WorkDir {1} -InstallerUrl {2} -ExpectedSignerThumbprint {3}' -f (ConvertTo-QuotedArg $copy), (ConvertTo-QuotedArg $dir), (ConvertTo-QuotedArg $InstallerUrl), (ConvertTo-QuotedArg $ExpectedSignerThumbprint)
    if ($InstallerSha256) { $argLine += ' -InstallerSha256 ' + (ConvertTo-QuotedArg $InstallerSha256) }
    Write-Host "Launching a detached hidden PowerShell process. Work directory and log: $dir"
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $argLine
    exit 0
}

if ($Apply -and $Detached) {
    if (-not $WorkDir -or -not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
        Write-Host 'Refusing to run: the detached run needs the private work directory made by the launcher.'
        exit 2
    }
}

if (-not $Apply) {
    Write-Host '[report-only] Create a private work directory under ProgramData with a random name, grant only SYSTEM and Administrators, and copy this script into it'
    Write-Host '[report-only] Relaunch the copy as a detached hidden PowerShell process'
}

try {
    Log '=== START swap (to NEW tenant) ==='
    Uninstall-Level
    Install-NewTenant
    Enable-Level
    Test-ReadBack
} catch {
    Log "FATAL: $_"
    $failures++
}
Log ("=== DONE swap, failed checks: {0} ===" -f $failures)
if ($failures -gt 0) { exit 1 }
