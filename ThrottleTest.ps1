
<#
    .DESCRIPTION
        if you ever get the throttle message from azure run this in a powershell window to
	see what caused the throttle. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 4 Nov 2019
        EDITOR: Tony Mchailidis         
#>

$connectionName = "AzureRunAsConnection "
try
{
        $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
"Logging in to Azure..."
    $connectionResult =  Connect-AzAccount -Tenant $servicePrincipalConnection.TenantID `
                                 -ApplicationId $servicePrincipalConnection.ApplicationID   `
                                 -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
                                 -ServicePrincipal
"Logged in."
}
catch 
{
    if (!$servicePrincipalConnection)
    {
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
    } else {
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
}


Export-AzLogAnalyticRequestRateByInterval -Location 'Canada Central' -FromTime '2019-10-19T10:00:00' -ToTime '2019-10-21T12:00:00' -BlobContainerSasUri 'https://throttletest.blob.core.windows.net/dfo-hot?sp=racwdl&st=2019-10-21T18:42:53Z&se=2019-10-22T18:42:53Z&sv=2019-02-02&sr=c&sig=y87T8h77UZU%2Biqdq%2Fo%2B0xGZjmSlbmMQJEWi%2BUn5MeTg%3D' -IntervalLength ThirtyMins -GroupByThrottlePolicy

