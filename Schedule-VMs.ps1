<#
    .DESCRIPTION
        Handles the turning on and shutting off of VMs based on 3
        factors:on/off schedule, update schedule, and currently updating

    .NOTES
        Author: Alex Imray Papineau
        Last Edit: 18 October 2019
        Editor: Alex Imray Papineau
#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = `
        "The resource group in which to apply the operation, if any")]
    [string]
    $ResourceGroup = "",
    [Parameter(Mandatory = $false, HelpMessage = `
        "When Debug is active, runbook will wait for VM operations to return an output")]
    [switch] $DebugOutput
)

# Prevents runbook from continuing execution if there's an error - Alex
$ErrorActionPreference = "Stop"

# Logging in -> 
$TenantId = "" #your tenantid
$CertificateThumb = #your runbook cert
$ApplicationId = "" # your runbook acc id 

$Profile = Connect-AzAccount `
    -Tenant $TenantId `
    -CertificateThumbprint $CertificateThumb `
    -ApplicationId $ApplicationId `
    -ServicePrincipal `
    | Out-Null

<# Sets three state flags: Startup, Update, and Shutdown
If Startup, VM needs to start
If Update, VM is updating
If Shutdown, VM needs to shutdown
This allows the method's effective ouput to be more complex
without requiring state-specific strings. Method's actual
output will be warning or error messages #>
function Get-VirtualMachineState($VmTags, $LocalTime, `
    [ref] $StartupFlag, [ref] $UpdateFlag, [ref] $ShutdownFlag)
{
    $returnString = ""

    # Check that Startup/Shutdown tag values match Regex for time range of 00:00-23:59
    if ($VmTags.ContainsKey("Shutdown") -and $VmTags["Shutdown"] `
        -match "^([01]?[0-9]|2[0-3]):[0-5][0-9]$")
    {
        # Valid Shutdown tag
        $shutdownTime = [DateTime]$VmTags["Shutdown"]
        
        if ($VmTags.ContainsKey("Startup") -and $VmTags["Startup"] `
            -match "^([01]?[0-9]|2[0-3]):[0-5][0-9]$")
        {
            # Also valid startup tag
            $startupTime = [DateTime]$VmTags["Startup"]

            if ($LocalTime -ge $startupTime -and $LocalTime -lt $shutdownTime -and `
                ($LocalTime.DayOfWeek -ne "Saturday" -and $LocalTime.DayOfWeek -ne "Sunday"))
            { $StartupFlag.Value = $true }
            else
            { $ShutdownFlag.Value = $true }
        }
        elseif ($LocalTime -ge $shutdownTime)
        { $ShutdownFlag.Value = $true }
    }

    # Something previously marked this resource as needing a shutdown
    if ($VmTags.ContainsKey("Needs_Shutdown"))
    {
        $ShutdownFlag.Value = $true
    }

    #Set our update time to the default.
    $defaultUpdate = "sun_22:00"
    $updateDayPrefix = $defaultUpdate.Split('_')[0]
    $inUpdateTime = [DateTime]$defaultUpdate.Split('_')[1]
    #Check that Update tag value matches Regex for day and time
    if ($VmTags.ContainsKey("Update") -and $VmTags["Update"].ToLower() `
        -match "^(mon|tue|wed|thu|fri|sat|sun)_([01]?[0-9]|2[0-3]):00$")
    {
        #Overwrite the default time with the vm specified time.
        $updateDayPrefix = $VmTags["Update"].Split('_')[0]
        $inUpdateTime = [DateTime]$VmTags["Update"].Split('_')[1]
    }
    $timeUpdateDiff = $LocalTime - $inUpdateTime
    # The timeslot length should match the interval between scheduler.ps1
    # runs -> more edge cases may need to be handled otherwise
    $timeSlotLength = New-TimeSpan -Minutes 59

    # Check for Update_State tag, which indicates an update is
    # happening or is finished (and takes priority over timeslot)
    if ($VmTags.ContainsKey("Update_State"))
    {
        if ($VmTags["Update_State"].ToLower() -ne "ready" `
            -or $timeUpdateDiff -lt (New-TimeSpan -Minutes 110))
        { $UpdateFlag.Value = $VmTags["Update_State"].ToLower() -ne "done" }
        else
        {
            $returnString += ("WARNING! Resource was running in Update State 'ready' for" `
                + " nearly 2 hours. Update service may not be running on this resource.")
        }
    }
    # Check if we're within this Resource's Update timeslot
    elseif ($LocalTime.DayOfWeek.ToString().ToLower().Contains($updateDayPrefix) -and `
        $timeUpdateDiff.TotalMinutes -ge 0 -and $timeUpdateDiff -lt $timeSlotLength)
    { $UpdateFlag.Value = $true }

    return $returnString
}

$CurrentDate = Get-Date
$timeZoneIDs = @{
    "PST"               ="Pacific Standard Time";
    "MST"               ="Mountain Standard Time";
    "CST"               ="Central Standard Time";
    "EST"               ="Eastern Standard Time";
    "AST"               ="Atlantic Standard Time";
    "NST"               ="Newfoundland Standard Time";
    "UTC"               ="UTC";
    "GMT"               ="Greenwich Standard Time";
}

if ($ResourceGroup -eq "")
{
    "Retrieving VMs in {0} at {1}..." `
        -f $Profile.Context.Subscription, $CurrentDate
    $VirtualMachines = @(Get-AzVM)
}
else
{
    "Retrieving VMs in {0} within {1} at {2}..." `
        -f $ResourceGroup, $Profile.Context.Subscription, $CurrentDate
    $VirtualMachines = @(Get-AzVM -ResourceGroupName $ResourceGroup)
}
"Processing {0} VMs..." -f $VirtualMachines.Count

# Iterate through VMs and update state according to tags
foreach ($VMachine in $VirtualMachines) 
{
    $needsStartup = $false
    $inUpdateTime = $false
    $needsShutdown = $false
    $VmMessage = "'{0}' " -f $VMachine.Name

    # Skip if 'Schedule' tag missing or 'false'
    if (!$VMachine.Tags.ContainsKey("Schedule") -or `
        $VMachine.Tags["Schedule"].ToLower() -eq "false")
    {
        $VmMessage += "is unscheduled. Skipping..."
        $VmMessage
        continue
    }

    # Get the VM's local time based on its timezone
    $ScheduleTimeZone = "EST"
    if ($VMachine.Tags["Schedule"].ToLower() -ne "true")
    { $ScheduleTimeZone = $VMachine.Tags["Schedule"].ToUpper() }
    $LocalTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(`
        $CurrentDate, $timeZoneIDs[$ScheduleTimeZone])
    $VmMessage += "is {0} scheduled:" -f $ScheduleTimeZone

    # Check if VM state
    $VmStateMessage = Get-VirtualMachineState `
        -VmTags $VMachine.Tags `
        -LocalTime $LocalTime `
        -Startup ([ref]$needsStartup) `
        -Update ([ref]$inUpdateTime) `
        -Shutdown ([ref]$needsShutdown)
    $VmMessage += "`nStartup={0} Shutdown={1} Update={2}" `
        -f $needsStartup, $needsShutdown, $inUpdateTime

    # Error message output
    if ($VmStateMessage -ne "" -and $DebugOutput)
    { $VmMessage += "`nMessage: {0}" -f $VmStateMessage }

    # A schedule or an update marked the resource as needing shutdown
    if ($needsShutdown)
    {
        if ($inUpdateTime)
        {
            if (!$VMachine.Tags.ContainsKey("Needs_Shutdown"))
            {
                $VMachine.Tags.Add("Needs_Shutdown", "") | Out-Null
                # Set-AzureRmResource -ResourceId $VMachine.ResourceId `
                #     -Tag $VMachine.Tags -Force -AsJob | Out-Null
                $VmMessage += "`n  Action: Added 'Needs_Shutdown' tag"
            }
        }
        else
        {
            $VmInstance = Get-AzVM -Status -ResourceGroupName `
                $VMachine.ResourceGroupName -Name $VMachine.Name

            if ($VmInstance.Statuses.DisplayStatus.Contains("VM running") -and !$needsStartup)
            # The last !$needsStartup is in case ansible fails to shutdown the VM.
            # It prevents vm shutdown & startup in same scheduler run
            {
                if ($DebugOutput)
                {
                    $VmMessage += (Stop-AzVM -ResourceGroupName `
                        $VMachine.ResourceGroupName -Name $VMachine.Name -Force)
                }
                else
                {
                    Stop-AzVM -ResourceGroupName $VMachine.ResourceGroupName `
                        -Name $VMachine.Name -Force | Out-Null
                }
                $VmMessage += "`n  Action: Shutdown VM"
            }

            if ($VMachine.Tags.ContainsKey("Needs_Shutdown"))
            {
                $VMachine.Tags.Remove("Needs_Shutdown") | Out-Null
                # Set-AzureRmResource -ResourceId $VMachine.ResourceId `
                #     -Tag $VMachine.Tags -Force -AsJob | Out-Null
                $VmMessage += "`n  Action: Removed 'Needs_Shutdown' tag"
            }
        }
    }

    # Resource needs starting, either due to schedule or update timeslot
    if ($needsStartup -or $inUpdateTime)
    {
        $VmInstance = Get-AzVM -Status -ResourceGroupName `
            $VMachine.ResourceGroupName -Name $VMachine.Name

        if (!$VmInstance.Statuses.DisplayStatus.Contains("VM running"))
        {
            if ($DebugOutput)
            { $VmMessage += (Start-AzVM -Id $VMachine.Id) }
            else
            { Start-AzVM -Id $VMachine.Id -AsJob | Out-Null }
            # Start-AzureRmVM -ResourceGroupName $VMachine.ResourceGroupName `
            #     -Name $VMachine.Name -AsJob | Out-Null
            $VmMessage += "`n  Action: Started VM"
        }
        # This is to handle when $needsStartup is true during an update timeslot
        elseif ($needsStartup -and $VMachine.Tags.ContainsKey("Needs_Shutdown"))
        {
            $VMachine.Tags.Remove("Needs_Shutdown") | Out-Null
            # Set-AzureRmResource -ResourceId $VMachine.ResourceId `
            #     -Tag $VMachine.Tags -Force -AsJob | Out-Null
            $VmMessage += "`n  Action: Removing 'Needs_Shutdown' tag"
        }
    }

    # Resource is starting or finishing an update
    if ($inUpdateTime)
    {
        if (!$VMachine.Tags.ContainsKey("Update_State"))
        {
            $VMachine.Tags.Add("Update_State", "Ready") | Out-Null
            # Set-AzureRmResource -ResourceId $VMachine.ResourceId `
            #     -Tag $VMachine.Tags -Force | Out-Null
            $VmMessage += "`n  Action: Adding 'Update_State : Ready' tag"
        }
    }
    elseif ($VMachine.Tags.ContainsKey("Update_State"))
    {
        $VMachine.Tags.Remove("Update_State") | Out-Null
        # Set-AzureRmResource -ResourceId $VMachine.ResourceId `
            #     -Tag $VMachine.Tags -Force | Out-Null
        $VmMessage += "`n  Action: Removing 'Update_State' tag"
    }

    # Update the VM's tags, output activity summary for this VM
    if ($DebugOutput)
    {
        $UpdateResult = Update-AzVM -Id $VMachine.Id `
        -VM $VMachine -Tag $VMachine.Tags 
        $VmMessage += "`nUpdate success: {0}`nResult message: {1}" `
            -f $UpdateResult.IsSuccessStatusCode, `
            $UpdateResult.ReasonPhrase
    }
    else
    {
        Update-AzVM -Id $VMachine.Id -VM $VMachine `
            -Tag $VMachine.Tags -AsJob | Out-Null
    }
    $VmMessage
}