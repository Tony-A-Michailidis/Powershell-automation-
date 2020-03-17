<#
    .DESCRIPTION
        Returns and posts to the related Teams channel (TeamsURI) performance characteristics of
        the VMs in the subscription the automation account lives. Future additions to get the same
        for the app service using Get-AzureRmAppServicePlanMetrics and 
        Get-AzureRmWebAppMetrics for apps and web apps. If Azure decides to deprecate any cmdlt
        adjust as necessary to use the new one, if any, or change to query the log instead for the 
        same values. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
#>

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
            $json1
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

function LoginToAzure
{
    # To test outside of Azure Automation, replace this block with Login-AzureRmAccount
    $connectionName = "AzureRunAsConnection"
    try
    {
        # Get the connection "AzureRunAsConnection "
        $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName        
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


function GetMetricsForCurrentSub
{
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrentSubId = $CurrrentSub.id
    $subname = $CurrrentSub.name
    $VMs = Get-AzureRmVM
    $body = ""
    $natta = ""
    $toPost = ""
    foreach ($vm in $VMs)
        {        
            $rgName = Get-AzureRmVM  | where {$_.ID -eq $vm.ID} | Select-Object -ExpandProperty ResourceGroupName
            $ResourceId = "/subscriptions/" + $CurrentSubId + "/resourceGroups/" + $rgName + "/providers/Microsoft.Compute/virtualMachines/" + $vm.name 
            $st = (get-date).AddDays(-7)
            $et = (get-date)
            
            $percentage_cpu_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Percentage CPU" # Percentage
            $network_in_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Network IN" # Bytes
            $network_out_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Network Out" # Bytes
          <#  $disk_read_bytes_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Disk Read Bytes" # Bytes Per Second
            $disk_write_bytes_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Disk Write Bytes" # Bytes Per Second
            $disk_read_operations_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Disk Read Operations/Sec" # Count Per Second
            $disk_write_operations_data = get-azurermmetric -ResourceId $vm.id -TimeGrain 00:01:00 -StartTime $st -EndTime $et -MetricName "Disk Write Operations/Sec" # Count Per Second
            
            $percentage_cpu_data.Data[-2].Average
            $network_in_data.Data[-2].Total
            $network_out_data.Data[-2].Total
            $disk_read_bytes_data.Data[-2].Average
            $disk_write_bytes_data.Data[-2].Average
            $disk_read_operations_data.Data[-2].Average
            $disk_write_operations_data.Data[-2].Average 
            #>
            $vmpath = "<a href='https://portal.azure.com/#@086gc.onmicrosoft.com/resource"+$ResourceId+"'>" + $VM.name + "</a>"
            if ($percentage_cpu_data.Data[-2].Average -gt 0)
                {
                    $body = $body + "`n- " + $vmpath + " avg CPU: **" + [math]::Round($percentage_cpu_data.Data[-2].Average,2) + "%**, network-in: " + [math]::Round($network_in_data.Data[-2].Total/1000000,2) + " MB, network-out: " + [math]::Round($network_out_data.Data[-2].Total/1000000,2) + " MB`n"
                }
            else                         
               {
                    $natta = $natta + $vmpath + " "
               }
        }
    If ($natta -ne "" -and $body -ne "")
        {
            $toPost = "VM metrics recorded during last week in the " + $subname + " subscription.`n`n" + $body + "`n`nThe following VMs report no significant activity:`n`n- "+ $natta +" `n`nAll numbers are rounded up, consult each VM's Metrics blade for detailed reports. [Get-AzureRmMetric] Parameter deprecation: The DetailedOutput parameter will be deprecated in a future breaking change release (then we switch to log analytics)."   
        }
    else 
        {
           if ($body -ne "") 
                {
                    $toPost = "VM metrics recorded during last week in the " + $subname + " subscription.`n`n" + $body +"`n`n`nAll numbers are rounded up, consult each VM's Metrics blade for detailed reports. [Get-AzureRmMetric] Parameter deprecation: The DetailedOutput parameter will be deprecated in a future breaking change release (then we switch to log analytics)."   
                }
           else
                {
                    $toPost = "All VMs in the " + $subname + " subscription (list below) have logged no significant metrics during last week:`n`n- "+ $natta +" `n`n Consult each VM's Metrics blade for detailed reports. [Get-AzureRmMetric] Parameter deprecation: The DetailedOutput parameter will be deprecated in a future breaking change release (then we switch to log analytics)."     
                }
        }        
    postToTeams($toPost)
}    

LoginToAzure
GetMetricsForCurrentSub
