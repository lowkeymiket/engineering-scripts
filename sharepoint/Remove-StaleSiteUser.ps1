# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

<#
.SYNOPSIS
Removes one stale user identity from each SharePoint or OneDrive site in a reviewed list, then reads the site's User Information List.

.DESCRIPTION
For each site in the CSV the script connects with PnP PowerShell, removes the user whose login
name is exactly -LoginName (not a display-name match), waits one second, reads the site's
User Information List, and records Removed or Still Exists. A failure on one site is recorded as
a row and the loop moves on.

The published original had NO dry run. It removed the identity on its first pass. This copy adds
one. DRY RUN IS THE DEFAULT. Without -Execute the script still connects to each site, because the
lookup needs it, but it only reads: it looks up the exact login on the site and records
WouldRemove if the login is there, NotFound if it is not, or LookupFailed with the message if the
lookup threw. It removes nothing. Pass -Execute to remove. An explicit -WhatIf always wins, even
together with -Execute. The script never sets $WhatIfPreference itself. With -Execute,
ConfirmImpact is High, so PowerShell asks before each site unless -Confirm:$false is passed after
the dry run has been read.

Known weakness, carried over from the original. The read-back matches on display name and email,
not on the login the removal used. The stale and the current identity shared an email address in
the case this was written for, so the read-back may not tell them apart. Read Still Exists as
"look at this site", not as proof the removal failed. Removed means only that no entry matched
the name and email.

Results: one row per site (Site, Status, Notes), exported to -OutputCsv after the loop. An
interrupted run writes no file. Under an explicit -WhatIf, Export-Csv follows PowerShell's WhatIf
rules and writes no file.
Status values: WouldRemove, NotFound, LookupFailed, Declined, Removed, Still Exists, Failed.

Changed in this copy, not in the published original: the dry-run default and -Execute switch, the
read-only lookup step before any removal, ShouldProcess support, $ErrorActionPreference = 'Stop',
a Notes column, a one-row or empty CSV handled with @(), and a site-count line on the console.
ClientId was already a parameter with no value in the original. In this copy the parameters that
name the environment (-LoginName, -ExpectedDisplayName, -ExpectedEmail, -ClientId) default to
placeholders instead of being mandatory.

.PARAMETER SitesCsv
Path to the reviewed CSV. One column, Site, holding the full site URL:
<<REPLACE: full URL of one site>>.

.PARAMETER LoginName
The exact membership login of the stale identity: <<REPLACE: membership login name of the stale identity>>.

.PARAMETER ExpectedDisplayName
Display name used only by the read-back: <<REPLACE: display name of the person>>.

.PARAMETER ExpectedEmail
Email used only by the read-back: <<REPLACE: email address of the person>>.

.PARAMETER ClientId
Client id of an app registration allowed to sign in interactively to the sites:
<<REPLACE: client id of the app registration>>. The script holds no value for it. Which delegated
permissions that registration carries is outside this script.

.PARAMETER OutputCsv
Where to write the results CSV. Default .\SharePointUserCleanupResults.csv.

.PARAMETER Execute
Actually remove the identity. Without this switch the run is a dry run.

.EXAMPLE
.\Remove-StaleSiteUser.ps1 -SitesCsv .\reviewed-sites.csv -LoginName <<REPLACE: membership login name of the stale identity>> -ExpectedDisplayName <<REPLACE: display name of the person>> -ExpectedEmail <<REPLACE: email address of the person>> -ClientId <<REPLACE: client id of the app registration>>

Dry run. Looks up the login on each site and removes nothing.

.NOTES
Connects to each site with Connect-PnPOnline -Interactive, so it works with the signed-in
account's own rights on that site. The script requests no other scopes. The connection is not
closed at the end. Run the dry run first and read its results before using -Execute.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string]$SitesCsv,
    [string]$LoginName = '<<REPLACE: membership login name of the stale identity>>',
    [string]$ExpectedDisplayName = '<<REPLACE: display name of the person>>',
    [string]$ExpectedEmail = '<<REPLACE: email address of the person>>',
    [string]$ClientId = '<<REPLACE: client id of the app registration>>',
    [string]$OutputCsv = '.\SharePointUserCleanupResults.csv',
    [switch]$Execute
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

# Dry run unless -Execute is given. An explicit -WhatIf also forces a dry run.
$dryRun = (-not $Execute) -or $WhatIfPreference

$results = @()
$csv = @(Import-Csv -LiteralPath $SitesCsv)
$mode = if ($dryRun) { 'DRY RUN' } else { 'EXECUTE' }
Write-Host "Sites in CSV: $($csv.Count). Mode: $mode" -ForegroundColor Cyan

foreach ($row in $csv) {
    $site = $row.Site
    Write-Host "Processing $site" -ForegroundColor Cyan
    try {
        Connect-PnPOnline -Url $site -Interactive -ClientId $ClientId

        # Added in this copy: read-only lookup of the exact login. The dry run stops after this.
        $found = $null
        $lookupError = $null
        try { $found = Get-PnPUser -Identity $LoginName } catch { $lookupError = $_.Exception.Message }

        if ($lookupError) {
            $results += [pscustomobject]@{ Site = $site; Status = 'LookupFailed'; Notes = $lookupError }
            Write-Host "$site - LookupFailed" -ForegroundColor Yellow
            continue
        }
        if (-not $found) {
            $results += [pscustomobject]@{ Site = $site; Status = 'NotFound'; Notes = $null }
            Write-Host "$site - NotFound" -ForegroundColor Yellow
            continue
        }

        if ($dryRun) {
            $results += [pscustomobject]@{ Site = $site; Status = 'WouldRemove'; Notes = $null }
            Write-Host "$site - WouldRemove (dry run, nothing changed)" -ForegroundColor DarkYellow
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($site, "Remove $LoginName from the site user list")) {
            $results += [pscustomobject]@{ Site = $site; Status = 'Declined'; Notes = $null }
            continue
        }

        Remove-PnPUser -Identity $LoginName -Force
        Start-Sleep -Seconds 1

        # NOTE: this read-back matches display name and email, not the login used above.
        # The stale and the current identity shared an email address. See the weakness in the help text.
        $verify = Get-PnPListItem -List 'User Information List' -Fields 'ID','Title','EMail' |
            Where-Object {
                $_['Title'] -eq $ExpectedDisplayName -and
                $_['EMail'] -eq $ExpectedEmail
            }

        $status = if ($verify) { 'Still Exists' } else { 'Removed' }
        $results += [pscustomobject]@{ Site = $site; Status = $status; Notes = $null }
        Write-Host "$site - $status" -ForegroundColor Green
    }
    catch {
        $results += [pscustomobject]@{ Site = $site; Status = 'Failed'; Notes = $_.Exception.Message }
        Write-Host "$site - FAILED" -ForegroundColor Red
    }
}

$results | Export-Csv -Path $OutputCsv -NoTypeInformation
$results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Results: $OutputCsv"
