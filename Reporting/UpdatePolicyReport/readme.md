# Intune update policy report

`Get-IntuneUpdatePolicyReport.ps1` exports every Windows update policy in Intune to `IntuneUpdatePolicyReport.csv` and a standalone `IntuneUpdatePolicyReport.html` report page.

It covers update rings, feature update, quality update and driver update profiles. For each policy the report lists its key settings (deferrals, deadlines, pauses, target version, expedite release, driver approval), its assignments, and for update rings the device status overview (succeeded, errors, conflicts, pending). Unassigned policies and rings with device errors are highlighted.

## Requirements

- The `MSGraphRequest` module (`Install-Module -Name MSGraphRequest`)
- An app registration with the `DeviceManagementConfiguration.Read.All` Microsoft Graph permission

## Usage

```powershell
.\Get-IntuneUpdatePolicyReport.ps1 -TenantID "contoso.onmicrosoft.com" -ClientID "<client_id>" -OutputPath "C:\Reports"

# Only feature and quality update profiles
.\Get-IntuneUpdatePolicyReport.ps1 -TenantID "contoso.onmicrosoft.com" -ClientID "<client_id>" -PolicyType FeatureUpdate, QualityUpdate
```

The functions live in `IntuneUpdatePolicyReport.psm1` and can be imported on their own, for example to feed `Get-IntuneUpdatePolicy` output into another report.

## Tests

```powershell
Invoke-Pester -Path .\Tests
```
