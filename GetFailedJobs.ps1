<#
    .DESCRIPTION
        Obviously with so many runbooks to monitor operations we needed some runbook to check out if any of the batch jobs have failed. This runbook locates failed 
        jobs running on schedule and posts the names of the runbooks in the related Teams channel. 
        
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
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

function GetFailedJobs 
{
    $outt = ""
    $now = get-Date
    $startDate = $($now.Date.AddDays(-1))
    $books = Get-AzureRmAutomationRunbook -AutomationAccountName "Mgmt-Prod-Automation" -ResourceGroupName "MGMT-PROD-RG" 
    $Check = New-Object System.Collections.ArrayList

    Foreach ($book in $books)
    {
        $jobs = Get-AzureRmAutomationJob –AutomationAccountName "Mgmt-Prod-Automation" –RunbookName $book.Name -ResourceGroupName "MGMT-PROD-RG" -StartTime $startDate -EndTime $now
        foreach ($job in $jobs)
            {
                if ($job.Status -eq "Failed") 
                {                 
                    if ($Check -contains $book.Name) {}
                    else {                    
                            $booklink = "<a href='https://portal.azure.com/#@086gc.onmicrosoft.com/resource/subscriptions/a09b97a0-4b61-469d-ab88-1f77727b8c08/resourceGroups/MGMT-PROD-RG/providers/Microsoft.Automation/automationAccounts/Mgmt-Prod-Automation/runbooks/" + $book.Name + "'>" +  $book.Name + "</a> (UTC time stamp: " + $job.EndTime + ")"                         
                            $outt = $outt + "`n - " + $booklink +"`n"
                            $Check.Add($book.Name) > null
                         }    
                }
            }    
    }
    return ($outt)
}

Disable-AzureRmContextAutosave –Scope Process

loginAzure
$CurrrentSub = (Get-AzureRmContext).Subscription
$CurrrentSubName = $CurrrentSub.Name
$a = ""
$a = GetFailedJobs             
if ($a -ne "")
{
    postToTeams ("The following runbook jobs have failed to complete in the **"+$CurrrentSubName+"** subscription during the past 12 hours: `n`n" + $a +"`n`n(examine automation account job logs for details)")
}    

