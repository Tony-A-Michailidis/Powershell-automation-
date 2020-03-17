<#
    .DESCRIPTION
        Returns and posts in the related Teams channel information about resource costing for last week, per resource group. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
        inspired by https://octopus.com/blog/saving-cloud-dollars 
 #>
 
 $totalCost = 0 

function loginAzure 
{
    $connectionName = "AzureRunAsConnection"
    try
        {
            $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         
            "Logging in to Azure..."
            $azureaccount = Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
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
 "uri "+$uri
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

function Get-ParsedResult {
param ( [Parameter(Mandatory=$true)] [System.Object] $Results )
    $b = ""
    foreach ($row in $Results)  
    {
        $tempname = ""    
        $tempname = $row.name
        If ($tempname -ne "") {
            $b += "`n- <a href='https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$SubscriptionId/resourceGroups/$tempname/overview'>"+$tempname+"</a>: " + $row.Cost + "`n"
        }
    }
    Return ( $b )
}

function GetSpenders
{
    $body=""
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name     
    $SubscriptionId  = $CurrrentSub.ID 
    $DateRangeInDays = 7
    $now = get-Date
    $startDate = $($now.Date.AddDays(-$DateRangeInDays))
    $endDate = $($now.Date)
    $SubConsumptionUsage = Get-AzureRmConsumptionUsageDetail -StartDate $startDate -EndDate $endDate
    $SubIdPrefix = "/subscriptions/" + $SubscriptionId
    $RgIdPrefix = $SubIdPrefix + "/resourceGroups/"
    $resourceGroupName = @()
    $resourceGroups =  @()
    foreach ($line in $SubConsumptionUsage) {
        if ($line.InstanceId -ne $null ) {
            $thisRgName = $($line.InstanceId.ToLower()).Replace($RgIdPrefix.ToLower(),"")
            $toAdd = $thisRgName.Split("/")[0]
            $toAdd = $toAdd.ToString()
            $toAdd = $toAdd.ToLower()
            $toAdd = $toAdd.Trim()
            if ($resourceGroups.Name -notcontains $toAdd) 
                {
                    $resourceGroupName = [PSCustomObject]@{
                    Name = $toAdd
                        }
                            $resourceGroups += $resourceGroupName
                }
        }
    }
    $currentResourceGroups = Get-AzureRmResourceGroup
    $rgIndexId = 0
    foreach ($rg in $resourceGroups) {
        $RgIdPrefix = $SubIdPrefix + "/resourceGroups/" + $rg.Name
        $ThisRgCost = $null
        $SubConsumptionUsage | ? { if ( $_.InstanceId -ne $null) { $($_.InstanceId.ToLower()).StartsWith($RgIdPrefix.ToLower()) } } |  ForEach-Object { $ThisRgCost += $_.PretaxCost   }
        $toaddCost = [math]::Round($ThisRgCost,2)
        $resourceGroups[$rgIndexId] | Add-Member -MemberType NoteProperty -Name "Cost" -Value $toaddCost.tostring('C2')
        If ($rg.name -ne ""){$totalCost = $totalCost + $toaddCost}
        if ($currentResourceGroups.ResourceGroupName -contains $rg.Name) {
            $addingResourceGroup = Get-AzureRmResourceGroup -Name $($rg.Name)
            #future add if we need to also display the cost linit... $resourceGroups[$rgIndexId] | Add-Member -MemberType NoteProperty -Name "NotifyCostLimit" -Value $($addingResourceGroup.tags.NotifyCostLimit)
        }
    $rgIndexId ++
    }
    $resourceGroups
    if ($resourceGroups -ne "")
    {
        $a = (Get-ParsedResult -Results $resourceGroups) 
        $toPost = "`n Accumulated pre-tax estimated costs in the **"+$CurrrentSubName+"** subscription during past "+$DateRangeInDays+" days (grand total of **"+$totalCost.tostring('C2')+"**):`n"+$a
        postToTeams($toPost)
    }
}

loginAzure
GetSpenders
