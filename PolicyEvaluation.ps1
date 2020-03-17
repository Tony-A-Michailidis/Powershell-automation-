<#
    .DESCRIPTION
        Goes through all the assigned policies and initiatives in the subscription the automation account exists and flags whatever has failed. This will
        be usefull in a PB environment to monitor blueprints, eventually. So far it is just a test to get the data out of the logs or via the REST API or the
        related cmdtl's that spit out policy information. Caution posting to Teams such information, even tho thats the idea, first because it may be sensitive and
        second these APIs generate a lot of data and we have a 24MB limit posting a single message in Teams via the Invoke-RestMethod -Method Post. 
    
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

function GetPolicyStateSummary
{ 
    $CurrrentSub = (Get-AzureRmContext).Subscription
    $CurrrentSubName = $CurrrentSub.Name
    $CurrentSubId = $CurrrentSub.id
    $now = get-Date
    $startDate  = $($now.Date.AddDays(-1))
    $topost = ""
    $poly = Get-AzureRmPolicyAssignment 
    foreach ($p in $poly) 
    {
        $filt = "(PolicyAssignmentName eq '"+$p.Name + "')"
        If ((Get-AzureRmPolicyState -Filter $filt).IsCompliant -ne $null) 
        {
            $fullname = "https://portal.azure.com/#blade/Microsoft_Azure_Policy/PolicyMenuBlade/Compliance"
            $topost += "`n" + "- <a href='"+$fullName+"'>"+ $p.Properties.displayName + "</a>`n"
        }
    }
    
    $topost = "During the last 24h the following Azure Policy Assignments have evaluated as non-compliant in the **" + $CurrrentSubName + "** subscription:`n" + $topost + "`n"
    $topost += "`nReference the <a href='https://portal.azure.com/#blade/Microsoft_Azure_Policy/PolicyMenuBlade/Compliance'>Azure Portal Policy</a> menu blade for details"
    postToTeams($topost)
} 
 
loginAzure 
GetPolicyStateSummary
