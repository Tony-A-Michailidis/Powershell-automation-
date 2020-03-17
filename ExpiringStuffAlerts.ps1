<#
    .DESCRIPTION
        One runbook in the prod sub only to go through certificates, secrets, etc. in automation accounts, app registrations, webhooks and key vaults and identify all that is about to expire,
        give a week's notice if it finds anything by posting the details on the realted Teams channel. Other stuff that may be expiring is SAS for storage accounts that we need to look
        at separately. Insirational powershell code written by others can be located in the links that appear as comments. If it is to be used outside of DFO, adjust
        code and requirements as necessary for your needs. Lots of opportunities for optimization, starting with the expiry date
        calculations. Given that all this is the result of stitching together various existing scripts, some thinking moving forward
        should take plae to keep all in one runbook or split it into as many functions as in the code. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 25 Oct 2019
        EDITOR: Tony Michailidis
#>
 
function ElevatedLogin  
{ 
    $Conn = Get-AutomationConnection -Name AnalyticsConnection 
    Connect-AzureAD  -tenantId $Conn.TenantID -CertificateThumbprint $Conn.CertificateThumbprint  -ApplicationId  $Conn.ApplicationID   
}

function postToTeams ([string]$teamsMessage)
{
    try
        { 
            $uri = Get-AutomationVariable -Name 'TeamsURI' #use TestURI for the test channel
            $uri = [uri]::EscapeUriString($uri)         
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

function LoginToAzure
{
    # To test outside of Azure Automation, replace this block with Login-AzureRmAccount
    $connectionName = "AzureRunAsConnection"
    try
    {
        # Get the connection "AzureRunAsConnection "
        $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName        
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint   $servicePrincipalConnection.CertificateThumbprint 
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

# ***************************************************** Azure AD Apps *****************************************************

function AzureADApps
{
    #insipred by https://blogs.msdn.microsoft.com/svarukala/2018/01/26/powershell-to-list-all-azure-ad-apps-with-expiration-dates/
    $topost =""
    ElevatedLogin # needs to login the AD, a different "kind" of login all together...
    $now = get-Date
    $ExpiryDate = $($now.Date.AddDays(+7))
    $ExpiryDaterange = $($now.Date.AddDays(+14))
    $results = @()
    Get-AzureADApplication -All $true | %{  
        $app = $_
        $owner = Get-AzureADApplicationOwner -ObjectId $_.ObjectID -Top 1
        $app.PasswordCredentials | 
            %{ 
                    $results += [PSCustomObject] @{
                    CredentialType = "PasswordCredentials"
                    DisplayName = $app.DisplayName; 
                    appID = $app.appID
                    ExpiryDate = $_.EndDate;
                    StartDate = $_.StartDate;
                    KeyID = $_.KeyId;
                    Type = 'NA';
                    Usage = 'NA';
                    Owners = $owner.UserPrincipalName;
                }
            }                     
        $app.KeyCredentials | 
            %{ 
                    $results += [PSCustomObject] @{
                    CredentialType = "KeyCredentials"                                        
                    DisplayName = $app.DisplayName; 
                    appID = $app.appID
                    ExpiryDate = $_.EndDate;
                    StartDate = $_.StartDate;
                    KeyID = $_.KeyId;
                    Type = $_.Type;
                    Usage = $_.Usage;
                    Owners = $owner.UserPrincipalName;
                }
            }                            
    } 
    Foreach ($r in $results)
    {   
        if ($r.ExpiryDate -lt $now)
        {
            If ($r.CredentialType -eq "PasswordCredentials")
            {
                $topost += "`n - Client Secret for application <a href='https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/" + $r.appID + "/isMSAApp/'>" + $r.DisplayName + "</a> has expired"
            }
            else
            {
                $topost += "`n - Certificate for application <a href='https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/" + $r.appID + "/isMSAApp/'>" + $r.DisplayName + "</a> has expired"
            }
        }
        if (($r.ExpiryDate -gt $ExpiryDate) -and ($r.ExpiryDate -lt $ExpiryDaterange))
        {
             If ($r.CredentialType -eq "PasswordCredentials")
            {
                $topost += "`n - Client Secret for application <a href='https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/" + $r.appID + "/isMSAApp/'>" + $r.DisplayName + "</a> to expire on "+ $r.ExpiryDate
            }
            else
            {
                $topost += "`n - Certificate for application <a href='https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/" + $r.appID + "/isMSAApp/'>" + $r.DisplayName + "</a> to expire on "+ $r.ExpiryDate
            }
        }
    }
    postToTeams ("The following Azure AD registered applications have expired credentials/keys, or their credentials/keys are about to expire soon:`n `n" + "`n" + $topost)    
}    
 p
# ***************************************************** Vaults *****************************************************

Function New-KeyVaultObject
{
    param
    (
        [string]$Id,
        [string]$Name,
        [string]$Version,
        [System.Nullable[DateTime]]$Expires
    )
    $server = New-Object -TypeName PSObject
    $server | Add-Member -MemberType NoteProperty -Name Id -Value $Id
    $server | Add-Member -MemberType NoteProperty -Name Name -Value $Name
    $server | Add-Member -MemberType NoteProperty -Name Version -Value $Version
    $server | Add-Member -MemberType NoteProperty -Name Expires -Value $Expires
    return $server
}

function Get-AzureKeyVaultObjectKeys
{
    param
    (
        [string]$VaultName,
        [bool]$IncludeAllVersions
    )
    $vaultObjects = [System.Collections.ArrayList]@()
    $allKeys = Get-AzureKeyVaultKey -VaultName $VaultName
    foreach ($key in $allKeys) 
        {
            if($IncludeAllVersions)
                {
                    $allSecretVersion = Get-AzureKeyVaultKey -VaultName $VaultName -IncludeVersions -Name $key.Name
                    foreach($key in $allSecretVersion)
                        {
                            $vaultObject = New-KeyVaultObject -Id $key.Id -Name $key.Name -Version $key.Version -Expires $key.Expires
                            $vaultObjects.Add($vaultObject)
                        }
                } 
            else 
                {
                    $vaultObject = New-KeyVaultObject -Id $key.Id -Name $key.Name -Version $key.Version -Expires $key.Expires
                    $vaultObjects.Add($vaultObject)
                }
        } 
    return $vaultObjects
}

function Get-AzureKeyVaultObjectSecrets
{
    param
    (
        [string]$VaultName,
        [bool]$IncludeAllVersions
    )
    $vaultObjects = [System.Collections.ArrayList]@()
    $allSecrets = Get-AzureKeyVaultSecret -VaultName $VaultName
    foreach ($secret in $allSecrets) 
    {
        if($IncludeAllVersions)
        {
            $allSecretVersion = Get-AzureKeyVaultSecret -VaultName $VaultName -IncludeVersions -Name $secret.Name
            foreach($secret in $allSecretVersion)
                {
                    $vaultObject = New-KeyVaultObject -Id $secret.Id -Name $secret.Name -Version $secret.Version -Expires $secret.Expires
                    $vaultObjects.Add($vaultObject)
                }
        } else 
                {
                    $vaultObject = New-KeyVaultObject -Id $secret.Id -Name $secret.Name -Version $secret.Version -Expires $secret.Expires
                    $vaultObjects.Add($vaultObject)
                }
    }    
    return $vaultObjects
}
  
function AzureVaults
{
    #inspired by: https://www.rahulpnath.com/blog/expiry-notification-for-azure-key-vault-keys-and-secrets/
   
    #this should be in each sub as a separate runbook, or else we are mixing and matching permissions across different subs and thats not a good practice. 
    #it will work for the vaults in the sub the runbook runs in but it will throw errors for the other vaults in other subs. 
    
    # would rather get error for vaults not accessible from this auto acc instead of hard coding the names of the vaults for just
    # this sub in here!!!

    $VaultName  = Get-AzureRMKeyVault

    $IncludeAllKeyVersions = $false
    $IncludeAllSecretVersions = $false 
    
    $today = (Get-Date).Date
    $ExpiryDate = $($today.Date.AddDays(+8))

    foreach ($v in $VaultName)
    {
        $topost =""
        $allKeyVaultObjects = [System.Collections.ArrayList]@()
        $allKeyVaultObjects.AddRange((Get-AzureKeyVaultObjectKeys -VaultName $v.VaultName -IncludeAllVersions $IncludeAllKeyVersions))
        $allKeyVaultObjects.AddRange((Get-AzureKeyVaultObjectSecrets -VaultName $v.VaultName -IncludeAllVersions $IncludeAllSecretVersions))    
        $expiredKeyVaultObjects = [System.Collections.ArrayList]@()
        
        foreach ($vaultObject in $allKeyVaultObjects)
        { 
            If ( $vaultObject.Name -ne $null )
            {
                If ( $vaultObject.Expires -eq $null )
                {
                    $topost += "`n - Vault object " + $vaultObject.Name + " in vault " + $v.VaultName + " has no expiry date" 
                }
                else 
                {
                    if ( $ExpiryDate -gt $vaultObject.Expires.AddDays(-1).Date ) 
                        {
                            $topost += "`n - Vault object " + $vaultObject.Name + " in key vault " + $v.VaultName  + " is expiring on " + $vaultObject.Expires
                        }    
                }
            }    
        }    
        If ($topost -ne "" )
        {
            postToTeams ("The following vault objects are about to expire, or have no expiry date. Add expiry dates and/or address the soon to expire ones. Search for each vault object mentioned below in the Azure portal for details:`n" + $topost)
        }            
    }    
}

# ***************************************************** Web Hooks *****************************************************

function AzureWebhooks
{    
    #inspired by https://www.powershellgallery.com/packages/Get-ExpiredWebhook/1.0/Content/Get-ExpiredWebhook.ps1
    $DaysToExpiration = 10
    $topost =""
    $hookss = Get-AzureRmResourceGroup | Get-AzureRmAutomationAccount | Get-AzureRmAutomationWebhook 
    foreach ($hoo in $hookss )
        {  
            If ((New-TimeSpan -Start (Get-Date).ToUniversalTime() -End $hoo.ExpiryTime.UtcDateTime).Days -lt $DaysToExpiration)
            {                  
                $topost += "`n - Webhook " + $hoo.Name + " linked to " + $hoo.ResourceGroupName +" / " + $hoo.AutomationAccountName  +" / " + $hoo.RunbookName + "will expire on " + $hoo.ExpiryTime
            }
        }    
   If ($topost -ne "" )
        {
            postToTeams ("The following WebHooks are about to expire, or have already expired. Search for each WebHook mentioned below in the Azure portal for details:`n" + $topost) 
        }            
}

# ***************************************************** Web Apps certs *****************************************************

function AzureWebApps
{
    #inspired by https://bramstoop.com/2018/08/03/monitor-your-azure-ssl-certificates-expiration/  
    $topost =""
    $minimumCertAgeDays = 30 #these renewals may take a while if the are SSC certs so 30 days ahead is ok. 
    $currentSubscription = (Get-AzureRmContext).Subscription
    $resourceGroups = Get-AzureRmResourceGroup
    foreach ($ResourceGroup in $resourceGroups)
    {
        $ResourceGroupName = $ResourceGroup.ResourceGroupName
        #The Get-AzureRmWebAppCertificate cmdlet gets information about Azure Web App certificates associated with a specified resource group.
        $allCertificates = Get-AzureRmWebAppCertificate -ResourceGroupName $ResourceGroupName
        foreach ($certificate in $allCertificates)
        {
            [datetime]$expiration = $($certificate.ExpirationDate)
            [int]$certExpiresIn = ($expiration - $(get-date)).Days
            if ($certExpiresIn -gt $minimumCertAgeDays)
            {
                #nothing (just playing with the -gt and -lt)
            }
            else
            {
                $topost += "`n - Certificate " + $certificate.FriendlyName + " expires in " + $certExpiresIn + "days, on " + $expiration + `
                ". This certificate can be found in subscrtiption " + $currentSubscription.Name + " and resource group: " + $ResourceGroup.ResourceGroupName
            }
        }
    }
    If ($topost -ne "" )
        {
            postToTeams ("The following web app certificates are expiring soon. Seach for each certificate mentioned below in the Azure portal for details:`n" + $topost)
        }   
}
 

AzureADApps #this one logs in using a different method, see function above
LoginToAzure
AzureVaults #this needs to be re-created in the other subs too since premissions may be required without crossing boundaries betwen dev prod and sandbox
AzureWebhooks
AzureWebApps #this needs to be re-created in the other subs too since permissions may be required without crossing boundaries betwen dev prod and sandbox