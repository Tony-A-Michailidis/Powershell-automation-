<#
    .DESCRIPTION
        Iterates through RGs and ensures that recovery services
        vaults have the correct default backup policies.
        Optionally runs Link-Backups.ps1 on vaults

        Schedule: Weekly

    .NOTES
        AUTHOR: Alex Imray Papineau
        LAST EDIT: 06 November 2019
        EDITOR: Alex Imray Papineau
#>

Param(
    # Webhook-triggered
    [Parameter(Mandatory = $false)]
    [object] $WebhookData = $null,
    # Schedule-triggered
    [Parameter(Mandatory = $false, HelpMessage = `
        "The resource group in which to apply the operation")]
    [string] $ResourceGroup = "",
    # Needed to start other runbook
    [Parameter(Mandatory = $false)]
    [string] $AutoAccountName = "Training-Automation",
    [Parameter(Mandatory = $false)]
    [string] $AccountRG = "Training-RG",
    [Parameter(Mandatory = $false, HelpMessage = `
        "Whether to run the link-backups as jobs or sequence them")]
    [bool] $RunAsJob = $true
)

# Prevents runbook from continuing execution if there's an error - Alex
$ErrorActionPreference = "Stop"
Enable-AzureRmAlias -Scope Local

# Logging in -> Get connection and use for Az login
$Connection = Get-AutomationConnection -Name "AzureRunAsConnection"
$AzureProfile = Connect-AzAccount `
    -Tenant $Connection.TenantId `
    -CertificateThumbprint $Connection.CertificateThumbprint `
    -ApplicationId $Connection.ApplicationId `
    -ServicePrincipal `
    | Out-Null
$AzureProfile.Context.Subscription

if ($null -ne $WebhookData)
{
    #"Webhook run. Displaying raw webhook:`n{0}" -f $WebhookData
    try
    {
        $Webhook = $WebhookData
        "Display request body:`n{0}" -f $Webhook.RequestBody.ToString()
        Get-Member -InputObject $Webhook -Name "RequestBody" -MemberType Property
    }
    catch
    {
        "Cannot access request body. Converting webhook from JSON..."
        $Webhook = $WebhookData | ConvertFrom-Json
        #"Conversion complete"
    }

    try
    {
        $RequestBody = $Webhook.RequestBody
        "Display subject:`n{0}" -f $RequestBody.subject.ToString()
        Get-Member -InputObject $RequestBody -Name "subject" -MemberType Property
    }
    catch
    {
        "Cannot access subject. Converting request body from JSON..."
        $RequestBody = $Webhook.RequestBody | ConvertFrom-Json
        #"Conversion complete"
    }

    $SubStrings = $RequestBody.subject.Split('/')
    if ($SubStrings.Length -le 0)
    {
        "No substrings found in 'Webhook.RequestBody.subject'. Exiting."
        exit
    }
    else
    {
        $Message = "Data substrings parsed:"
        foreach($Sub in $SubStrings)
        { $Message += "`n- " + $Sub }
        $Message += "`n"
        # $Message
    }

    $ResourceGroup = $SubStrings[4]
    $VaultName = $SubStrings[8]

    "Webhook run.`nResource Group: {0}`nVault: {1}" `
        -f $ResourceGroup, $VaultName
}
else
{
    "Scheduled run.`nResource Group: {0}" `
        -f $ResourceGroup
}

"Initializing default DFO policies..."
$BackupPolicyNames = @()
# Enum (0 = ?, 1 = AzureVM, 2 = AzureSQLDatabase, 3 = AzureFiles, 4 = MSSQL)
$PolicyWorkload = 'AzureVM'
$SchedulePolicyObj = Get-AzureRmRecoveryServicesBackupSchedulePolicyObject `
    -WorkloadType 'AzureVM'
$RetentionPolicyObj = Get-AzureRmRecoveryServicesBackupRetentionPolicyObject `
    -WorkloadType 'AzureVM'

# Set start date as a time reference
$StartDate = Get-Date -Year 2019 -Month 5 -Day 31 -Hour 5 -Minute 30 -Second 0 -Millisecond 0
$StartDate = $StartDate.ToUniversalTime()

# Recreate the DFOdefaultVM schedule policy
$SchedulePolicyObj.ScheduleRunTimes.Clear()
$SchedulePolicyObj.ScheduleRunTimes.Add($StartDate)
$SchedulePolicyObj.ScheduleRunFrequency = 'Weekly'
$SchedulePolicyObj.ScheduleRunDays = @('Saturday')

# Recreate the DFOdefaultVM retention policy
$RetentionPolicyObj.IsDailyScheduleEnabled = $false
$RetentionPolicyObj.DailySchedule.DurationCountInDays = 7
$RetentionPolicyObj.DailySchedule.RetentionTimes.Clear()
$RetentionPolicyObj.DailySchedule.RetentionTimes.Add($StartDate)

$RetentionPolicyObj.IsWeeklyScheduleEnabled = $false
$RetentionPolicyObj.WeeklySchedule.DurationCountInWeeks = 4
$RetentionPolicyObj.WeeklySchedule.RetentionTimes.Clear()
$RetentionPolicyObj.WeeklySchedule.RetentionTimes.Add($StartDate)
$RetentionPolicyObj.WeeklySchedule.DaysOfTheWeek = `
    @('Saturday')

$RetentionPolicyObj.IsMonthlyScheduleEnabled = $false
$RetentionPolicyObj.MonthlySchedule.DurationCountInMonths = 3
$RetentionPolicyObj.MonthlySchedule.RetentionTimes.Clear()
$RetentionPolicyObj.MonthlySchedule.RetentionTimes.Add($StartDate)
$RetentionPolicyObj.MonthlySchedule.RetentionScheduleWeekly.DaysOfTheWeek = `
    @('Saturday')
$RetentionPolicyObj.MonthlySchedule.RetentionScheduleWeekly.WeeksOfTheMonth = `
    @('First')

$RetentionPolicyObj.IsYearlyScheduleEnabled = $false
$RetentionPolicyObj.YearlySchedule.DurationCountInYears = 1
$RetentionPolicyObj.YearlySchedule.RetentionTimes.Clear()
$RetentionPolicyObj.YearlySchedule.RetentionTimes.Add($StartDate)
$RetentionPolicyObj.YearlySchedule.RetentionScheduleWeekly.DaysOfTheWeek = `
    @('Saturday')
$RetentionPolicyObj.YearlySchedule.RetentionScheduleWeekly.WeeksOfTheMonth = `
    @('First')
$RetentionPolicyObj.YearlySchedule.MonthsOfYear = `
    @('January', 'July')

"Retrieving recovery vaults..."
$SubVaults = @()
if ($ResourceGroup -eq "")
{
    $SubVaults = @(Get-AzureRmRecoveryServicesVault)
}
else
{
    $SubVaults = @(Get-AzureRmRecoveryServicesVault `
        -ResourceGroupName $ResourceGroup)
}

"Parsing retrieved vaults via RG and region..."
$ValidVaults = @()
$RGandRegion = @{}
$ValidNames = @()
foreach ($SubVault in $SubVaults)
{
    if ($RGandRegion.ContainsKey($SubVault.ResourceGroupName))
    {
        if (!$RGandRegion[$SubVault.ResourceGroupName].Contains(`
            $SubVault.Location))
        {
            $RGandRegion[$SubVault.ResourceGroupName] += "," + $SubVault.Location
            $ValidVaults += $SubVault
            $ValidNames += "`n- " + $SubVault.Name
        }
    }
    else
    {
        $RGandRegion.Add($SubVault.ResourceGroupName, $SubVault.Location)
        $ValidVaults += $SubVault
        $ValidNames += "`n- " + $SubVault.Name
    }
}

"Checking backup protection policies of " + $ValidVaults.Count + `
    " vaults...`n" + $ValidNames + `
    "`n=====================================================" `
    | Write-Output
foreach ($VaVault in $ValidVaults)
{
    "Checking vault " + $VaVault.Name + "'s policies..." | Write-Output
    Set-AzureRmRecoveryServicesVaultContext -Vault $VaVault

    $BackupPolicyNames = @(Get-AzureRmRecoveryServicesBackupProtectionPolicy) `
        | Select-Object -Property Name

    for ($i = 0; $i -lt $BackupPolicyNames.Length; $i++)
    {
        $BackupPolicyNames[$i] = $BackupPolicyNames[$i].Name
    }

    if ($BackupPolicyNames -notcontains "DFODaily")
    {
        $RetentionPolicyObj.IsDailyScheduleEnabled = $true
        $SchedulePolicyObj.ScheduleRunFrequency = 'Daily'

        New-AzureRmRecoveryServicesBackupProtectionPolicy `
            -Name 'DFODaily' `
            -WorkloadType $PolicyWorkload `
            -SchedulePolicy $SchedulePolicyObj `
            -RetentionPolicy $RetentionPolicyObj `
            | Out-Null
        
        "Added new 'DFODaily' backup protection policy"
        $RetentionPolicyObj.IsDailyScheduleEnabled = $false
        $SchedulePolicyObj.ScheduleRunFrequency = 'Weekly'
    }

    if ($BackupPolicyNames -notcontains "DFOWeekly")
    {
        $RetentionPolicyObj.IsWeeklyScheduleEnabled = $true

        New-AzureRmRecoveryServicesBackupProtectionPolicy `
            -Name 'DFOWeekly' `
            -WorkloadType $PolicyWorkload `
            -SchedulePolicy $SchedulePolicyObj `
            -RetentionPolicy $RetentionPolicyObj `
            | Out-Null

        "Added new 'DFOWeekly' backup protection policy"
        $RetentionPolicyObj.IsWeeklyScheduleEnabled = $false
    }

    if ($BackupPolicyNames -notcontains "DFOMonthly")
    {
        $RetentionPolicyObj.IsWeeklyScheduleEnabled = $true
        $RetentionPolicyObj.WeeklySchedule.DurationCountInWeeks = 1
        $RetentionPolicyObj.IsMonthlyScheduleEnabled = $true

        New-AzureRmRecoveryServicesBackupProtectionPolicy `
            -Name 'DFOMonthly' `
            -WorkloadType $PolicyWorkload `
            -SchedulePolicy $SchedulePolicyObj `
            -RetentionPolicy $RetentionPolicyObj `
            | Out-Null

        "Added new 'DFOMonthly' backup protection policy"
        $RetentionPolicyObj.IsWeeklyScheduleEnabled = $false
        $RetentionPolicyObj.WeeklySchedule.DurationCountInWeeks = 4
        $RetentionPolicyObj.IsMonthlyScheduleEnabled = $false
    }

    if ($BackupPolicyNames -notcontains "DFOLongDaily")
    {
        $RetentionPolicyObj.IsDailyScheduleEnabled = $true
        $RetentionPolicyObj.IsMonthlyScheduleEnabled = $true
        $SchedulePolicyObj.ScheduleRunFrequency = 'Daily'

        New-AzureRmRecoveryServicesBackupProtectionPolicy `
            -Name 'DFOLongDaily' `
            -WorkloadType $PolicyWorkload `
            -SchedulePolicy $SchedulePolicyObj `
            -RetentionPolicy $RetentionPolicyObj `
            | Out-Null

        "Added new 'DFOLongDaily' backup protection policy"
        $RetentionPolicyObj.IsDailyScheduleEnabled = $false
        $RetentionPolicyObj.IsMonthlyScheduleEnabled = $false
        $SchedulePolicyObj.ScheduleRunFrequency = 'Weekly'
    }

    if ($BackupPolicyNames -notcontains "DFOLongMonthly")
    {
        $RetentionPolicyObj.IsWeeklyScheduleEnabled = $true
        $RetentionPolicyObj.WeeklySchedule.DurationCountInWeeks = 1
        $RetentionPolicyObj.IsMonthlyScheduleEnabled = $true
        $RetentionPolicyObj.IsYearlyScheduleEnabled = $true

        New-AzureRmRecoveryServicesBackupProtectionPolicy `
            -Name 'DFOLongMonthly' `
            -WorkloadType $PolicyWorkload `
            -SchedulePolicy $SchedulePolicyObj `
            -RetentionPolicy $RetentionPolicyObj `
            | Out-Null

        "Added new 'DFOLongMonthly' backup protection policy"
        $RetentionPolicyObj.IsWeeklyScheduleEnabled = $false
        $RetentionPolicyObj.WeeklySchedule.DurationCountInWeeks = 4
        $RetentionPolicyObj.IsMonthlyScheduleEnabled = $false
        $RetentionPolicyObj.IsYearlyScheduleEnabled = $false
    }

    $VaultResource = Get-AzureRmResource -ResourceId $VaVault.ID
    if ($VaultResource.Tags.Keys -notcontains 'AutoDelete')
    {
        "Adding 'AutoDelete:False' tag to {0}..." -f $VaVault.Name
        if ($null -eq $VaultResource.Tags)
        {
            $VaultResource.Tags = New-Object `
                'System.Collections.Generic.Dictionary[String,String]'
        }

        $VaultResource.Tags.Add('AutoDelete', 'False')
        Set-AzureRmResource -Tag $VaultResource.Tags `
            -ResourceId $VaultResource.Id -AsJob -Force | Out-Null
    }

    "Starting parallel Link-Backups task on " + $VaVault.Name + `
        "..." | Write-Output
    $args = @{ "VaultName" = $VaVault.Name; }

    if ($RunAsJob -eq $true)
    {
        Start-AzureRmAutomationRunbook `
            -AutomationAccountName $AutoAccountName `
            -Name 'Link-Backups' -ResourceGroupName $AccountRG `
            -Parameters $args `
            | Out-Null
    }
    else
    {
        $output = Start-AzureRmAutomationRunbook `
        -AutomationAccountName $AutoAccountName `
        -Name 'Link-Backups' -ResourceGroupName $AccountRG `
        -Parameters $args -Wait
        $output += "`n====================================================="
        $output
    }
}