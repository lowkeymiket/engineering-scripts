# Reference listing, edited for publication to share the approach. Environment
# values are replaced by lines marked REPLACE and the script exits until every
# one is filled in. Review the logic before use. Provided under the MIT License,
# without warranty, and run at your own risk.

<#
.SYNOPSIS
Restores SharePoint Online recycle-bin items listed in a reviewed CSV, one REST call per item.

.DESCRIPTION
Reads a CSV of recycle-bin items that a person has already reviewed and restores each one through
the site recycle-bin REST endpoint, /_api/site/RecycleBin/GetById('{item id}')/Restore(), using
Invoke-PnPSPRestMethod.

The script restores only what is in the CSV. It does not enumerate or filter the recycle bin.
That step happens before this script and is not part of it.

DRY RUN IS THE DEFAULT. Without -Execute the script makes no REST call: it reads the CSV, checks
each Id, and reports what it would restore. Pass -Execute to restore. An explicit -WhatIf always
wins, even together with -Execute. The script never sets $WhatIfPreference itself.

For each item the script prints a progress line and runs the restore inside try/catch. A failed
item prints its name and the error message in red and the loop moves on. Failures are printed to
the console only. The script writes no results file. A closing line prints the counts.

Added in this copy, not in the published original: the dry-run default and -Execute switch,
ShouldProcess support, GUID validation of the Id column, $ErrorActionPreference = 'Stop', the
connection step, and the closing tally. The published original had no preview step of any kind.

.PARAMETER CsvPath
Path to the reviewed CSV. Columns: Id (the recycle-bin item GUID), DirName, Title.
DirName and Title are used only for display.

.PARAMETER SiteUrl
URL of the site that holds the recycle bin: <<REPLACE: URL of the site that holds the recycle bin>>.
Used only with -Execute, to connect. The default is a placeholder in this listing.

.PARAMETER ClientId
Client id of an app registration allowed to sign in interactively to that site:
<<REPLACE: client id of the app registration used to sign in>>. Used only with -Execute, to connect.
The default is a placeholder in this listing.

.PARAMETER DelayMilliseconds
Pause after each restore call, to go easy on throttling. Default 500. Not applied in a dry run.

.PARAMETER Execute
Actually restore the items. Without this switch the run is a dry run.

.EXAMPLE
.\Restore-RecycleBinItems.ps1 -CsvPath .\reviewed-items.csv

Dry run. Prints what would be restored and restores nothing.

.EXAMPLE
.\Restore-RecycleBinItems.ps1 -CsvPath .\reviewed-items.csv -SiteUrl <<REPLACE: URL of the site that holds the recycle bin>> -ClientId <<REPLACE: client id of the app registration used to sign in>> -Execute

Restores every valid row in the CSV.

.NOTES
With -Execute the script runs Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId, so it works
with the signed-in account's own rights on that site: sign in as an account that is allowed to restore items
there. The script requests no other scopes. Run the dry run first and read its output before using -Execute.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$SiteUrl = '<<REPLACE: URL of the site that holds the recycle bin>>',

    [string]$ClientId = '<<REPLACE: client id of the app registration used to sign in>>',

    [ValidateRange(0, 60000)]
    [int]$DelayMilliseconds = 500,

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

if (-not $dryRun) {
    Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $ClientId
    $connection = $null
    try { $connection = Get-PnPConnection } catch { }
    if (-not $connection) {
        throw 'No PnP connection after Connect-PnPOnline.'
    }
}

$items = @(Import-Csv -LiteralPath $CsvPath)
$mode = if ($dryRun) { 'DRY RUN (nothing is restored; pass -Execute to restore)' } else { 'EXECUTE' }
Write-Host "Loaded $($items.Count) items from CSV. Mode: $mode"

$restored = 0
$failed = 0
$skipped = 0
$notRun = 0

for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    $label = "$($item.DirName)/$($item.Title)"
    Write-Host "[$($i + 1) / $($items.Count)] $label"

    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$item.Id, [ref]$id)) {
        Write-Host "SKIPPED (Id is not a GUID): $label" -ForegroundColor Yellow
        $skipped++
        continue
    }

    $endpoint = "/_api/site/RecycleBin/GetById('$id')/Restore()"
    try {
        if ($dryRun) {
            Write-Host "  DRY RUN: would POST $endpoint"
            $notRun++
        }
        elseif ($PSCmdlet.ShouldProcess($label, 'Restore from recycle bin')) {
            Invoke-PnPSPRestMethod -Method Post -Url $endpoint | Out-Null
            $restored++
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
        else {
            $notRun++
        }
    }
    catch {
        $failed++
        Write-Host "FAILED: $label" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
}

Write-Host "Done. Restored: $restored. Failed: $failed. Skipped (invalid Id): $skipped. Not run (dry run or declined): $notRun."
