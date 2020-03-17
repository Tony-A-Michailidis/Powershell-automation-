#
    .DESCRIPTION
        Returns and posts to the related Teams channel (TeamsURI) changes to role assignments
        by querying log analytics using the related search queries to find role assignment addition operations
        during the last X number of days - see query below to set how many days or hours to go back. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR Tony Michailidis
        LAST EDIT 22 Oct 2019
        EDITOR Tony Mchailidis
#

$body= 

function Get-ParsedResult {
param ( [Parameter(Mandatory=$true)] [System.Object] $Results )
    $b =  
    foreach ($row in $Results.'3__rows') 
    {
        $b += - Role added on  + $row.TimeGenerated + , by User a href='mailto + $row.Caller + ' + $row.Caller + a, and the scope is a href='httpsportal.azure.com#@dfo-mpo.gc.caresource + $row.ResourceId.Substring(0, $row.ResourceId.IndexOf(providersMicrosoft.)) + ' + $row.ResourceId.Substring(0, $row.ResourceId.IndexOf(providersMicrosoft.)) + a `n
    }
    Return ( $b )
}
 
$Conn = Get-AutomationConnection -Name 'AnalyticsConnection'
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 
$queryResults =
$wdid = Get-AutomationVariable -Name 'WorkspaceId'
$queryResults = Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $wdid -Query AzureActivity  where OperationName == 'Create role assignment' and ActivityStatusValue == 'Succeeded'  -Timespan (New-TimeSpan -Hours 12) 

If ($queryResults.results -ne ) 
{
    $queryResults = $queryResults.Results
    $body = (Get-ParsedResult -Results $queryResults) 
    $body 
    $uri = Get-AutomationVariable -Name 'TeamsURI'
    
    $payload1 = @{
            text = I found out that some roles have been added in production`n`n$body`n`nIf the links don't load, the resource may have already been deleted.
    }
   
    $json1 = ConvertTo-Json $payload1   
         
    Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'ApplicationJson'
}

  