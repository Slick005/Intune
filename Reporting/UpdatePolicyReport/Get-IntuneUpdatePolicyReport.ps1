<#
.SYNOPSIS
    Export a report of all Windows update policies in Intune as a CSV file and an HTML report page.

.DESCRIPTION
    Collects update rings, feature update, quality update and driver update profiles from Microsoft Graph (beta),
    summarizes their key settings and assignments, adds the device status overview for update rings, and writes
    IntuneUpdatePolicyReport.csv and IntuneUpdatePolicyReport.html to the output folder.

    The app registration used needs the DeviceManagementConfiguration.Read.All Graph permission.

.PARAMETER TenantID
    Specify the tenant ID or tenant name, e.g. domain.onmicrosoft.com.

.PARAMETER ClientID
    Specify the client ID of the app registration used to authenticate against Graph.

.PARAMETER RedirectUri
    Specify the redirect URI of the app registration. Defaults to http://localhost.

.PARAMETER OutputPath
    Folder the CSV and HTML report are written to. Defaults to the current folder.

.PARAMETER PolicyType
    Policy types to include: UpdateRing, FeatureUpdate, QualityUpdate, DriverUpdate. Defaults to all.

.PARAMETER SkipDeviceStatus
    Skip retrieving the device status overview for update rings.

.EXAMPLE
    .\Get-IntuneUpdatePolicyReport.ps1 -TenantID "contoso.onmicrosoft.com" -ClientID "<client_id>" -OutputPath "C:\Reports"

.NOTES
    FileName:    Get-IntuneUpdatePolicyReport.ps1
    Created:     2026-10-03
    Updated:     2026-10-03

    Version history:
    1.0.0 - (2026-10-03) Script created

    Required modules:
    MSGraphRequest (Install-Module -Name MSGraphRequest)
#>
[CmdletBinding()]
param(
    [parameter(Mandatory = $true, HelpMessage = "Specify the tenant ID or tenant name, e.g. domain.onmicrosoft.com.")]
    [ValidateNotNullOrEmpty()]
    [string]$TenantID,

    [parameter(Mandatory = $true, HelpMessage = "Specify the client ID of the app registration used to authenticate against Graph.")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientID,

    [parameter(Mandatory = $false, HelpMessage = "Specify the redirect URI of the app registration.")]
    [ValidateNotNullOrEmpty()]
    [string]$RedirectUri = "http://localhost",

    [parameter(Mandatory = $false, HelpMessage = "Folder the CSV and HTML report are written to.")]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Get-Location).Path,

    [parameter(Mandatory = $false, HelpMessage = "Policy types to include in the report.")]
    [ValidateSet("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate")]
    [string[]]$PolicyType = @("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate"),

    [parameter(Mandatory = $false, HelpMessage = "Skip retrieving the device status overview for update rings.")]
    [switch]$SkipDeviceStatus
)
Process {
    Import-Module -Name "MSGraphRequest" -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "IntuneUpdatePolicyReport.psm1") -Force -ErrorAction Stop

    # Authentication, sets the header used by Invoke-MSGraphOperation
    $Global:AuthenticationHeader = Get-AccessToken -TenantID $TenantID -ClientID $ClientID -RedirectUri $RedirectUri

    $Records = Get-IntuneUpdatePolicy -PolicyType $PolicyType -SkipDeviceStatus:$SkipDeviceStatus
    Write-Verbose -Message "Retrieved $(@($Records).Count) update policies"

    Export-IntuneUpdatePolicyReport -Records $Records -Path $OutputPath
}
