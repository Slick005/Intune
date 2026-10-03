#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0.0" }

BeforeAll {
    # Stub for the MSGraphRequest command so it can be mocked without the module installed
    if (-not (Get-Command -Name "Invoke-MSGraphOperation" -ErrorAction SilentlyContinue)) {
        function global:Invoke-MSGraphOperation { param([switch]$Get, [string]$APIVersion, [string]$Resource) }
    }

    $ModulePath = Join-Path -Path $PSScriptRoot -ChildPath "..\Reporting\UpdatePolicyReport\IntuneUpdatePolicyReport.psm1"
    Import-Module -Name $ModulePath -Force

    function New-TestAssignment {
        param([string]$Type)
        [PSCustomObject]@{ target = [PSCustomObject]@{ "@odata.type" = "#microsoft.graph.$($Type)" } }
    }

    $Script:UpdateRing = [PSCustomObject]@{
        id = "ring-1"
        displayName = "Ring 1 - Pilot"
        qualityUpdatesDeferralPeriodInDays = 0
        featureUpdatesDeferralPeriodInDays = 30
        deadlineForQualityUpdatesInDays = 2
        deadlineForFeatureUpdatesInDays = 7
        qualityUpdatesPaused = $true
        featureUpdatesPaused = $false
        lastModifiedDateTime = "2026-09-01T10:00:00Z"
        assignments = @(
            (New-TestAssignment -Type "groupAssignmentTarget"),
            (New-TestAssignment -Type "groupAssignmentTarget"),
            (New-TestAssignment -Type "exclusionGroupAssignmentTarget")
        )
    }
    $Script:FeatureUpdate = [PSCustomObject]@{
        id = "fu-1"
        displayName = "Windows 11 24H2"
        featureUpdateVersion = "Windows 11, version 24H2"
        endOfSupportDate = "2027-10-12T00:00:00Z"
        rolloutSettings = [PSCustomObject]@{ offerStartDateTimeInUTC = "2026-10-01T00:00:00Z" }
        assignments = @()
    }
    $Script:QualityUpdate = [PSCustomObject]@{
        id = "qu-1"
        displayName = "Expedite September"
        expeditedUpdateSettings = [PSCustomObject]@{ qualityUpdateRelease = "2026-09-09T00:00:00Z"; daysUntilForcedReboot = 1 }
        assignments = @((New-TestAssignment -Type "allDevicesAssignmentTarget"))
    }
    $Script:DriverUpdate = [PSCustomObject]@{
        id = "du-1"
        displayName = "Drivers <manual>"
        approvalType = "manual"
        deploymentDeferralInDays = 3
        newUpdates = 5
        assignments = @((New-TestAssignment -Type "groupAssignmentTarget"))
    }
}

AfterAll {
    Remove-Module -Name "IntuneUpdatePolicyReport" -ErrorAction SilentlyContinue
}

Describe "Get-UpdatePolicyAssignmentSummary" {
    It "Counts included and excluded groups" {
        $Result = Get-UpdatePolicyAssignmentSummary -Assignments $Script:UpdateRing.assignments
        $Result.IncludedGroupCount | Should -Be 2
        $Result.ExcludedGroupCount | Should -Be 1
        $Result.Assigned | Should -BeTrue
        $Result.Summary | Should -Be "2 included group(s), 1 excluded group(s)"
    }

    It "Reports all devices and all users targets by name" {
        $Assignments = @((New-TestAssignment -Type "allDevicesAssignmentTarget"), (New-TestAssignment -Type "allLicensedUsersAssignmentTarget"))
        $Result = Get-UpdatePolicyAssignmentSummary -Assignments $Assignments
        $Result.Summary | Should -Be "All devices, All users"
        $Result.IncludedGroupCount | Should -Be 0
    }

    It "Marks a policy without assignments as not assigned" {
        $Result = Get-UpdatePolicyAssignmentSummary -Assignments @()
        $Result.Assigned | Should -BeFalse
        $Result.Summary | Should -Be "Not assigned"
    }

    It "Accepts null assignments" {
        (Get-UpdatePolicyAssignmentSummary -Assignments $null).Summary | Should -Be "Not assigned"
    }
}

Describe "Get-UpdatePolicySettingSummary" {
    It "Summarizes update ring deferrals, deadlines and pauses" {
        $Result = Get-UpdatePolicySettingSummary -PolicyType "UpdateRing" -Policy $Script:UpdateRing
        $Result | Should -Be "Quality deferral: 0 days; Feature deferral: 30 days; Quality deadline: 2 days; Feature deadline: 7 days; Quality updates paused"
    }

    It "Summarizes feature update version, end of support and rollout" {
        $Result = Get-UpdatePolicySettingSummary -PolicyType "FeatureUpdate" -Policy $Script:FeatureUpdate
        $Result | Should -Be "Version: Windows 11, version 24H2; End of support: 2027-10-12; Gradual rollout"
    }

    It "Summarizes quality update expedite settings" {
        $Result = Get-UpdatePolicySettingSummary -PolicyType "QualityUpdate" -Policy $Script:QualityUpdate
        $Result | Should -Be "Expedite release: 2026-09-09; Forced reboot after: 1 days"
    }

    It "Shows no expedite release when none is set" {
        $Policy = [PSCustomObject]@{ expeditedUpdateSettings = $null }
        Get-UpdatePolicySettingSummary -PolicyType "QualityUpdate" -Policy $Policy | Should -Be "Expedite release: none"
    }

    It "Summarizes driver update approval, deferral and pending approvals" {
        $Result = Get-UpdatePolicySettingSummary -PolicyType "DriverUpdate" -Policy $Script:DriverUpdate
        $Result | Should -Be "Approval: manual; Deferral: 3 days; Pending approval: 5"
    }
}

Describe "ConvertTo-UpdatePolicyRecord" {
    It "Combines errors and failures from the device status overview" {
        $Status = [PSCustomObject]@{ successCount = 40; errorCount = 2; failedCount = 1; conflictCount = 3; pendingCount = 4 }
        $Record = ConvertTo-UpdatePolicyRecord -PolicyType "UpdateRing" -Policy $Script:UpdateRing -DeviceStatus $Status
        $Record.PolicyType | Should -Be "UpdateRing"
        $Record.DisplayName | Should -Be "Ring 1 - Pilot"
        $Record.SucceededCount | Should -Be 40
        $Record.ErrorCount | Should -Be 3
        $Record.ConflictCount | Should -Be 3
        $Record.PendingCount | Should -Be 4
        $Record.IncludedGroupCount | Should -Be 2
    }

    It "Leaves status counts empty when there is no device status" {
        $Record = ConvertTo-UpdatePolicyRecord -PolicyType "FeatureUpdate" -Policy $Script:FeatureUpdate
        $Record.SucceededCount | Should -BeNullOrEmpty
        $Record.ErrorCount | Should -BeNullOrEmpty
        $Record.Assigned | Should -BeFalse
    }
}

Describe "Invoke-UpdatePolicyGraphRequest" {
    It "Unwraps the value property of collection responses" {
        Mock -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-MSGraphOperation" -MockWith {
            [PSCustomObject]@{ value = @([PSCustomObject]@{ id = "a" }, [PSCustomObject]@{ id = "b" }) }
        }
        $Result = @(Invoke-UpdatePolicyGraphRequest -Resource "deviceManagement/windowsFeatureUpdateProfiles")
        $Result.id | Should -Be @("a", "b")
        Should -Invoke -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-MSGraphOperation" -Times 1 -ParameterFilter {
            $APIVersion -eq "Beta" -and $Resource -eq "deviceManagement/windowsFeatureUpdateProfiles"
        }
    }

    It "Returns single entity responses as they are" {
        Mock -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-MSGraphOperation" -MockWith {
            [PSCustomObject]@{ successCount = 7 }
        }
        (Invoke-UpdatePolicyGraphRequest -Resource "deviceManagement/deviceConfigurations/x/deviceStatusOverview").successCount | Should -Be 7
    }
}

Describe "Get-IntuneUpdatePolicy" {
    BeforeEach {
        Mock -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -MockWith {
            switch -Wildcard ($Resource) {
                "*deviceStatusOverview" { [PSCustomObject]@{ successCount = 10; errorCount = 1; failedCount = 0; conflictCount = 0; pendingCount = 2 }; break }
                "deviceManagement/deviceConfigurations*" { $Script:UpdateRing }
                "deviceManagement/windowsFeatureUpdateProfiles*" { $Script:FeatureUpdate }
                "deviceManagement/windowsQualityUpdateProfiles*" { $Script:QualityUpdate }
                "deviceManagement/windowsDriverUpdateProfiles*" { $Script:DriverUpdate }
            }
        }
    }

    It "Returns one record per policy across all four types" {
        $Records = Get-IntuneUpdatePolicy
        $Records.Count | Should -Be 4
        $Records.PolicyType | Should -Be @("UpdateRing", "FeatureUpdate", "QualityUpdate", "DriverUpdate")
    }

    It "Filters update rings to Windows Update for Business configurations" {
        Get-IntuneUpdatePolicy -PolicyType "UpdateRing" | Out-Null
        Should -Invoke -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -Times 1 -Exactly -ParameterFilter {
            $Resource -like "*isof('microsoft.graph.windowsUpdateForBusinessConfiguration')*" -and $Resource -like "*`$expand=assignments*"
        }
    }

    It "Adds device status to update rings only" {
        $Records = Get-IntuneUpdatePolicy
        ($Records | Where-Object PolicyType -eq "UpdateRing").SucceededCount | Should -Be 10
        ($Records | Where-Object PolicyType -eq "FeatureUpdate").SucceededCount | Should -BeNullOrEmpty
        Should -Invoke -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -Times 1 -Exactly -ParameterFilter {
            $Resource -eq "deviceManagement/deviceConfigurations/ring-1/deviceStatusOverview"
        }
    }

    It "Skips the device status request with -SkipDeviceStatus" {
        $Records = Get-IntuneUpdatePolicy -PolicyType "UpdateRing" -SkipDeviceStatus
        $Records[0].SucceededCount | Should -BeNullOrEmpty
        Should -Invoke -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -Times 0 -ParameterFilter {
            $Resource -like "*deviceStatusOverview"
        }
    }

    It "Only requests the selected policy types" {
        $Records = Get-IntuneUpdatePolicy -PolicyType "DriverUpdate", "FeatureUpdate"
        $Records.PolicyType | Should -Be @("FeatureUpdate", "DriverUpdate")
        Should -Invoke -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -Times 2 -Exactly
    }

    It "Keeps the update ring and warns when device status fails" {
        Mock -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -ParameterFilter { $Resource -like "*deviceStatusOverview" } -MockWith {
            throw "Forbidden"
        }
        Mock -ModuleName "IntuneUpdatePolicyReport" -CommandName "Write-Warning"
        $Records = Get-IntuneUpdatePolicy -PolicyType "UpdateRing"
        $Records.Count | Should -Be 1
        $Records[0].SucceededCount | Should -BeNullOrEmpty
        Should -Invoke -ModuleName "IntuneUpdatePolicyReport" -CommandName "Write-Warning" -Times 1
    }

    It "Returns nothing when the tenant has no update policies" {
        Mock -ModuleName "IntuneUpdatePolicyReport" -CommandName "Invoke-UpdatePolicyGraphRequest" -MockWith { }
        @(Get-IntuneUpdatePolicy).Count | Should -Be 0
    }
}

Describe "ConvertTo-UpdatePolicyHtmlReport" {
    BeforeAll {
        $Status = [PSCustomObject]@{ successCount = 10; errorCount = 2; failedCount = 0; conflictCount = 1; pendingCount = 0 }
        $Script:Records = @(
            (ConvertTo-UpdatePolicyRecord -PolicyType "UpdateRing" -Policy $Script:UpdateRing -DeviceStatus $Status),
            (ConvertTo-UpdatePolicyRecord -PolicyType "FeatureUpdate" -Policy $Script:FeatureUpdate),
            (ConvertTo-UpdatePolicyRecord -PolicyType "DriverUpdate" -Policy $Script:DriverUpdate)
        )
        $Script:Html = ConvertTo-UpdatePolicyHtmlReport -Records $Script:Records -GeneratedDateTime ([datetime]"2026-10-03 12:00")
    }

    It "Produces a complete HTML document" {
        $Script:Html | Should -Match "^<!DOCTYPE html>"
        $Script:Html | Should -Match "</html>\s*$"
        $Script:Html | Should -Match "Generated 2026-10-03 12:00"
    }

    It "HTML-encodes policy names" {
        $Script:Html | Should -Match ([regex]::Escape("Drivers &lt;manual&gt;"))
        $Script:Html | Should -Not -Match ([regex]::Escape("Drivers <manual>"))
    }

    It "Shows a section per policy type and notes empty types" {
        foreach ($Heading in @("Update rings", "Feature updates", "Quality updates", "Driver updates")) {
            $Script:Html | Should -Match "<h2>$($Heading)</h2>"
        }
        $Script:Html | Should -Match "No policies of this type."
    }

    It "Flags unassigned policies and update ring errors" {
        $Script:Html | Should -Match ([regex]::Escape("<td class=`"unassigned`">Not assigned</td>"))
        $Script:Html | Should -Match ([regex]::Escape("<td class=`"num bad`">2</td>"))
    }

    It "Renders an empty report without errors" {
        $Html = ConvertTo-UpdatePolicyHtmlReport -Records @()
        ([regex]::Matches($Html, "No policies of this type.")).Count | Should -Be 4
    }
}

Describe "Export-IntuneUpdatePolicyReport" {
    It "Writes the CSV and HTML files to a new folder" {
        $Records = @(ConvertTo-UpdatePolicyRecord -PolicyType "FeatureUpdate" -Policy $Script:FeatureUpdate)
        $OutputPath = Join-Path -Path $TestDrive -ChildPath "out"
        $Result = Export-IntuneUpdatePolicyReport -Records $Records -Path $OutputPath

        $Result.CsvPath | Should -Exist
        $Result.HtmlPath | Should -Exist
        $Csv = @(Import-Csv -Path $Result.CsvPath)
        $Csv.Count | Should -Be 1
        $Csv[0].DisplayName | Should -Be "Windows 11 24H2"
        $Csv[0].Assignments | Should -Be "Not assigned"
    }

    It "Writes a header-only CSV when there are no policies" {
        $Result = Export-IntuneUpdatePolicyReport -Records @() -Path $TestDrive -BaseName "Empty"
        (Get-Content -Path $Result.CsvPath -First 1) | Should -Match "^`"PolicyType`",`"DisplayName`""
        @(Import-Csv -Path $Result.CsvPath).Count | Should -Be 0
    }
}
