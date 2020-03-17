<#
    .DESCRIPTION
        We hope it never happens, i.e. a level 5 security issue is logged in the log. If thats the case it is an azure issue... 
        For this to work (the query below) the Security Center - Pricing & settings should be set to standard in the related log so that it can access the SecurityEvent. 
        Thats about $15 per VM per month tho... so think first. 

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
            $azureaccount = Add-AzureRmAccount -ServicePrincipal -TenantId $servicePrincipalConnection.TenantId -ApplicationId $servicePrincipalConnection.ApplicationId -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
            "Logged in OK."
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
            $uri = Get-AutomationVariable -Name 'SecurityURI'
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
    foreach ($row in $Results.'<>3__rows') 
    {
        $b += "- Created on " + $row.TimeGenerated + ", for Computer " + $row.Computer + ", with event source name " + $row.EventSourceName + ", and channel " + $row.channel + ", with activity: " + $row.Activity + " `n" 
    }
    Return ( $b )
}
 
$Conn = Get-AutomationConnection -Name 'AnalyticsConnection'
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

$queryResults = $null
$body = "" 
$wwid = Get-AutomationVariable -Name 'WorkspaceId'
$queryResults = Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $wwid -Query "SecurityEvent | where Level == '5' | summarize by TimeGenerated, Computer, EventSourceName, Channel, Activity" -Timespan (New-TimeSpan -Days 1) 
$queryResults.results
If ($queryResults.results -ne $null) 
{
    $queryResults = $queryResults.Results
    $body = (Get-ParsedResult -Results $queryResults)
    postToTeams("**A severe security event was logged by Azure, query the log for details:**`n`n$body") 
}

 