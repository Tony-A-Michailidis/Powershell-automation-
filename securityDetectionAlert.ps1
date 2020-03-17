 <#
    .DESCRIPTION
       Retrieves from the log security alert entries using table SecurityDetection for the last 24h. Posts
       results, if any, to the related Teams channel. 
       For this to work (the query below) the Security Center - Pricing & settings should be set to standard in the related log so that it can access the SecurityDetection. 
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

function Get-ParsedResult {
param ( [Parameter(Mandatory=$true)] [System.Object] $Results )
    $b = ""
    foreach ($row in $Results.'<>3__rows') 
    {
        $b += "- **Created on:** " + $row.TimeGenerated + ", **for Computer:** " + "<a href='https://portal.azure.com/#@dfo-mpo.gc.ca/resource" + $row.AssociatedResource + "'>" + $row.Computer + "</a> **and user:** "+ $row.SubjectUserName + ". **Alert title:** " + $row.AlertTitle + " **Details:** " + $row.Description + " ** Recommended remediation:** " + $row.RemediationSteps + " `n" 
    }
    Return ( $b )
}
 
$Conn = Get-AutomationConnection -Name 'AnalyticsConnection'
$null1 = Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID -ApplicationID $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint 

$queryResults = $null
$body = $null
$queryResults = Invoke-AzureRmOperationalInsightsQuery -WorkspaceId "82b8783b-c1a7-48d1-9b6e-43941b0191fa" -Query "SecurityDetection" -Timespan (New-TimeSpan -Days 1) 
 
If ($queryResults.results -ne $null) 
{
    $queryResults = $queryResults.Results
    $body = (Get-ParsedResult -Results $queryResults)
    postToTeams ("**Security detected the following in the last 24 hours:**`n`n$body`n`n **Examine logs and trace user/systems actions to verify events.**")  
}
