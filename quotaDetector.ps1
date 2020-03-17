<#
    .DESCRIPTION
        If we ever get close to the quota for resources or disks etc on the sub (at 80%) the runbook will alert us with a post on the related Teams channel. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
        inspired by ... https://blogs.msdn.microsoft.com/tomholl/2017/06/11/get-alerts-as-you-approach-your-azure-resource-quotas/ 
#>


function LoginToAzure
{
    # To test outside of Azure Automation, replace this block with Login-AzureRmAccount
    $connectionName = "AzureRunAsConnection"
    try
    {
        # Get the connection "AzureRunAsConnection "
        $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName        
        "Logging in to Azure..."
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint   $servicePrincipalConnection.CertificateThumbprint 
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
}
 
function postToTeams ([string]$teamsMessage)
{
    try
        { 
            $uri = Get-AutomationVariable -Name 'TeamsURI'   
            $uri = [uri]::EscapeUriString($uri)         
            $payload1 = @{
            "text" = $teamsMessage
            }
            $json1 = ConvertTo-Json $payload1   
            Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
        }
    Catch
        {
            $ErrorMessage = $_.Exception.Message
            $FailedItem = $_.Exception.ItemName
            Write-Error "We failed to read $FailedItem. The error message was $ErrorMessage"
            Break
        }   
}

function GetVMQuota
{
    $flag = 0
    $varvar =""
    foreach ($location in $locations)
    {
        $vmQuotas = Get-AzureRmVMUsage -Location $location 
        $vmQuotas
        foreach($vmQuota in $vmQuotas)
            {
                $usage = 0
                if ($vmQuota.Limit -gt 0) 
                    { 
                        $usage = $vmQuota.CurrentValue / $vmQuota.Limit * 100
                        $usage = ([Math]::Round($usage, 2))
                    }   
                if ($usage -gt 80) 
                    { 
                        $varvar += "`n"+"- "+$vmQuota.Name.LocalizedValue +" usage in "+$location+" is at "+$usage+"% (consider requesting an increase)`n"
                        $flag++
                    }     
            }    
    }
    if ($flag -gt 0)
        {
            $toPost = "`n In the **"+$CurrrentSubName+"** subscription:`n"+$varvar
            postToTeams($toPost)    
        }
}     
        
function GetStorageQuota
{
    $flag = 0
    $varvar =""
    foreach ($location in $locations)
    {
        $storageQuotas = Get-AzureRmStorageUsage -location $location
        foreach ($storageQuota in $storageQuotas)
            {
                $usage = 0
                if ($storageQuota.Limit -gt 0) 
                    { 
                        $usage = $storageQuota.CurrentValue / $storageQuota.Limit * 100 
                        $usage = ([Math]::Round($usage, 2))
                    }
                if ($usage -gt 80) 
                    { 
                        $varvar += "`n"+"- Storage usage in "+$location+" is at "+$usage+"% (consider requesting an increase)`n"
                        $flag++
                    }     
            }    
    }
    if ($flag -gt 0)
        {
            $toPost = "`n In the **"+$CurrrentSubName+"** subscription:`n"+$varvar
            postToTeams($toPost)    
        } 
}     

function GetNetworkQuota
{
    $flag = 0
    $varvar =""
    foreach ($location in $locations)
    {
        $networkQuotas = Get-AzureRmNetworkUsage -location $location
        foreach ($networkQuota in $networkQuotas)
        {
            $usage = 0
            if ($networkQuota.limit -gt 0) 
                { 
                    $usage = $networkQuota.currentValue / $networkQuota.limit * 100
                    $usage = ([Math]::Round($usage, 2))
                }
            if ($usage -gt 80) 
                { 
                    if ($networkQuota.name.localizedValue -ne "Network Watchers")
                        {   
                            $varvar += "`n"+"- "+$networkQuota.name.localizedValue +" usage in "+$location+" is at "+$usage+"% (consider requesting an increase)`n"
                            $flag++
                        }
                }    
        }  
    }
   if ($flag -gt 0)
        {
            $toPost = "`n In the **"+$CurrrentSubName+"** subscription:`n"+$varvar
            postToTeams($toPost)  
        } 
} 

[string[]]$locations = "CanadaCentral", "CanadaEast"
LoginToAzure
$CurrrentSub = (Get-AzureRmContext).Subscription
$CurrrentSubName = $CurrrentSub.Name
GetStorageQuota
GetVMQuota
GetNetworkQuota
 