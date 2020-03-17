<#
DESCRIPTION
    Iterates through storage accounts and updates blob access tiers based on account rules specified by tags and blobs' last modfied time.

    Until lifecycle management is global and out of preview, we'll be imitating it with this script

NOTES
    Author: Alex Imray Papineau
    Last edit: 11-Feb 2019
    Edit by: Alex Imray Papineau
#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = "The subscription name of ID to get storage accounts from")]
    [string] $Subscription = "",
    [Parameter(Mandatory = $false, HelpMessage = "The specific resource group from which to get storage accounts")]
    [string] $ResourceGroupName = "",
    [Parameter(Mandatory = $false, HelpMessage = "Whether to output all the logs")]
    [bool] $FullLogs = $false
)

# Prevents runbook from continuing execution if there's an error - Alex IP
$ErrorActionPreference = "Stop"

# Acquiring Service Principal to allow authentication
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName         

    if ($FullLogs) {"Logging in to Azure..."}

    if ($Subscription -eq "")
    {
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
    }
    else
    {
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
            -Subscription $Subscription
    }
}
catch 
{
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } 
    else
    {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

# Retrieve collection of all storage accounts from subscription
if ($FullLogs) {"Retrieving storage accounts..."}

if ($ResourceGroupName -eq "")
{
    $SubStorageAccounts = @(Get-AzureRmStorageAccount)
}
else
{
    $SubStorageAccounts = @(Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName)
}

$CurrentTime = Get-Date

if ($SubStorageAccounts.Length -le 0)
{
    if ($ResourceGroupName -eq "")
    { "No storage accounts found in subscription '" + $Subscription + "'" }
    else 
    { "No storage accounts found in resource group '" + $ResourceGroupName + "'" }
}
else
{
    foreach ($Account in $SubStorageAccounts)
    {
        if ($FullLogs) { "Processing storage account '" + $Account.StorageAccountName + "'..." }

        $ChillBlobs = $Account.Tags.ContainsKey("days2cold")
        $FreezeBlobs = $Account.Tags.ContainsKey("days2archive")
        $DeleteBlobs = $Account.Tags.ContainsKey("days2delete")
        
        if (!$ChillBlobs -and !$FreezeBlobs -and !$DeleteBlobs)
        {
            if ($FullLogs) { "Account '" + $Account.StorageAccountName + "' does not have any storage rules. Skipping..." }
        }
        else 
        {
            $AccountChangeSummary = $Account.StorageAccountName + " change summary:"
            $Containers = @()
            $Blobs = @()

            if ($ChillBlobs)
            { 
                $ChillInterval = [double]($Account.Tags["days2cold"])
                $AccountChangeSummary += " (" + $ChillInterval + " day cool rule)"
            }

            if ($FreezeBlobs) 
            { 
                $FreezeInterval = [double]($Account.Tags["days2archive"])
                $AccountChangeSummary += " (" + $FreezeInterval + " day archive rule)"
            }            

            if ($DeleteBlobs)
            {
                $DeleteInterval = [double]($Account.Tags["days2delete"])
                $AccountChangeSummary += " (" + $DeleteInterval + " day delete rule)"
            }

            try
            {
                $Containers = @(Get-AzureStorageContainer -Context $Account.Context)    
            }
            catch
            {
                if ($FullLogs)
                {
                    "Failed to retrieve containers from '" + $Account.StorageAccountName +
                    "'. Error message:`n" + $_.Exception + "Skipping account...`n"
                }
                continue
            }

            if ($null -eq $Containers -or $Containers.Length -le 0)
            {
                if ($FullLogs) {"No containers found in '" + $Account.StorageAccountName + "'. Skipping...`n"}
                continue
            }

            foreach ($Container in $Containers)
            {
                if ($FullLogs) {"Getting blobs in '" + $Container.Name +"'..."}
        
                $Blobs = @($Container | Get-AzureStorageBlob)
                
                if ($null -eq $Blobs -or $Blobs.Length -le 0)
                {
                    if ($FullLogs) {"No blobs found in '" + $Container.Name + "'. Skipping..."}
                    continue
                }
                
                $ContainerChangeSummary = ""
                $BlobsChanged = 0

                # Iterate through blobs and set to archive as necessary
                for ($i = 0; $i -lt $Blobs.Length; $i++)
                {
                    if ($Blobs[$i].BlobType -ne "BlockBlob")
                    {
                        continue
                    }
                    $BlockBlob = [Microsoft.WindowsAzure.Storage.Blob.CloudBlockBlob]($Blobs[$i].ICloudBlob)

                    $BlobTier = $BlockBlob.Properties.StandardBlobTier
                    
                    if ($BlobTier -eq "Hot" -and $ChillBlobs)
                    {
                        $ModifiedOffset = $CurrentTime.Subtract($Blobs[$i].LastModified.DateTime)

                        if ($ModifiedOffset.TotalDays -gt $ChillInterval)
                        {
                            $ChillTask = $BlockBlob.SetStandardBlobTierAsync("Cool")
                            if ($null -ne $ChillTask.Exception)
                            {
                                $ContainerChangeSummary += "`n- " + $BlockBlob.Name + " cool failed"
                                if ($FullLogs) { $ContainerChangeSummary += ":`n`t" + $ChillTask.Exception.Message }
                                $BlobsChanged++
                            }
                            else
                            {
                                $ContainerChangeSummary += "`n- " + $BlockBlob.Name + " cooled"
                                $BlobsChanged++
                            }
                        }
                    }
                    elseif ($BlobTier -ne "Archive" -and $FreezeBlobs)
                    {
                        $ModifiedOffset = $CurrentTime.Subtract($Blobs[$i].LastModified.DateTime)

                        if ($ModifiedOffset.TotalDays -gt $FreezeInterval)
                        {
                            $FreezeTask = $BlockBlob.SetStandardBlobTierAsync("Archive")
                            if ($null -ne $FreezeTask.Exception)
                            {
                                $ContainerChangeSummary += "`n- " + $BlockBlob.Name + " archive failed"
                                if ($FullLogs) { $ContainerChangeSummary += ":`n`t" + $FreezeTask.Exception.Message }
                                $BlobsChanged++
                            }
                            else
                            {
                                $ContainerChangeSummary += "`n- " + $BlockBlob.Name + " archived"
                                $BlobsChanged++
                            }
                        }
                    }
                    elseif ($DeleteBlobs)
                    {
                        $ModifiedOffset = $CurrentTime.Subtract($Blobs[$i].LastModified.DateTime)

                        if ($ModifiedOffset.TotalDays -gt $DeleteInterval)
                        {
                            $DeleteTask = $BlockBlob.DeleteAsync()
                            if ($null -ne $DeleteTask.Exception)
                            {
                                $ContainerChangeSummary += "`n- " + $BlockBlob.Name + " delete failed"
                                if ($FullLogs) { $ContainerChangeSummary += ":`n`t" + $DeleteTask.Exception.Message }
                                $BlobsChanged++
                            }
                            else
                            {
                                $ContainerChangeSummary += "`n- " + $BlockBlob.Name + " deleted"
                                $BlobsChanged++
                            }
                        }
                    }
                }

                if ($BlobsChanged -gt 0)
                {
                    $AccountChangeSummary += "--" + $Container.CloudBlobContainer.Name + `
                        " (" + $BlobsChanged + ")--" + $ContainerChangeSummary
                }
            }

            $AccountChangeSummary + "`n"
        }
    }
}