# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

<#
.SYNOPSIS
Adds a designated site collection administrator to SharePoint Online sites that a reviewed CSV export shows as ownerless.

.DESCRIPTION
Reads a site-inventory CSV export that a person has reviewed. A row is a candidate when its
'Email address of site owners' column is blank OR its 'Number of site owners' column is 0.
Either indicator is enough. The script applies this filter itself, so deleting rows from the CSV
narrows the run, but a row added by hand that shows an owner is ignored and gets no result row.

For each candidate URL (HTTPS only; anything else is recorded as Skipped) the script runs
Set-SPOUser -IsSiteCollectionAdmin $true for the account in -SiteCollectionAdmin.

DRY RUN IS THE DEFAULT. Without -Execute the script changes nothing and records WouldUpdate for
each candidate. Pass -Execute to act. An explicit -WhatIf always wins, even together with
-Execute. The script never sets $WhatIfPreference itself. With -Execute, ConfirmImpact is High, so
PowerShell asks before each site unless -Confirm:$false is passed after the dry run has been read.

With -Verify, and only for a site that was actually changed, the script reads (Get-SPOSite).Owner
and records it in the VerifiedOwner column. It does not compare that value with
-SiteCollectionAdmin. Comparing is left to whoever reads the results file. Owner is a single
field and this script adds an administrator, so a match is not guaranteed.

Results: one row per candidate (Url, Status, VerifiedOwner, Notes), exported to -ResultsPath after
the loop, plus a count by Status on the console. An interrupted run writes no file. Under an
explicit -WhatIf, Export-Csv follows PowerShell's WhatIf rules and writes no file.
Status values: Skipped, WouldUpdate, Updated, Declined, Failed.

Based on the published version of this script. Changed in this copy: the forced WhatIf was
replaced by the dry-run default and -Execute switch, the status now reflects whether a change was
really made (the published version would record Updated after a declined confirmation prompt),
a failed read-back no longer turns a made change into Failed, a single-row or empty CSV is
handled, and the console shows the CSV row count. The tenant and account values are parameters
whose defaults are placeholders in this listing, and with -Execute the script connects to the
admin center itself.

.PARAMETER CsvPath
Path to the reviewed site-inventory CSV. Required columns: URL, Number of site owners,
Email address of site owners.

.PARAMETER SiteCollectionAdmin
Login name of the support account to add as site collection administrator:
<<REPLACE: login name of the support account>>. The default is a placeholder in this listing.

.PARAMETER AdminUrl
SharePoint admin center URL for the tenant: <<REPLACE: SharePoint admin center URL for the tenant>>.
Used only with -Execute, to connect. The default is a placeholder in this listing.

.PARAMETER ResultsPath
Where to write the results CSV. Default .\OwnerlessSiteRemediationResults.csv.

.PARAMETER Verify
After each real change, read the site Owner and record it. Has no effect in a dry run.

.PARAMETER Execute
Actually assign the administrator. Without this switch the run is a dry run.

.EXAMPLE
.\Set-OwnerlessSiteAdmin.ps1 -CsvPath .\reviewed-sites.csv -SiteCollectionAdmin <<REPLACE: login name of the support account>>

Dry run. Writes the results CSV with WouldUpdate rows and changes nothing.

.EXAMPLE
.\Set-OwnerlessSiteAdmin.ps1 -CsvPath .\reviewed-sites.csv -SiteCollectionAdmin <<REPLACE: login name of the support account>> -AdminUrl <<REPLACE: SharePoint admin center URL for the tenant>> -Execute -Verify -Confirm:$false

Acts on every candidate and records the Owner read-back. Use only after reading the dry run.

.NOTES
With -Execute the script runs Connect-SPOService -Url $AdminUrl, which needs the SharePoint Online
Management Shell module. The script requests no API scopes. Use an account in the SharePoint
Administrator role rather than a broader one. Site URLs are the full HTTPS address of each site, as the inventory export lists them.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$SiteCollectionAdmin = '<<REPLACE: login name of the support account>>',

    [string]$AdminUrl = '<<REPLACE: SharePoint admin center URL for the tenant>>',

    [string]$ResultsPath = '.\OwnerlessSiteRemediationResults.csv',

    [switch]$Verify,

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

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) {
    throw "CSV has no data rows: $CsvPath"
}

$requiredColumns = @('URL', 'Number of site owners', 'Email address of site owners')
$missing = $requiredColumns | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) {
    throw "CSV is missing required column(s): $($missing -join ', ')"
}

$sites = @($rows | Where-Object {
    [string]::IsNullOrWhiteSpace($_.'Email address of site owners') -or
    $_.'Number of site owners' -eq '0'
})

$mode = if ($dryRun) { 'DRY RUN' } else { 'EXECUTE' }
Write-Host "Rows in CSV: $($rows.Count). Ownerless candidates: $($sites.Count). Mode: $mode" -ForegroundColor Cyan
$results = [System.Collections.Generic.List[object]]::new()

# Connect only for a real run. A dry run reads the CSV and touches nothing in the tenant.
if (-not $dryRun) {
    Connect-SPOService -Url $AdminUrl
}

foreach ($site in $sites) {
    $url = $site.URL

    if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') {
        $results.Add([pscustomobject]@{
            Url = $url
            Status = 'Skipped'
            VerifiedOwner = $null
            Notes = 'Missing or invalid HTTPS site URL'
        })
        continue
    }

    $status = $null
    $verifiedOwner = $null
    $notes = $null

    try {
        if ($dryRun) {
            $status = 'WouldUpdate'
            Write-Host "DRY RUN: would assign $SiteCollectionAdmin as site collection administrator on $url"
        }
        elseif ($PSCmdlet.ShouldProcess($url, "Assign $SiteCollectionAdmin as site collection administrator")) {
            Set-SPOUser -Site $url -LoginName $SiteCollectionAdmin -IsSiteCollectionAdmin $true
            $status = 'Updated'
        }
        else {
            $status = 'Declined'
        }
    }
    catch {
        $status = 'Failed'
        $notes = $_.Exception.Message
    }

    if ($Verify -and $status -eq 'Updated') {
        try {
            $verifiedOwner = (Get-SPOSite -Identity $url).Owner
        }
        catch {
            $notes = "Updated, but the read-back failed: $($_.Exception.Message)"
        }
    }

    $results.Add([pscustomobject]@{
        Url = $url
        Status = $status
        VerifiedOwner = $verifiedOwner
        Notes = $notes
    })
}

$results | Export-Csv -LiteralPath $ResultsPath -NoTypeInformation
$results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Results: $ResultsPath"
