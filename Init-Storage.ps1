<#
    .DESCRIPTION
        This script reacts to storage account creation or iterates through
        RGs and looks for uninitialized storage accounts.

        Initialization includes adding containers and lifecycle managment
        rules to the account, making them easy to start using efficiently
        out of the box.

        Schedule: Daily

    .NOTES
        AUTHOR: Alex Imray Papineau
        LAST EDIT: 06 November 2019
        EDITOR: Alex Imray Papineau
#>

Param(
    # Webhook triggered
    [Parameter(Mandatory = $false)]
    [object] $WebhookData = $null,
    # Schedule or manual trigger
    [Parameter(Mandatory = $false)]
    [string] $RGName = "",
    [Parameter(Mandatory = $false)]
    [string] $StorageName = ""
)

# Prevents runbook from continuing execution if there's an error - Alex
$ErrorActionPreference = "Stop"

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
$webhookRun = $null -ne $WebhookData
if ($webhookRun)
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
        $Message
    }

    # Extract useful information
    $RGName = $SubStrings[4]
    $StorageName = $SubStrings[8]

    "Webhook run.`n  Resource Group: {0}`n  Storage account: {1}" `
        -f $RGName, $StorageName
}
else
{
    "Scheduled or manual run.`n  Resource Group: {0}" `
        -f $RGName
}

# Creating lifecycle policy
$action = Add-AzStorageAccountManagementPolicyAction `
    -BaseBlobAction TierToCool -DaysAfterModificationGreaterThan 7
$filter = New-AzStorageAccountManagementPolicyFilter -PrefixMatch 'dfo-cool'
$coolrule = New-AzStorageAccountManagementPolicyRule `
    -Name 'DFO_Cool_Rule' -Action $action -Filter $filter

$action = Add-AzStorageAccountManagementPolicyAction `
    -BaseBlobAction TierToArchive -DaysAfterModificationGreaterThan 1
$filter = New-AzStorageAccountManagementPolicyFilter -PrefixMatch 'dfo-archive'
$archiverule = New-AzStorageAccountManagementPolicyRule `
    -Name 'DFO_Archive_Rule' -Action $action -Filter $filter

# Get storage account(s) from Webhook, ResourceGroup or Subscription
if ($RGName -ne '' -and $StorageName -ne '')
{
    $SelectedAccounts = @(Get-AzStorageAccount `
        -ResourceGroupName $RGName -Name $StorageName)
}
elseif ($RGName -ne '')
{ $SelectedAccounts = @(Get-AzStorageAccount -ResourceGroupName $RGName) }
else
{ $SelectedAccounts = @(Get-AzStorageAccount) }

$Message = "Retrieved and operating on following accounts:"
foreach ($SA in $SelectedAccounts)
{ $Message += "`n- " + $SA.StorageAccountName }
$Message

$policy = $null
$rules = @($coolrule, $archiverule)
$RightNow = Get-Date
$Diff = New-TimeSpan -Minutes 5

# Output format variables
$AccountsAndContainers = ""
$AccountsAndPolicies = ""

# Apply policy to selected storage accounts
foreach ($SA in $SelectedAccounts)
{
    if ($SA.Kind -eq 'Storage')
    { continue }

    if ($webhookRun -and $Diff -gt $RightNow.Subtract($SA.CreationTime))
    {
        $ContainerNames = (Get-AzStorageContainer -Context $SA.Context) | Select -ExpandProperty Name
        $AddedContainers = @()

        if ($ContainerNames -notcontains 'dfo-hot')
        { $AddedContainers = $AddedContainers + (New-AzStorageContainer -Name "dfo-hot" -Context $SA.Context -Permission Off) }

        # if ($ContainerNames -notcontains 'dfo-cool')
        # { $AddedContainers = $AddedContainers + (New-AzStorageContainer -Name "dfo-cool" -Context $SA.Context -Permission Off) }

        if ($ContainerNames -notcontains 'dfo-archive')
        { $AddedContainers = $AddedContainers + (New-AzStorageContainer -Name "dfo-archive" -Context $SA.Context -Permission Off) }

        $AccNames = ""
        foreach ($AddCon in $AddedContainers)
        { $AccNames += "`n  " + $AddCon.Name }
        $AccountsAndContainers += "`n- {0} {1}" -f $SA.StorageAccountName, $AccNames
    }

    try
    { 
        $policy = Get-AzStorageAccountManagementPolicy -StorageAccount $SA
        $policy.Rules = $policy.Rules + $rules
        Set-AzStorageAccountManagementPolicy `
            -Policy $policy -StorageAccount $SA
    }
    catch
    {
        $policy = Set-AzStorageAccountManagementPolicy `
            -StorageAccount $SA -Rule $rules
    }

    $AccountsAndPolicies += "`n  policy '{0}' in '{1}'" -f $policy.Name, $SA.StorageAccountName
    # "Assigned rules '{0}' and '{1}' to policy '{2}' on storage account '{3}'" `
    #     -f $coolrule.Name, $archiverule.Name, $policy.Name, $SA.StorageAccountName
}

if ($webhookRun)
{ "Added specified containers to the following accounts:{0}" -f $AccountsAndContainers }

"Assigned rules '{0}' and '{1}' to the following accounts and policies:{2}" `
    -f $coolrule.Name, $archiverule.Name, $AccountsAndPolicies