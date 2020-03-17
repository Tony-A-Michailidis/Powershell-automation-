<#
    .DESCRIPTION
        Checks if a user has elevated his/her credentials without authorization. Highly unlikely this will happen but you never know...
        
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
#>

function Get-ParsedResult {
param ( [Parameter(Mandatory=$true)] [System.Object] $Results )
    $b = ""
    foreach ($row in $Results.'<>3__rows') 
    {
        if ($row.displayName_ -ne $null){
            $b += "- Attempted on " + $row.TimeGenerated + ", by " + $row.displayName_ + $row.userPrincipalName_ +" `n"
        }
    }
    Return ( $b )
}
 
$Conn = Get-AutomationConnection -Name AnalyticsConnection 
$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

$queryResults=""
$wdid = Get-AutomationVariable -Name 'WorkspaceId'
$queryResults = Invoke-AzureRmOperationalInsightsQuery -WorkspaceId $wdid -Query "AuditLogs | where OperationName == 'Set Company Information' and Result == 'success' | extend displayName_ = tostring(parse_json(tostring(InitiatedBy.app)).displayName) | extend userPrincipalName_ = tostring(parse_json(tostring(InitiatedBy.user)).userPrincipalName) | distinct TimeGenerated, displayName_, userPrincipalName_" -Timespan (New-TimeSpan -Hours 24)

$queryResults = $queryResults.Results 
$body = ""

if ($queryResults -ne "") 
{
    $body = (Get-ParsedResult -Results $queryResults)
    $body 
        $uri = Get-AutomationVariable -Name 'TeamsURI'
        $uri = [uri]::EscapeUriString($uri)   
        $payload1 = @{
            "text" = "There has been at least one successful attempt to obtain elevated (root scope) Azure Active Directory privileges during the last 24 hours:`n`n$body"}
        $json1 = ConvertTo-Json $payload1   
        Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
}
