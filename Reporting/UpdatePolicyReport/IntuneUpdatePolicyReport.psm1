<#
.SYNOPSIS
    Functions to collect Windows update policies from Intune and render them as a CSV and HTML report.

.DESCRIPTION
    Covers the four Windows update policy types in Intune:
    - Update rings (windowsUpdateForBusinessConfiguration device configurations)
    - Feature update profiles (windowsFeatureUpdateProfiles)
    - Quality update profiles (windowsQualityUpdateProfiles)
    - Driver update profiles (windowsDriverUpdateProfiles)

    All Graph calls go through Invoke-UpdatePolicyGraphRequest, which uses Invoke-MSGraphOperation from the
    MSGraphRequest module. Acquire a token with Get-AccessToken before calling Get-IntuneUpdatePolicy.

.NOTES
    FileName:    IntuneUpdatePolicyReport.psm1
    Created:     2026-10-03
    Updated:     2026-10-03

    Version history:
    1.0.0 - (2026-10-03) Module created

    Required modules:
    MSGraphRequest (Install-Module -Name MSGraphRequest)
#>

# Graph resources (beta) for each policy type
$Script:UpdatePolicyResources = [ordered]@{
    UpdateRing    = "deviceManagement/deviceConfigurations?`$filter=isof('microsoft.graph.windowsUpdateForBusinessConfiguration')&`$expand=assignments"
    FeatureUpdate = "deviceManagement/windowsFeatureUpdateProfiles?`$expand=assignments"
    QualityUpdate = "deviceManagement/windowsQualityUpdateProfiles?`$expand=assignments"
    DriverUpdate  = "deviceManagement/windowsDriverUpdateProfiles?`$expand=assignments"
}

# Display names for each policy type, used in the HTML report
$Script:UpdatePolicyTypeDisplayNames = [ordered]@{
    UpdateRing    = "Update rings"
    FeatureUpdate = "Feature updates"
    QualityUpdate = "Quality updates"
    DriverUpdate  = "Driver updates"
}

function Invoke-UpdatePolicyGraphRequest {
    <#
    .SYNOPSIS
        Invoke a GET request against the Graph beta endpoint and return the items of the response.
    #>
    param(
        [parameter(Mandatory = $true, HelpMessage = "Specify the Graph resource, relative to the beta endpoint.")]
        [ValidateNotNullOrEmpty()]
        [string]$Resource
    )
    Process {
        $Response = Invoke-MSGraphOperation -Get -APIVersion "Beta" -Resource $Resource -ErrorAction Stop

        # Collection responses carry their items in the value property
        if (($null -ne $Response) -and ($Response.PSObject.Properties.Name -contains "value")) {
            return $Response.value
        }
        return $Response
    }
}

function Get-UpdatePolicyAssignmentSummary {
    <#
    .SYNOPSIS
        Summarize the assignments of a policy into included and excluded group counts.
    #>
    param(
        [parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Assignments
    )
    Process {
        $Included = 0
        $Excluded = 0
        $AllDevices = $false
        $AllUsers = $false
        foreach ($Assignment in $Assignments) {
            switch ($Assignment.target.'@odata.type') {
                "#microsoft.graph.exclusionGroupAssignmentTarget" { $Excluded++ }
                "#microsoft.graph.allDevicesAssignmentTarget" { $AllDevices = $true }
                "#microsoft.graph.allLicensedUsersAssignmentTarget" { $AllUsers = $true }
                default { $Included++ }
            }
        }

        $Parts = New-Object -TypeName "System.Collections.Generic.List[string]"
        if ($AllDevices) { $Parts.Add("All devices") }
        if ($AllUsers) { $Parts.Add("All users") }
        if ($Included -gt 0) { $Parts.Add("$($Included) included group(s)") }
        if ($Excluded -gt 0) { $Parts.Add("$($Excluded) excluded group(s)") }

        return [PSCustomObject]@{
            IncludedGroupCount = $Included
            ExcludedGroupCount = $Excluded
            Assigned = ($Parts.Count -gt 0)
            Summary = if ($Parts.Count -gt 0) { $Parts -join ", " } else { "Not assigned" }
        }
    }
}

function Get-UpdatePolicySettingSummary {
    <#
    .SYNOPSIS
        Build a short, human-readable summary of the key settings for a policy of the given type.
    #>
    param(
        [parameter(Mandatory = $true)]
        [ValidateSet("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate")]
        [string]$PolicyType,

        [parameter(Mandatory = $true)]
        [object]$Policy
    )
    Process {
        switch ($PolicyType) {
            "UpdateRing" {
                $Settings = @(
                    "Quality deferral: $([int]$Policy.qualityUpdatesDeferralPeriodInDays) days",
                    "Feature deferral: $([int]$Policy.featureUpdatesDeferralPeriodInDays) days"
                )
                if ($null -ne $Policy.deadlineForQualityUpdatesInDays) {
                    $Settings += "Quality deadline: $($Policy.deadlineForQualityUpdatesInDays) days"
                }
                if ($null -ne $Policy.deadlineForFeatureUpdatesInDays) {
                    $Settings += "Feature deadline: $($Policy.deadlineForFeatureUpdatesInDays) days"
                }
                if ($Policy.qualityUpdatesPaused -eq $true) { $Settings += "Quality updates paused" }
                if ($Policy.featureUpdatesPaused -eq $true) { $Settings += "Feature updates paused" }
            }
            "FeatureUpdate" {
                $Settings = @("Version: $($Policy.featureUpdateVersion)")
                if ($Policy.endOfSupportDate) {
                    $Settings += "End of support: $(([datetime]$Policy.endOfSupportDate).ToString('yyyy-MM-dd'))"
                }
                if ($Policy.rolloutSettings.offerStartDateTimeInUTC) {
                    $Settings += "Gradual rollout"
                }
            }
            "QualityUpdate" {
                $Release = $Policy.expeditedUpdateSettings.qualityUpdateRelease
                $Settings = @("Expedite release: $(if ($Release) { ([datetime]$Release).ToString('yyyy-MM-dd') } else { 'none' })")
                if ($null -ne $Policy.expeditedUpdateSettings.daysUntilForcedReboot) {
                    $Settings += "Forced reboot after: $($Policy.expeditedUpdateSettings.daysUntilForcedReboot) days"
                }
            }
            "DriverUpdate" {
                $Settings = @("Approval: $($Policy.approvalType)")
                if ($null -ne $Policy.deploymentDeferralInDays) {
                    $Settings += "Deferral: $($Policy.deploymentDeferralInDays) days"
                }
                if ($null -ne $Policy.newUpdates) {
                    $Settings += "Pending approval: $($Policy.newUpdates)"
                }
            }
        }
        return ($Settings -join "; ")
    }
}

function ConvertTo-UpdatePolicyRecord {
    <#
    .SYNOPSIS
        Convert a raw Graph policy object into a flat record used by the CSV and HTML report.
    #>
    param(
        [parameter(Mandatory = $true)]
        [ValidateSet("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate")]
        [string]$PolicyType,

        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$Policy,

        [parameter(Mandatory = $false, HelpMessage = "Device status overview for the policy, when available.")]
        [AllowNull()]
        [object]$DeviceStatus
    )
    Process {
        $AssignmentSummary = Get-UpdatePolicyAssignmentSummary -Assignments $Policy.assignments

        return [PSCustomObject]@{
            PolicyType = $PolicyType
            Id = $Policy.id
            DisplayName = $Policy.displayName
            Description = $Policy.description
            Settings = Get-UpdatePolicySettingSummary -PolicyType $PolicyType -Policy $Policy
            Assignments = $AssignmentSummary.Summary
            Assigned = $AssignmentSummary.Assigned
            IncludedGroupCount = $AssignmentSummary.IncludedGroupCount
            ExcludedGroupCount = $AssignmentSummary.ExcludedGroupCount
            SucceededCount = if ($DeviceStatus) { [int]$DeviceStatus.successCount } else { $null }
            ErrorCount = if ($DeviceStatus) { [int]$DeviceStatus.errorCount + [int]$DeviceStatus.failedCount } else { $null }
            ConflictCount = if ($DeviceStatus) { [int]$DeviceStatus.conflictCount } else { $null }
            PendingCount = if ($DeviceStatus) { [int]$DeviceStatus.pendingCount } else { $null }
            CreatedDateTime = $Policy.createdDateTime
            LastModifiedDateTime = $Policy.lastModifiedDateTime
        }
    }
}

function Get-IntuneUpdatePolicy {
    <#
    .SYNOPSIS
        Retrieve Windows update policies from Intune as flat report records.

    .PARAMETER PolicyType
        Policy types to include. Defaults to all four types.

    .PARAMETER SkipDeviceStatus
        Skip the per-policy device status request for update rings, which saves one request per ring.
    #>
    param(
        [parameter(Mandatory = $false)]
        [ValidateSet("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate")]
        [string[]]$PolicyType = @("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate"),

        [parameter(Mandatory = $false)]
        [switch]$SkipDeviceStatus
    )
    Process {
        $Records = New-Object -TypeName "System.Collections.Generic.List[System.Object]"
        foreach ($Type in $Script:UpdatePolicyResources.Keys) {
            if ($Type -notin $PolicyType) { continue }

            Write-Verbose -Message "Retrieving $($Script:UpdatePolicyTypeDisplayNames[$Type]) policies"
            $Policies = @(Invoke-UpdatePolicyGraphRequest -Resource $Script:UpdatePolicyResources[$Type])
            foreach ($Policy in $Policies) {
                if ($null -eq $Policy) { continue }

                # Device status overview is only exposed for device configurations, i.e. update rings
                $DeviceStatus = $null
                if (($Type -eq "UpdateRing") -and (-not $SkipDeviceStatus)) {
                    try {
                        $DeviceStatus = Invoke-UpdatePolicyGraphRequest -Resource "deviceManagement/deviceConfigurations/$($Policy.id)/deviceStatusOverview"
                    }
                    catch [System.Exception] {
                        Write-Warning -Message "Failed to retrieve device status for update ring '$($Policy.displayName)': $($_.Exception.Message)"
                    }
                }

                $Records.Add((ConvertTo-UpdatePolicyRecord -PolicyType $Type -Policy $Policy -DeviceStatus $DeviceStatus))
            }
        }
        return $Records.ToArray()
    }
}

function ConvertTo-UpdatePolicyHtmlReport {
    <#
    .SYNOPSIS
        Render update policy records as a standalone HTML report page.
    #>
    param(
        [parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Title = "Intune update policy report",

        [parameter(Mandatory = $false)]
        [datetime]$GeneratedDateTime = (Get-Date)
    )
    Process {
        $Encode = { param($Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }

        $Builder = New-Object -TypeName "System.Text.StringBuilder"
        [void]$Builder.AppendLine("<!DOCTYPE html>")
        [void]$Builder.AppendLine("<html lang=`"en`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">")
        [void]$Builder.AppendLine("<title>$(& $Encode $Title)</title>")
        [void]$Builder.AppendLine(@"
<style>
:root { --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --card: #f6f8fa; --warn: #9a6700; --bad: #d1242f; --good: #1a7f37; }
@media (prefers-color-scheme: dark) { :root { --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --card: #151b23; --warn: #d29922; --bad: #f85149; --good: #3fb950; } }
body { margin: 0; padding: 24px 16px; background: var(--bg); color: var(--fg); font: 14px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1200px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 17px; margin: 28px 0 8px; }
.meta { color: var(--muted); margin: 0 0 16px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 12px; }
.card .n { font-size: 24px; font-weight: 600; } .card .l { color: var(--muted); }
.scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); vertical-align: top; }
th { color: var(--muted); font-weight: 600; } td.num { text-align: right; font-variant-numeric: tabular-nums; }
.unassigned { color: var(--warn); } .bad { color: var(--bad); font-weight: 600; } .empty { color: var(--muted); }
</style>
"@)
        [void]$Builder.AppendLine("</head><body><main>")
        [void]$Builder.AppendLine("<h1>$(& $Encode $Title)</h1>")
        [void]$Builder.AppendLine("<p class=`"meta`">Generated $(& $Encode $GeneratedDateTime.ToString('yyyy-MM-dd HH:mm'))</p>")

        # Summary cards
        $Unassigned = @($Records | Where-Object { $PSItem.Assigned -eq $false }).Count
        $DevicesInError = ($Records | Where-Object { $null -ne $PSItem.ErrorCount } | Measure-Object -Property ErrorCount -Sum).Sum
        [void]$Builder.AppendLine("<div class=`"cards`">")
        [void]$Builder.AppendLine("<div class=`"card`"><div class=`"n`">$(@($Records).Count)</div><div class=`"l`">Policies</div></div>")
        foreach ($Type in $Script:UpdatePolicyTypeDisplayNames.Keys) {
            $Count = @($Records | Where-Object { $PSItem.PolicyType -eq $Type }).Count
            [void]$Builder.AppendLine("<div class=`"card`"><div class=`"n`">$($Count)</div><div class=`"l`">$($Script:UpdatePolicyTypeDisplayNames[$Type])</div></div>")
        }
        [void]$Builder.AppendLine("<div class=`"card`"><div class=`"n`">$($Unassigned)</div><div class=`"l`">Not assigned</div></div>")
        [void]$Builder.AppendLine("<div class=`"card`"><div class=`"n`">$([int]$DevicesInError)</div><div class=`"l`">Update ring device errors</div></div>")
        [void]$Builder.AppendLine("</div>")

        # One table per policy type
        foreach ($Type in $Script:UpdatePolicyTypeDisplayNames.Keys) {
            $TypeRecords = @($Records | Where-Object { $PSItem.PolicyType -eq $Type } | Sort-Object -Property DisplayName)
            [void]$Builder.AppendLine("<h2>$($Script:UpdatePolicyTypeDisplayNames[$Type])</h2>")
            if ($TypeRecords.Count -eq 0) {
                [void]$Builder.AppendLine("<p class=`"empty`">No policies of this type.</p>")
                continue
            }

            $ShowStatus = ($Type -eq "UpdateRing")
            [void]$Builder.AppendLine("<div class=`"scroll`"><table><thead><tr><th>Name</th><th>Settings</th><th>Assignments</th>")
            if ($ShowStatus) {
                [void]$Builder.AppendLine("<th>Succeeded</th><th>Errors</th><th>Conflicts</th><th>Pending</th>")
            }
            [void]$Builder.AppendLine("<th>Last modified</th></tr></thead><tbody>")
            foreach ($Record in $TypeRecords) {
                $AssignmentClass = if ($Record.Assigned) { "" } else { " class=`"unassigned`"" }
                $Modified = if ($Record.LastModifiedDateTime) { ([datetime]$Record.LastModifiedDateTime).ToString("yyyy-MM-dd") } else { "" }
                [void]$Builder.Append("<tr><td>$(& $Encode $Record.DisplayName)</td><td>$(& $Encode $Record.Settings)</td><td$($AssignmentClass)>$(& $Encode $Record.Assignments)</td>")
                if ($ShowStatus) {
                    $ErrorClass = if ([int]$Record.ErrorCount -gt 0) { "num bad" } else { "num" }
                    [void]$Builder.Append("<td class=`"num`">$($Record.SucceededCount)</td><td class=`"$($ErrorClass)`">$($Record.ErrorCount)</td><td class=`"num`">$($Record.ConflictCount)</td><td class=`"num`">$($Record.PendingCount)</td>")
                }
                [void]$Builder.AppendLine("<td>$(& $Encode $Modified)</td></tr>")
            }
            [void]$Builder.AppendLine("</tbody></table></div>")
        }

        [void]$Builder.AppendLine("</main></body></html>")
        return $Builder.ToString()
    }
}

function Export-IntuneUpdatePolicyReport {
    <#
    .SYNOPSIS
        Write update policy records to a CSV file and an HTML report page in the given folder.

    .OUTPUTS
        An object with the paths of the CSV and HTML files written.
    #>
    param(
        [parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [parameter(Mandatory = $true, HelpMessage = "Folder to write the report files to. Created when missing.")]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$BaseName = "IntuneUpdatePolicyReport"
    )
    Process {
        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType "Directory" -Force | Out-Null
        }

        $CsvPath = Join-Path -Path $Path -ChildPath "$($BaseName).csv"
        $HtmlPath = Join-Path -Path $Path -ChildPath "$($BaseName).html"

        $CsvColumns = @("PolicyType", "DisplayName", "Settings", "Assignments", "IncludedGroupCount", "ExcludedGroupCount", "SucceededCount", "ErrorCount", "ConflictCount", "PendingCount", "CreatedDateTime", "LastModifiedDateTime", "Id")
        if (@($Records).Count -gt 0) {
            $Records | Select-Object -Property $CsvColumns | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding "UTF8"
        }
        else {
            # Export-Csv writes nothing for empty input, so write the header row on its own
            Set-Content -Path $CsvPath -Value (($CsvColumns | ForEach-Object { "`"$($PSItem)`"" }) -join ",") -Encoding "UTF8"
        }
        ConvertTo-UpdatePolicyHtmlReport -Records $Records | Set-Content -Path $HtmlPath -Encoding "UTF8"

        return [PSCustomObject]@{
            CsvPath = $CsvPath
            HtmlPath = $HtmlPath
        }
    }
}

Export-ModuleMember -Function Get-IntuneUpdatePolicy, ConvertTo-UpdatePolicyRecord, Get-UpdatePolicyAssignmentSummary, Get-UpdatePolicySettingSummary, ConvertTo-UpdatePolicyHtmlReport, Export-IntuneUpdatePolicyReport, Invoke-UpdatePolicyGraphRequest
