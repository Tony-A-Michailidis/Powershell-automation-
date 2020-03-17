<#
    .DESCRIPTION
        Finds risky users on a daily basis by querying the related log analytics table and posts the cound of users (not the real names) in the related Teams channel. 
        Thereafter if the reader has access to the risky users menu he or she can view details such as names, actions, IPs, etc. This is just for testing here, the real
        one is in the Prod sub. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
#>

function Get-ParsedResult {
param ( [Parameter(Mandatory=$true)] [System.Object] $Results )
    $b = 0
    foreach ($row in $Results.'<>3__rows')  
    {
        $b = $row.Count    # since you are getting back a Count there should be only 1 row 
    }
    Return ( $b )
}

$Conn = Get-AutomationConnection -Name AnalyticsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

$queryResults = ""
$wspaceid = Get-AutomationVariable -Name 'WorkspaceId'
$queryResults = Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $wspaceid -Query "SigninLogs | where RiskState == 'atRisk'| distinct UserPrincipalName | count " -Timespan (New-TimeSpan -Hours 24 )
 
$queryResults = $queryResults.results
 
$body = 0

$body = (Get-ParsedResult -Results $queryResults)
  
If ($body -ne 0)
    {
        $uri = Get-AutomationVariable -Name 'TeamsURI'
        $uri2 = Get-AutomationVariable -Name 'SecurityURI'   
        $payload1 = @{
            "text" = "I found $body risky user(s) during the last 24 hours in the Azure Risky users activity report. Check report for details: <a href='https://portal.azure.com/#blade/Microsoft_AAD_IAM/SecurityMenuBlade/RiskyUsers'>Link</a>"
            } 
        $json1 = ConvertTo-Json $payload1  
        Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
        #sending this to Robert Luther too... $uri2. 
        Invoke-RestMethod -uri $uri2 -Method Post -body $json1 -ContentType 'Application/Json'
    }
 