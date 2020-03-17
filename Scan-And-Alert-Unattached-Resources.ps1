<#
    .DESCRIPTION
        Finds unused NICs, NSGs, IPs and unattached disks left over after a VM gets deleted and posts in the related Teams channel. A couple of notes to make, first you
        can "silence" the resource by adding a Silenced tag with the value of True, and second if there is a lock on a resource it won't be reported. Finally, just
        because an NSG has NICs attached to it doesn't mean its still in use, if the NICs themselves are not attached to any VM. In that case we flat the NSG as unused too. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
        inspired by https://github.com/RZomerman/AzureCleanup/blob/master/AzureCleanup.ps1.ps1
#>
 
function loginAzure 
    {
        $connectionName = "AzureRunAsConnection"
        try
            {
                # Get the connection "AzureRunAsConnection "
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

function WarnAboutUnusedNSGs 
{
    $UnattachedCounter=0
    $resourcen=""
    $UnattachedNames = @()
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name
    $CurrentSubId = $CurrrentSub.id
    $AllNSGs = Get-AzureRmNetworkSecurityGroup
    ForEach ($NSG in $AllNSGs) 
    {
	    If ($NSG.NetworkInterfaces.count -eq 0 -and $NSG.Subnets.count -eq 0) 
        { 
            $resourcen = $NSG.name
            $rgName = Get-AzureRmNetworkSecurityGroup  | where {$_.id -eq $NSG.id} | Select-Object -ExpandProperty ResourceGroupName
            $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$rgName/providers/Microsoft.Network/networkSecurityGroups/$resourcen/overview "
            $thetype = "Microsoft.Network/networkSecurityGroups"            
            $lockfact = Get-AzureRMResourceLock -ResourceGroupName $rgName -ResourceName $resourcen -ResourceType $thetype
            if ($lockfact.LockId -eq $null)     
            { 
                    if ((Get-AzureRmResource -ResourceId $NSG.id).Tags.Silent  -eq "True")
                    {
                        #do nothing
                         $NSG.Name + " NSG is silent"
                    }    
                    else
                    {    
                         $NSG.Name + " NSG is not silent"
                        $UnattachedCounter++
                        $UnattachedNames += "`n"+"- <a href='"+$fullName+"'>"+$resourcen+"</a>`n"
                    }    
            }   
 		}
        ElseIf ($NSG.NetworkInterfaces.count -eq 1 -and $NSGCheck -contains $NSG.NetworkInterfaces.id) #if the nics in the nsg are 1 and that nic is dead... even if the NSG has > 0 NIcs attached to it, the NICs themselves may not be attached to something else, so flag the entire NSG. but this works only if its just 1 
        {
			$resourcen = $NSG.name
             $NSG.Name
            $rgName = Get-AzureRmNetworkSecurityGroup  | where {$_.id -eq $NSG.id} | Select-Object -ExpandProperty ResourceGroupName
            $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$rgName/providers/Microsoft.Network/networkSecurityGroups/$resourcen/overview "
            $lockfact = Get-AzureRMResourceLock -ResourceGroupName "$rgName" -ResourceName "$resourcen" -ResourceType "Microsoft.Network/networkSecurityGroups"
            if ($lockfact.LockId -eq $null) 
                { 
                    if ((Get-AzureRmResource -ResourceId $NSG.id).Tags.Silent -eq "True")
                    {
                         $NSG.Name + " NSG is silent"
                        #do nothing
                    }    
                    else
                    {    
                         $NSG.Name + " NSG is not silent"
                        $UnattachedCounter++
                        $UnattachedNames += "`n"+"- <a href='"+$fullName+"'>"+$resourcen+"</a>`n"
                    }    
                }   
		}
	}
    if ($UnattachedCounter -gt 0) 
    { 
        postToTeams("I found the following not used Network Security Groups (NSGs) in the **$CurrrentSubName** subscription (check with their owners before deleting them):`n $UnattachedNames")
    } 
}

function WarnAboutUnusedPiPs {
    $UnattachedCounter=0
    $resourcen=""
    $UnattachedNames = @()
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name
    $CurrentSubId = $CurrrentSub.id
    $PublicIPAddresses=Get-AzureRmPublicIpAddress
    ForEach ($exIP in $PublicIPAddresses) 
    {  
	    if ($exIP.Ipconfiguration.id.count -eq 0) 
            {
                $resourcen = $exIP.name
                $rgName = Get-AzureRmPublicIpAddress  | where {$_.id -eq $exIP.id} | Select-Object -ExpandProperty ResourceGroupName
                $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$rgName/providers/Microsoft.Network/publicIPAddresses/$resourcen/overview "
                $lockfact = Get-AzureRMResourceLock -ResourceGroupName $rgName -ResourceName $resourcen -ResourceType "Microsoft.Network/publicIPAddresses"
                if ($lockfact.LockId -eq $null) 
                {                        
                    if ((Get-AzureRmResource -ResourceId $exIP.id).Tags.Silent -eq "True") 
                    {
                        $exIP.name + " IP is silent"
                        #do nothing
                    }    
                    else
                    {                    
                        $exIP.name + " IP is not silent"
                        $UnattachedCounter++
                        $UnattachedNames += "`n"+"- <a href='"+$fullName+"'>"+$resourcen+"</a>`n"
                    }    
                }     
            }     
    } 
    if ($UnattachedCounter -gt 0) 
    { 
        postToTeams("I found the following not used public IPs in the **$CurrrentSubName** subscription (check with their owners before deleting them):`n $UnattachedNames")
    } 
}

function WarnAboutUnattachedDisks 
{
    $UnattachedCounter=0
    $UnattachedNames = @()
    $ResourceToExamine = Get-AzureRmDisk 
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name
    $CurrentSubId = $CurrrentSub.id
    foreach ($md in $ResourceToExamine) 
       {
         if ($md.ManagedBy -eq $null) 
            {
                $rgName = Get-AzureRmDisk  | where {$_.id -eq $md.id} | Select-Object -ExpandProperty ResourceGroupName
                $resourcen = $md.Name
                 
                $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$rgName/providers/Microsoft.Compute/disks/$resourcen/overview "
                $lockfact = Get-AzureRMResourceLock -ResourceGroupName $rgName -ResourceName $resourcen -ResourceType "Microsoft.Compute/disks"
                if ($lockfact.LockId -eq $null) 
                    { 
                         
                       if ($md.Tags.ContainsKey("Silent") -eq "True" -and $md.Tags["Silent"]  -eq "True") 
                           { 
                               $md.Name + " disk is silent"
                                #do nothing
                           }
                        else
                           {
                               $md.Name + " disk is not silent"
                                $UnattachedCounter++
                                $UnattachedNames += "`n"+"- <a href='"+$fullName+"'>"+$resourcen+"</a>`n"
                           }    
                    }    
            }  
       }
    if ($UnattachedCounter -gt 0) 
        { 
            postToTeams("I found the following unattached VM disks in the **$CurrrentSubName** subscription (check with their owners before deleting them):`n`n $UnattachedNames")
        } 
}
 
function WarnAboutNICs 
{
    $numberUnattachedNICs=0 
    $numberUnattachedNICsWithLocks=0
    $orphanedNICs = ""
    $orphanedNICsWithLock = ""
    $fullName= ""
    $resourcen =""
    $UnattachedNames=""
    $AttachedNICs = Get-AzureRmNetworkInterface  
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name
    $CurrentSubId = $CurrrentSub.id
    foreach ($md1 in $AttachedNICs) 
        {                 
            if ($md1.VirtualMachine -eq $null) 
                {
                    $rgName = Get-AzureRmNetworkInterface | where {$_.id -eq $md1.id} | Select-Object -ExpandProperty ResourceGroupName
                    $resourcen = $md1.Name
                    $fullName ="https://portal.azure.com/#@dfo-mpo.gc.ca/resource/subscriptions/$CurrentSubId/resourceGroups/$rgName/providers/Microsoft.Network/networkInterfaces/$resourcen/overview`n"
                    $lockfact = Get-AzureRMResourceLock -ResourceGroupName $rgName -ResourceName $resourcen -ResourceType "Microsoft.Network/networkInterfaces"
                    $NSGCheck.Add($md1.id) > null #building a list of NIcs found not attached, however they may appear in NSGs even after they are detached from VMs so add them up in the list and check in the nsg function
                    if ($lockfact.LockId -eq $null) 
                        { 
                            if ((Get-AzureRmResource -ResourceId $md1.id).Tags.Silent -eq "True") 
                            {
                                $md1.Name + " NIC is silent"
                                  #do nothing
                            }    
                            else
                            {       
                                $md1.Name + " NIC is not silent"
                                $numberUnattachedNICs++ 
                                $UnattachedNames += "`n"+"- <a href='"+$fullName+"'>"+$resourcen+"</a>`n"     
                            }                                                 
                        }  
                }
        } 
    if ($numberUnattachedNICs -gt 0) 
        { 
            postToTeams("I found the following not used Network Interfaces in the **$CurrrentSubName** subscription (check with their owners before deleting them):`n $UnattachedNames")
        }  
}

$NSGCheck = New-Object System.Collections.ArrayList #building a list of nsgs with NICs in them, however the NICs may still appear in NSGs, meaning... see code. 
loginAzure
"login done"
WarnAboutNICs
"nics done"
WarnAboutUnattachedDisks
"disks done"
WarnAboutUnusedPiPs
"pips done"
WarnAboutUnusedNSGs
"nics done"