<#
    .DESCRIPTION
        Finds all non-DFO e-mail accounts in the active directory and posts them to the related Teams channel. This is just a test here, the real one is in the 
        Prod sub. 
    
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
        $b +=  "- "+$row.Values+" `n "
    }
    Return ( $b )
}

 $Conn = Get-AutomationConnection -Name AnalyticsConnection 
 Connect-AzureAD  -tenantId $Conn.TenantID -CertificateThumbprint $Conn.CertificateThumbprint  -ApplicationId  $Conn.ApplicationID   

#$Conn = Get-AutomationConnection -Name AnalyticsConnection 
#$null = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

$queryResults = ""
$wspaceid = Get-AutomationVariable -Name 'WorkspaceId'

#$azureADdomain = get-azureaddomain
#get-azureaddomain

$test=""    
$test = Get-AzureADUser -All $true -Filter "userType eq 'Guest'"  | Select-Object -Property Mail
$test = $test -replace "`n", ""
$test = $test -replace "@{Mail=", ""
$test = $test -replace "}", " "

If ($test -ne "")
{ 
    $test += (Get-ParsedResult -Results $test)
    $test
    $test = Out-String -InputObject $test 
    $uri =  Get-AutomationVariable -Name 'TeamsURI'
    $payload1 = @{
    "text" = "**FYI: I found the following non-DFO users (guests) in the DFO tenant:**`n$test"
        }
    $json1 = ConvertTo-Json $payload1   
    $json1
    Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
}
    