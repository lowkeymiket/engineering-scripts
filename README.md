# Engineering scripts

This repository holds sanitized reference listings of the scripts behind the engineering write-ups on terrana.dev. They are published to share the approach: report-only defaults, dry runs, read-back checks and a refusal to act when a check fails.

Every script was edited for publication. Environment values are replaced by lines marked `<<REPLACE: ...>>`, and each script refuses to run, exiting with code 2 and a one-line message, until every marked line is filled in. Anything you run after that is your own responsibility and at your own risk, so review the logic first. The code is released under the MIT License (see LICENSE) with no warranty.

| Script | Folder | Write-up |
| --- | --- | --- |
| [Migrate-RmmAgentTenant.ps1](endpoint/Migrate-RmmAgentTenant.ps1) | endpoint | [Level RMM agent tenant migration: Windows and macOS](https://terrana.dev/engineering/endpoint/level-rmm-agent-tenant-migration-windows-and-macos/) |
| [migrate-rmm-agent-tenant-macos.sh](endpoint/migrate-rmm-agent-tenant-macos.sh) | endpoint | [Level RMM agent tenant migration: Windows and macOS](https://terrana.dev/engineering/endpoint/level-rmm-agent-tenant-migration-windows-and-macos/) |
| [Disable-OneNoteAutoBackup.ps1](endpoint/Disable-OneNoteAutoBackup.ps1) | endpoint | [Disabling OneNote automatic backup through RMM, offline profiles included](https://terrana.dev/engineering/endpoint/disabling-onenote-automatic-backup-through-rmm-offline-profiles-included/) |
| [Set-BalancedPowerMode.ps1](endpoint/Set-BalancedPowerMode.ps1) | endpoint | [Forcing Windows 11 to Balanced power mode on AC and DC through the RMM](https://terrana.dev/engineering/endpoint/forcing-windows-11-to-balanced-power-mode-on-ac-and-dc-through-the-rmm/) |
| [Restore-RecycleBinItems.ps1](sharepoint/Restore-RecycleBinItems.ps1) | sharepoint | [SharePoint remediation: restore, reclaim, repair](https://terrana.dev/engineering/sharepoint/sharepoint-remediation-restore-reclaim-repair/) |
| [Set-OwnerlessSiteAdmin.ps1](sharepoint/Set-OwnerlessSiteAdmin.ps1) | sharepoint | [SharePoint remediation: restore, reclaim, repair](https://terrana.dev/engineering/sharepoint/sharepoint-remediation-restore-reclaim-repair/) |
| [Remove-StaleSiteUser.ps1](sharepoint/Remove-StaleSiteUser.ps1) | sharepoint | [SharePoint remediation: restore, reclaim, repair](https://terrana.dev/engineering/sharepoint/sharepoint-remediation-restore-reclaim-repair/) |
