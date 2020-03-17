<#
    .DESCRIPTION
        Goes through all the VMs in the RG and looks for MicrosoftMonitoringAgent and IaaSAntimalware, if VM is on the network, and if it has backup on, reports
        to Teams if any of this fails (note that backup is really optional and up to the client to determine). Yes we can do the same with Policy, but we do need
        to get the message out beyond the portal... 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 4 Nov 2019
        EDITOR: Tony Mchailidis         
#>
 
function loginAzure 
    {
        try
            {
                $TenantId =  Get-AutomationVariable -Name 'TenantId'
                $CertificateThumb = Get-AutomationVariable -Name 'CertificateThumb'
                $ApplicationId =  Get-AutomationVariable -Name 'ApplicationId'
                Connect-AzAccount -Tenant $TenantId -CertificateThumbprint $CertificateThumb -ApplicationId $ApplicationId -ServicePrincipal | Out-Null
            }
        catch 
            {
                Write-Error -Message $_.Exception
                throw $_.Exception
            }
    }

function postToTeams ([string]$teamsMessage)
{
    try
        {
            $uri = Get-AutomationVariable -Name 'TestURI' 
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
     
function WarnAboutVMs 
{
    $fullName= ""
    $VMvNetName = ""
    $notInVnet = ""
    $CurrrentSub = (Get-AzContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name
    $CurrentSubId = $CurrrentSub.id
    $VMs = Get-AzVM
    Foreach ($VM in $VMs)
    {
        $namevm = $VM.Name
        $resname = $VM.ResourceGroupName
        $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$resname/providers/Microsoft.Compute/virtualMachines/$namevm/extensions`n"
        $extensions = Get-AzVMExtension -ResourceGroupName $resname -VMName $namevm 
        If ($vm.StorageProfile.osDisk.osType -eq "Windows")
        {
            $missing = ""
            if (-not($extensions.Name -contains "IaaSAntimalware") )
                {
                    $missing += "IaaSAntimalware "
                }
            if (-not($extensions.Name -contains "MicrosoftMonitoringAgent")  )
                {
                    $missing += "MicrosoftMonitoringAgent "
                }
            if (-not($extensions.Name -contains "AzureNetworkWatcherExtension")  )
                {
                    $missing += "AzureNetworkWatcherExtension "
                }  
            if (-not($extensions.Name -contains "Bootstrap")  )
                {
                    $missing += "Bootstrap "
                }             
            if (-not($extensions.Name -contains "Microsoft.Insights.VMDiagnosticsSettings")  )
                {
                    $missing += "Microsoft.Insights.VMDiagnosticsSettings "
                }     
            if (-not($extensions.Name -contains "Microsoft.Powershell.DSC")  )
                {
                    $missing += "Microsoft.Powershell.DSC "
                } 
           If ($missing -ne "") 
            {
                $namessW += "`n"+"- <a href='"+$fullName+"'>"+$namevm+"</a>: $missing`n`n"
            }
        }    
        if ($vm.StorageProfile.osDisk.osType -eq "Linux")
        {
           $missing = ""
           if (-not($extensions.Name -contains "AADLoginForLinux") )
                {
                    $missing += "AADLoginForLinux "
                }
            if (-not($extensions.Name -contains "Bootstrap")  )
                {
                    $missing += "Bootstrap "
                }
            if (-not($extensions.Name -contains "LinuxDiagnostic")  )
                {
                    $missing += "LinuxDiagnostic "
                }  
            if (-not($extensions.Name -contains "NetworkWatcherAgentLinux")  )
                {
                    $missing += "NetworkWatcherAgentLinux "
                }             
            if (-not($extensions.Name -contains "OmsAgentForLinux")  )
                {
                    $missing += "OmsAgentForLinux "
                }     
            if (-not($extensions.Name -contains "VMAccessForLinux")  )
                {
                    $missing += "VMAccessForLinux "
                } 
            If ($missing -ne "") 
                {
                    $namessL += "`n"+"- <a href='"+$fullName+"'>"+$namevm+"</a>: $missing`n`n"
                }
        }
        $VMNicName = $vm.NetworkProfile.NetworkInterfaces.Id.Split("/")[-1] 
        $VMNic = Get-AzNetworkInterface -ResourceGroupName $resname -Name $VMNicName
        $VMvNetName = $VMNic.IpConfigurations.Subnet.Id.Split("/")[8]
       
        $knownVnets = Get-AutomationVariable -Name 'Vnets' #just a string containing the names of the vnets separated by commas for /'g?sto/ :) 
         
        if ($knownVnets.Contains($VMvNetName))
        {
            #need to convert to -not later....
        }
        else
        {  
            $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$resname/providers/Microsoft.Compute/virtualMachines/$namevm/networking`n"
            $notInVnet += "`n"+"- <a href='"+$fullName+"'>"+$namevm+"</a>`n`n"
            "known vnets: " + $knownVnets + " DOES NOT contain vnet name: " + $VMvNetName
        }   
    }
    postToTeams("The following extensions are missing from VMs in the **$CurrrentSubName** subscription (advise VMs onwers):`n`n**Windows VMs**`n`n$namessW`n`n**Linux VMs**`n`n$namessL`n`nSome details about the installed extensions are unavailable. This can occur when the virtual machine is stopped or the agent is unresponsive.")
    If ($notInVnet -ne "")
    {
        postToTeams("The following VMs do not belong to any known virtual network in the **$CurrrentSubName** subscription (advise VMs onwers):`n`n$notInVnet`n`n")
    }    
} 

loginAzure
WarnAboutVMs 
#WarnAboutVMsNotBackuedup ... this one should look at tags)
 