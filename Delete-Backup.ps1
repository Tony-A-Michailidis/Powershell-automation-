<#
    .DESCRIPTION
        Triggered by a delete VM webhook, this script
        looks in a recovery services vault to see if
        the deleted VM has a backup to remove. If
        found, backup is deleted or alert is sent.

    .NOTES
        AUTHOR: Alex Imray Papineau
        LAST EDIT: 06 November 2019
        EDITOR: Alex Imray Papineau
#>

param
(
    [Parameter (Mandatory = $false)]
    [object] $WebhookData
)

if ($null -eq $WebhookData)
{ exit }
"Webhook valid. Parsing webhook data...`n"

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

# Parse webhook data into a useable info
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

# Extract useful information
$SubscriptionID = $SubStrings[2]
$ResourceGroup = $SubStrings[4]
$VmName = $SubStrings[$SubStrings.length - 1]
("Data acquired.`n- Sub ID: {0}`n- RG Name: {1}`n" `
    -f $SubscriptionID, $ResourceGroup + `
    "- VM Name: {0}`nConnecting to Azure account...`n" `
    -f $VmName)

# Retrieve vault
"Checking for container '{0}' in a vault within resource group '{1}'..." `
    -f $VmName, $ResourceGroup
$RGroupVaults = @(Get-AzureRmRecoveryServicesVault `
    -ResourceGroupName $ResourceGroup)
if ($RGroupVaults.Length -le 0)
{
    "No backup vaults found in '{0}'. Exiting..."-f $ResourceGroup
    exit
}

$IsBackup = $false
$IsAutoDelete = $false
$VaultName = ""

foreach ($RGVault in $RGroupVaults)
{
    # Check tags
    $Tags = (Get-AzureRmResource -ResourceId $RGVault.ID).Tags
    # $Tags
    if ($Tags.Keys -contains 'AutoDelete' -and $Tags.AutoDelete.ToLower() -eq 'true')
    { $IsAutoDelete = $true }
    else
    { $IsAutoDelete = $false }

    Set-AzureRmRecoveryServicesVaultContext -Vault $RGVault | Out-Null

    # Get container
    $Container = Get-AzureRmRecoveryServicesBackupContainer `
        -ContainerType 'AzureVM' -BackupManagementType 'AzureVM' `
        -FriendlyName $VmName
    if ($null -eq $Container)
    {
        $IsBackup = $false
        continue
    }
    else
    {
        $IsBackup = $true
        $VaultName = $RGVault.Name
        break
    }
}

if ($IsBackup -eq $true -and $IsAutoDelete -eq $true)
{
    # Delete backup
    $BackupItem = Get-AzureRmRecoveryServicesBackupItem `
        -Container $Container -WorkloadType 'AzureVM'
    Disable-AzureRmRecoveryServicesBackupProtection `
        -Item $BackupItem -RemoveRecoveryPoints -Force | Out-Null
    "Backup for '{0}' deleted. Exiting." -f $VmName
}
elseif ($IsBackup -eq $true)
{
    # Send notification
    $Message = "VM '{0}' in RG '{1}' was deleted. It has a backup in vault '{2}' that was not auto-deleted." `
    -f $VmName, $ResourceGroup, $VaultName
    "Sending the following alert to Teams:`n{0}" -f $Message

    $AlertURL = Get-AutomationVariable -Name 'TeamsURI'

    $JsonMessage = @{ "text" = $Message }
    $JsonMessage = ConvertTo-Json $JsonMessage

    $RestResult = Invoke-RestMethod -Uri $AlertURL -Method Post `
    -Body $JsonMessage -ContentType 'Application/Json'

    "Rest method result: {0}" -f $RestResult
}
else
{ "Container not found: no backup to delete. Exiting." }