# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

# RMM one-shot: Windows 11 Balanced Power Configuration
# Configures AC and DC independently in one execution.
# Power plan: Balanced
# Power mode: Balanced (AC and DC)
# Processor minimum: 0% (AC and DC)
# Processor maximum: 100% (AC and DC)

<#
.SYNOPSIS
Reports on, or applies, Balanced power settings for AC and DC on Windows 11.

.DESCRIPTION
Written as a one-shot for an RMM that runs scripts as SYSTEM. It handles four things for the
Balanced power scheme, with AC (plugged in) and DC (battery) treated separately:

  1. Power plan: Balanced is the active scheme.
  2. Power mode: the user-configured AC and DC overlay is Balanced. Balanced is stored as the
     all-zero GUID in ActiveOverlayAcPowerScheme and ActiveOverlayDcPowerScheme under
     HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes.
  3. Processor minimum state: 0 percent, AC and DC.
  4. Processor maximum state: 100 percent, AC and DC.

REPORT ONLY IS THE DEFAULT. Without -Apply the script changes nothing. It reads the active plan,
both overlay registry values and the four processor indexes, prints one line per check, and exits
0 only if every check already matches. Pass -Apply to set the values first and then run the same
read-back checks.

With -Apply, the processor limits are set with powercfg.exe. The two power modes are set through
the powrprof.dll exports PowerSetUserConfiguredACPowerMode and PowerSetUserConfiguredDCPowerMode,
called with the all-zero GUID through P/Invoke.

Added in this copy, not in the private original: this help block, the -ReportOnly and -Apply
switches (the original always applied), and printing every check result instead of stopping at the
first mismatch. The checks themselves are the same ones the original ran.

.PARAMETER ReportOnly
Read and report only. This is the default behavior, so the switch exists to make the intent
explicit in an RMM script field. It cannot be combined with -Apply.

.PARAMETER Apply
Change the settings, then verify them. Without this switch nothing is changed.

.EXAMPLE
.\Set-BalancedPowerMode.ps1

Reports whether the device already matches. Nothing is changed.

.EXAMPLE
.\Set-BalancedPowerMode.ps1 -Apply

Sets Balanced for AC and DC, then reports the read-back results.

.NOTES
Exit codes: 0 when every check matches, 1 for any failure (including a mismatch in report-only
mode) or for an invalid parameter combination.

The two powrprof.dll functions are documented on Microsoft Learn (powrprof.h, Windows 11 and
Windows Server 23H2 or later). I found no Microsoft documentation for the registry values used
for the read-back. They are where Windows stores the setting today, so re-check the read-back
results after a major Windows update.

The processor and plan changes need an elevated context. This script was written for SYSTEM.
#>
[CmdletBinding()]
param(
    [switch]$ReportOnly,
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

$ErrorActionPreference = 'Stop'

$scheme = '<<REPLACE: GUID of the Balanced power scheme, as shown by powercfg /list>>'
$balanced = [guid]::Empty
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'

$script:Results = New-Object System.Collections.Generic.List[object]

function Invoke-PowerCfg {
    param([string[]]$Arguments)

    $output = & powercfg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed: $output"
    }
    return $output
}

function Add-Check {
    param(
        [string]$Name,
        [string]$Expected,
        [string]$Actual
    )

    $script:Results.Add([pscustomobject]@{
        Check    = $Name
        Expected = $Expected
        Actual   = $Actual
        Pass     = ($Actual -eq $Expected)
    })
}

function Test-ProcessorState {
    param(
        [string]$Setting,
        [int]$Expected
    )

    $output = Invoke-PowerCfg @(
        '/query', $scheme, 'SUB_PROCESSOR', $Setting
    )

    $text = $output -join "`n"

    foreach ($supply in @('AC', 'DC')) {
        $pattern = "Current $supply Power Setting Index:\s*0x([0-9a-fA-F]+)"
        $match = [regex]::Match($text, $pattern)

        $actual = '(unreadable)'
        if ($match.Success) {
            $actual = [string][Convert]::ToInt32($match.Groups[1].Value, 16)
        }

        Add-Check "$Setting ($supply)" ([string]$Expected) $actual
    }
}

function Set-BalancedPowerSettings {
    Write-Host 'Starting Balanced power configuration...'

    # Set both processor power profiles.
    Invoke-PowerCfg @('/setacvalueindex', $scheme, 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '0')
    Invoke-PowerCfg @('/setdcvalueindex', $scheme, 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '0')
    Invoke-PowerCfg @('/setacvalueindex', $scheme, 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100')
    Invoke-PowerCfg @('/setdcvalueindex', $scheme, 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100')

    # Activate Balanced power plan.
    Invoke-PowerCfg @('/setactive', $scheme)

    # Set both Windows 11 power modes directly.
    $source = @'
using System;
using System.Runtime.InteropServices;

public static class BalancedPowerApi {
    [DllImport("powrprof.dll", ExactSpelling = true)]
    public static extern uint PowerSetUserConfiguredACPowerMode(
        ref Guid mode);

    [DllImport("powrprof.dll", ExactSpelling = true)]
    public static extern uint PowerSetUserConfiguredDCPowerMode(
        ref Guid mode);
}
'@

    if (-not ('BalancedPowerApi' -as [type])) {
        Add-Type -TypeDefinition $source
    }

    $ac = [BalancedPowerApi]::PowerSetUserConfiguredACPowerMode(
        [ref]$balanced)

    $dc = [BalancedPowerApi]::PowerSetUserConfiguredDCPowerMode(
        [ref]$balanced)

    if ($ac -ne 0 -or $dc -ne 0) {
        throw "Power mode API failed: AC=$ac DC=$dc"
    }
}

function Test-BalancedPowerMode {
    # Verify active plan.
    $active = (Invoke-PowerCfg @('/getactivescheme')) -join ' '
    $isActive = $active -match [regex]::Escape($scheme)
    Add-Check 'Active plan is Balanced' 'True' ([string]$isActive)

    # Verify AC and DC power modes. A missing value counts as a mismatch, as in the original.
    $settings = Get-ItemProperty -Path $regPath

    foreach ($supply in @('Ac', 'Dc')) {
        $name = "ActiveOverlay${supply}PowerScheme"
        $actual = '(not set)'
        if ($settings.PSObject.Properties[$name]) {
            $actual = [string]$settings.$name
        }
        Add-Check "Power mode $($supply.ToUpper()) ($name)" $balanced.ToString() $actual
    }

    # Verify processor settings.
    Test-ProcessorState 'PROCTHROTTLEMIN' 0
    Test-ProcessorState 'PROCTHROTTLEMAX' 100
}

try {
    if ($Apply -and $ReportOnly) {
        throw 'Use either -ReportOnly or -Apply, not both.'
    }

    if ($Apply) {
        Write-Host 'Mode: APPLY (settings will be changed).'
        Set-BalancedPowerSettings
    }
    else {
        Write-Host 'Mode: REPORT ONLY (nothing is changed). Use -Apply to change settings.'
    }

    Test-BalancedPowerMode

    foreach ($r in $script:Results) {
        $status = 'FAIL'
        if ($r.Pass) { $status = 'OK  ' }
        Write-Host ('{0} {1}: expected {2}, found {3}' -f $status, $r.Check, $r.Expected, $r.Actual)
    }

    $failed = @($script:Results | Where-Object { -not $_.Pass })
    if ($failed.Count -gt 0) {
        throw "$($failed.Count) check(s) did not match the Balanced settings."
    }

    Write-Host 'SUCCESS: All power settings verified.'
    Write-Host 'Power plan: Balanced'
    Write-Host 'Power mode AC: Balanced'
    Write-Host 'Power mode DC: Balanced'
    Write-Host 'Processor minimum AC/DC: 0%'
    Write-Host 'Processor maximum AC/DC: 100%'

    exit 0
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)"
    exit 1
}
