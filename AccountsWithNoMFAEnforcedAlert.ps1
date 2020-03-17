<#
    .DESCRIPTION
        Returns a list of users with no MFA enforced. The Connect-MsolService will require a login/password (can't do it with a service principle, unless you have figured it out!) so it will trigger 
        the MFA for the login admin user. So this is a script you copy and paste in your Powershell on your desktop to run and get results. 
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 3 Nov 2019
        EDITOR: Tony Mchailidis
        Inspired by: https://social.msdn.microsoft.com/Forums/security/en-US/ca7bf582-f4c2-4eee-9af7-63bb239c9a34/how-to-get-the-report-of-users-that-have-enabled-but-not-enforced-for-azure-multifactor?forum=windowsazureactiveauthentication
 #>
 
Connect-MsolService
$exclusionList =  
$allUsers = Get-MsolUser -All | Where-Object -Property UserPrincipalName -NotIn $exclusionList
$auth = New-Object -TypeName Microsoft.Online.Administration.StrongAuthenticationRequirement
$allUsers | 
ForEach-Object {
    if ($_.StrongAuthenticationRequirements.State -ne "Enforced")
    {
        Write-Host "$($_.DisplayName) (ObjectId=$($_.ObjectId))"  # or adjust to send output formatted to Teams using examplease of other runbooks in this and the other automation accounts we have. 
    }
    
}
