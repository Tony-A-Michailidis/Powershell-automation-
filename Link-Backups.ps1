<#
    .DESCRIPTION
        Gets the Recovery Services Vault of an RG and links the
        VMs of that RG to vault policies, according to VM tags

    .NOTES
        AUTHOR: Alex Imray Papineau
        LAST EDIT: 06 November 2019
        EDITOR: Alex Imray Papineau
#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = `
        "The name of the vault to link backups to")]
    [string] $VaultName = ""
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

("Logged in. Retrieving vault '{0}' and linkable VMs..." -f $VaultName)

# Retrieve vault to link
$VaultToLink = Get-AzureRmRecoveryServicesVault -Name $VaultName

# Init variables
$Policies = $null
$DFODaily = $null
$DFOWeekly = $null
$DFOMonthly = $null
$DFOLongDaily = $null
$DFOLongMonthly = $null
$Container = $null
$BkItem = $null

# Set vault and retrieve VMs in same RG
Set-AzureRmRecoveryServicesVaultContext -Vault $VaultToLink

$VMsInRG = @(Get-AzureRmVM -ResourceGroupName $VaultToLink.ResourceGroupName)
$VMsToLink = @()
$VMOutput = "VMs to link to vault:"
foreach ($RGVM in $VMsInRG)
{
    if ($RGVM.Location -eq $VaultToLink.Location)
    {
        $VMsToLink += $RGVM
        $VMOutput += "`n- " + $RGVM.Name
    }
}

if ($VMsToLink.Length -gt 0)
{
    Write-Output $VMOutput
}
else
{
    "No VMs to link in vault. Exiting."
    exit
}

# Retreive backup policies if needed
if ($null -eq $Policies)
{
    $Policies = @(Get-AzureRmRecoveryServicesBackupProtectionPolicy)
    $DFODaily = $Policies | Where-Object `
        -Property 'Name' -Value 'DFODaily' -EQ
    $DFOWeekly = $Policies | Where-Object `
        -Property 'Name' -Value 'DFOWeekly' -EQ
    $DFOMonthly = $Policies | Where-Object `
        -Property 'Name' -Value 'DFOMonthly' -EQ
    $DFOLongDaily = $Policies | Where-Object `
        -Property 'Name' -Value 'DFOLongDaily' -EQ
    $DFOLongMonthly = $Policies | Where-Object `
        -Property 'Name' -Value 'DFOLongMonthly' -EQ
}

$VaultSummary = ("Finished setting vault {0}'s VMs." -f $VaultToLink.Name `
    + "`nActivity summary:")

foreach ($VM in $VMsToLink)
{
    "Processing VM '{0}'..." -f $VM.Name
    $VaultSummary += "`n- " + $VM.Name

    # Based on backup tag existence and backup container
    # existence, do 1 of 4 actions
    $Container = Get-AzureRmRecoveryServicesBackupContainer `
        -ContainerType 'AzureVM' -BackupManagementType `
        'AzureVM' -FriendlyName $VM.Name

    if ($VM.Tags.Keys -notcontains 'Backup')
    {
        # No backup tag: Add with value None or Custom,
        # depending on whether backup container exists
        if ($null -eq $Container)
        {
            $VM.Tags.Add('Backup','None')
            $VaultSummary += " added Backup:None tag (1-1)"
        }
        else
        {
            $VM.Tags.Add('Backup','Custom')
            $VaultSummary += " added Backup:Custom tag (2-1)"
        }
        Set-AzureRmResource -Tag $VM.Tags `
            -ResourceId $VM.Id -Force -AsJob | Out-Null
    }
    else
    {
        # Tag exists but backup container is null:
        # enable/add policy (specific version of cmdlet)
        if ($null -eq $Container)
        {
            $StartBackup = $false

            if ($VM.Tags.Backup.ToLower() -eq 'daily')
            {
                Enable-AzureRmRecoveryServicesBackupProtection -Name $VM.Name `
                    -ResourceGroupName $VaultToLink.ResourceGroupName `
                    -Policy $DFODaily | Out-Null
                $VaultSummary += " newly linked to daily policy (3-1)"
                $StartBackup = $true
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'weekly')
            {
                Enable-AzureRmRecoveryServicesBackupProtection -Name $VM.Name `
                    -ResourceGroupName $VaultToLink.ResourceGroupName `
                    -Policy $DFOWeekly | Out-Null
                $VaultSummary += " newly linked to weekly policy (3-2)"
                $StartBackup = $true
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'monthly')
            {
                Enable-AzureRmRecoveryServicesBackupProtection -Name $VM.Name `
                    -ResourceGroupName $VaultToLink.ResourceGroupName `
                    -Policy $DFOMonthly | Out-Null
                $VaultSummary += " newly linked to monthly policy (3-3)"
                $StartBackup = $true
            }
            else
            {
                if ($VM.Tags.Backup.ToLower() -ne 'none')
                {
                    $VM.Tags.Backup = "None"
                    Set-AzureRmResource -Tag $VM.Tags `
                        -ResourceId $VM.Id -Force -AsJob
                    $VaultSummary += " updated Backup:None tag (3-4)"
                }
            }

            if ($StartBackup -eq $true)
            {
                $Container = Get-AzureRmRecoveryServicesBackupContainer `
                    -ContainerType 'AzureVM' -BackupManagementType `
                    'AzureVM' -FriendlyName $VM.Name

                $BkItem = Get-AzureRmRecoveryServicesBackupItem `
                    -Container $Container -WorkloadType AzureVM

                Backup-AzureRmRecoveryServicesBackupItem `
                    -Item $BkItem | Out-Null
                $VaultSummary += " (started backup)"
            }
        }
        # Tag and container both exist: get backup item and
        # update policy to match tag (specific version of cmdlet)
        else
        {
            $BkItem = Get-AzureRmRecoveryServicesBackupItem `
                -Container $Container -WorkloadType AzureVM

            if ($null -eq $BkItem)
            {
                $VM.Tags.Backup = "Custom"
                Set-AzureRmResource -Tag $VM.Tags `
                    -ResourceId $VM.Id -Force -AsJob | Out-Null
                $VaultSummary += (" backup item missing " `
                    + "(likely in different vault),")
            }

            if ($VM.Tags.Backup.ToLower() -eq 'daily')
            {
                Enable-AzureRmRecoveryServicesBackupProtection `
                    -Policy $DFODaily -Item $BkItem | Out-Null
                $VaultSummary += " linked to daily policy (4-1)"
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'weekly')
            {
                Enable-AzureRmRecoveryServicesBackupProtection `
                    -Policy $DFOWeekly -Item $BkItem | Out-Null
                $VaultSummary += " linked to weekly policy (4-2)"
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'monthly')
            {
                Enable-AzureRmRecoveryServicesBackupProtection `
                    -Policy $DFOMonthly -Item $BkItem | Out-Null
                $VaultSummary += " linked to monthly policy (4-3)"
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'ldaily')
            {
                Enable-AzureRmRecoveryServicesBackupProtection `
                    -Policy $DFOLongDaily -Item $BkItem | Out-Null
                $VaultSummary += " linked to long daily policy (4-4)"
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'lmonthly')
            {
                Enable-AzureRmRecoveryServicesBackupProtection `
                    -Policy $DFOLongMonthly -Item $BkItem | Out-Null
                $VaultSummary += " linked to long monthly policy (4-5)"
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'none')
            {
                Disable-AzureRmRecoveryServicesBackupProtection `
                    -Item $BkItem -RemoveRecoveryPoints -Force | Out-Null
                $VaultSummary += " unlinked from backup policy (4-6)"
            }
            elseif ($VM.Tags.Backup.ToLower() -eq 'custom')
            { $VaultSummary += " unchanged (4-7)" }
            else
            {
                $VM.Tags.Backup = 'Custom'
                Set-AzureRmResource -Tag $VM.Tags `
                    -ResourceId $VM.Id -Force -AsJob | Out-Null
                $VaultSummary += " updated Backup:Custom tag (4-6)"
            }
        }
    }
    # ("Finished setting " + $VM.Name + `
    #     "'s backup policy.") | Write-Output
}
# ("Finished setting " + $VaultToLink.Name + `
#     "'s vitual machines.") | Write-Output

$VaultSummary