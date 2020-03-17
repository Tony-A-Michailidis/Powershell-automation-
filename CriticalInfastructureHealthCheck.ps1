<#
    .DESCRIPTION
        This is just for testing in the training sub, the real one is in prod. In a nutshell, it looks at the DC, the awx and the jump servers and re-starts them if dead. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
#>

function postToTeams ([string]$teamsMessage)
{
    if ($teamsMessage -ne "")
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

function CriticalVMHealthCheck
{ 
    $topost = ""
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrentSubId = $CurrrentSub.id
    $subname = $CurrrentSub.name
    foreach ($oneVM in $allVMs)
        {
            # future modification: Get-AzureRmVm | Get-AzureRmVm -Status | select ResourceGroupName, Name, @{n="Status"; e={$_.Statuses[1].DisplayStatus}}

            "The VM: "+ $oneVM.name + ", has status: " + $oneVM.Statuses[1].DisplayStatus + "`n"
            if ($oneVM.Statuses[1].DisplayStatus -ne $null)
            {
                $ResourceId = "/subscriptions/" + $CurrentSubId + "/resourceGroups/" +  $oneVM.ResourceGroupName   + "/providers/Microsoft.Compute/virtualMachines/" + $oneVM.name 
                $vmpath = "<a href='https://portal.azure.com/#@086gc.onmicrosoft.com/resource" + $ResourceId + "'>" + $oneVM.name + "</a>"       
                if ($oneVM.Statuses[1].DisplayStatus -ne "VM running" -and $oneVM.Statuses[1].DisplayStatus -ne "VM starting" ) 
                # we assume status for critical stuff won't be "Deleting" since nobody can get there. 
                    {
                        $topost += "`n- Mission critical **"+ $vmpath + "** is down (power state: "+ $oneVM.Statuses[1].DisplayStatus + "). Attempting restart... "
             
                        $StartRtn = $oneVM | Start-AzureRmVM -ErrorAction Continue
                        if ($StartRtn.Status -ne "Succeeded")
                            {
                                $topost += "** Can not restart " + $vmpath + ". Examine Azure logs for issues.**`n"
                            }
                        else
                            {
                                $topost += "**" + $vmpath + "** has restarted.`n"
                            }
                    }
            } 
            else 
            {
                $topost += "**" + $vmpath + "** Virtual Machine state (running, deallocated, starting, etc) cannot be detected, trying again during the next scheduled iteration...`n"
            }                       
        }
    if ($topost -ne "" )
    {
        postToTeams($topost)
    }    
}  

LoginToAzure

$allVMs = (Get-AzureRmVM -ResourceGroupName 'MGMT-PROD-RG' -Name 'cloud-dc1-vm' -Status) , `
(Get-AzureRmVM -ResourceGroupName 'MGMT-PROD-RG' -Name 'cloud-dc2-vm' -Status), `
(Get-AzureRmVM -ResourceGroupName 'MGMT-PROD-RG' -Name 'awx-prod-vm2' -Status), `
(Get-AzureRmVM -ResourceGroupName 'FGCAC-PROD-RG' -Name 'FGCAC-A' -Status), `
(Get-AzureRmVM -ResourceGroupName 'FGCAC-PROD-RG' -Name 'FGCAC-B'  -Status) , `
(Get-AzureRmVM -ResourceGroupName 'FG-PROD-CAE-RG' -Name 'FGCAEVM'  -Status) , `
(Get-AzureRmVM -ResourceGroupName 'MGMT-PROD-RG' -Name 'cloud-rdg1-vm' -Status) , `
(Get-AzureRmVM -ResourceGroupName 'Network-PROD-RG' -Name 'linuxjumpserver01' -Status)


CriticalVMHealthCheck
 