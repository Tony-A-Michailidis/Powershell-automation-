<#
    .DESCRIPTION
        Returns and posts to the related Teams channel (TeamsURI) changes to role assignments
        by querying log analytics using the related search queries to find role assignment addition operations
        during the last X number of days - see query below to set how many days or hours to go back. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
#>

$body="" 
$b=""
function Get-ParsedResult 
{
param ( [Parameter(Mandatory=$true)] [System.Object] $Results )
    $b = ""
    foreach ($row in $Results.'<>3__rows') 
    {   
      if ($row.scope_ -ne "")
        { #<a href='mailto:" + $row.Caller + "'>
            $b += "- Role removed on " + $row.TimeGenerated + ", by " + $row.Caller + ", and the scope was <a href='https://portal.azure.com/#@dfo-mpo.gc.ca/resource" + $row.scope_ + "'>" + $row.scope_ + " `n" 
        }
       else 
        {
           $b += "- Role removed on " + $row.TimeGenerated + ", by " + $row.Caller + ", and the scope was <a href='https://portal.azure.com/#@dfo-mpo.gc.ca/resource" + $row.scope_2 + "'>" + $row.scope_2 + " `n" 
         }
    }
    Return ( $b ) 
}
$Conn = Get-AutomationConnection -Name 'AnalyticsConnection'
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 
$queryResults =""
$wdid = Get-AutomationVariable -Name 'WorkspaceId'
$queryResults = Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $wdid -Query "AzureActivity | where OperationName == 'Delete role assignment' and ActivityStatusValue == 'Succeeded' | extend scope_ = tostring(parse_json(Properties).scope) | extend scope_2 = tostring(parse_json(tostring(parse_json(tostring(parse_json(Properties).responseBody)).properties)).scope)" -Timespan (New-TimeSpan -Hours 24)
If ($queryResults.results -ne "") 
{
    $queryResults = $queryResults.Results
    $body = Get-ParsedResult -Results $queryResults  
    $uri = Get-AutomationVariable -Name 'TeamsURI'
    $payload1 = @{
            "text" = "I found out that some roles have been deleted in production:`n`n$body`n`nIf the link doesn't load the resource, the resource may have been deleted."
    }
    $json1 = ConvertTo-Json $payload1   
    Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
}
