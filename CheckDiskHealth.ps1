<#
    .DESCRIPTION
        Checks the health status of all storage accounts in the subscription. Posts to the related Teams channel if an issue was found, such as some limit exceeded or 
        there is disk damage (according to Azure detection schemes)
    
    .PARAMETER none
   
    .NOTES
        AUTHOR: Tony Michailidis
        LAST EDIT: 22 Oct 2019
        EDITOR: Tony Mchailidis
#>

$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
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
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}
"login ok" 

#Variables
$P10=0
$P20=0
$P30=0
$P40=0
$P50=0
$PremiumStorageMaxGbps=0
$StandardDisks=0
$P10Size=128
$P20Size=512
$P30Size=1024
$P40Size=2048
$P50Size=4095
$PremiumStorageLimitGB=35840
$PremiumStorageLimitGbps=50
$StandardStorageLimitIOPS=20000
$StandardStorageLimitDisks=40
$StandardOutputArray=@()
$PremiumOutputArray=@()

$VMs=@{
    Standard_B1s=10;
    Standard_B1ms=10;
    Standard_B2s=15;
    Standard_B2ms=23;
    Standard_B4ms=35;
    Standard_B8ms=50;
    Standard_DS1=32;
    Standard_DS2=64;
    Standard_DS3=128;
    Standard_DS4=256;
    Standard_DS11=64;
    Standard_DS12=128;
    Standard_DS13=256;
    Standard_DS14=512;
    Standard_DS1_v2=48;
    Standard_DS2_v2=96;
    Standard_DS3_v2=192;
    Standard_DS4_v2=384;
    Standard_DS5_v2=768;
    Standard_DS11_v2=96;
    Standard_DS12_v2=192;
    Standard_DS13_v2=384;
    Standard_DS14_v2=768;
    Standard_DS15_v2=960;
    Standard_D2s_v3=48;
    Standard_D4s_v3=96;
    Standard_D8s_v3=192;
    Standard_D16s_v3=384;
    Standard_D32s_v3=768;
    Standard_D64s_v3=1200;
    Standard_E2s_v3=48;
    Standard_E4s_v3=96;
    Standard_E8s_v3=192;
    Standard_E16s_v3=384;
    Standard_E32s_v3=768;
    Standard_E64s_v3=1200;
    Standard_F1s=48;
    Standard_F2s=96;
    Standard_F4s=192;
    Standard_F8s=384;
    Standard_F16s=768;
    Standard_GS1=125;
    Standard_GS2=250;
    Standard_GS3=500;
    Standard_GS4=1000;
    Standard_GS5=2000;
    Standard_L4s=125;
    Standard_L8s=250;
    Standard_L16s=500;
    Standard_L32s=1000;
    Standard_M64s=1000;
    Standard_M64ms=1000;
    Standard_M128s=2000;
}

#Standard Storage Accounts
$StandardStorageAccounts=Get-AzureRmStorageAccount|Where-Object {$_.Sku.Tier -eq "Standard"}
 
foreach ($StandardStorageAccount in $StandardStorageAccounts)
{
   
    $StandardVHDs=Get-AzureStorageBlob -Context $StandardStorageAccount.Context -Container vhds -ErrorAction SilentlyContinue|Where-Object {$_.BlobType -eq "PageBlob"}
    $StandardDisks=0
    foreach($StandardVHD in $StandardVHDs){
        $StandardDisks+=1
        if(($StandardDisks) -gt $StandardStorageLimitDisks)
        { 
            $uri = Get-AutomationVariable -Name 'TeamsURI'              
            $payload1 = @{
            "text" = "I found out that the following standard virtual hard disk has exceeded its storage capacity: $StandardVHD. Consider upgrading it."
            }
            $json1 = ConvertTo-Json $payload1      
            Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
        }
        if((500*$StandardDisks) -gt $StandardStorageLimitIOPS)
        { 
            $uri =  Get-AutomationVariable -Name 'TeamsURI'      
            $payload1 = @{
            "text" = "I found out that the following standard virtual hard disk has exceeded its IOPS (Input/Output Operations Per Second): $StandardVHD. Consider upgrading it."
            }
            $json1 = ConvertTo-Json $payload1      
            Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
        }
    }
} 
   
#Premium Storage Accounts
$PremiumStorageAccounts=Get-AzureRmStorageAccount|Where-Object {$_.Sku.Tier -eq "Premium"}
 
 
foreach($PremiumStorageAccount in $PremiumStorageAccounts)
{
    
    $PremiumVHDs=Get-AzureStorageBlob -Context $PremiumStorageAccount.Context -Container vhds -ErrorAction SilentlyContinue|Where-Object {$_.BlobType -eq "PageBlob"}
    $P10=0
    $P20=0
    $P30=0
    $P40=0
    $P50=0
    $PremiumStorageMaxGbps=0
    $PremiumVMs=Get-AzureRmVM -WarningAction SilentlyContinue|Where-Object {$VMs.keys -ccontains $_.HardwareProfile.VmSize}
    foreach($PremiumVHD in $PremiumVHDs){
        $PDisk=0
        #Checking for DataDisks integration pending
        foreach($PremiumVM in $PremiumVMs){
            if($PremiumVHD.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri -eq $PremiumVM.StorageProfile.OsDisk.Vhd.Uri){
                $VMsize=$PremiumVM.HardwareProfile.VMsize
                $PremiumStorageMaxGbps+=$VMs.$VMsize
            }
            if($PremiumVM.StorageProfile.DataDisks.Count -ne 0){
                $DataDisks=$PremiumVM.StorageProfile.DataDisks
                foreach($DataDisk in $DataDisks){
                    if($PremiumVHD.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri -eq $DataDisk.Vhd.Uri -and ($PremiumVM.StorageProfile.OsDisk.vhd.Uri -split "/")[2] -ne ($DataDisk.Vhd.Uri -split "/")[2]){
                        $VMsize=$PremiumVM.HardwareProfile.VMsize
                        $PremiumStorageMaxGbps+=$VMs.$VMsize
                    }
                }
            }
        }

        $PDisk=[math]::Round($PremiumVHD.Length/1GB)

        if($PDisk -le 128){
            $P10+=1
        }
        elseif($PDisk -gt 128 -and $PDisk -le 512){
            $P20+=1
        }
        elseif($PDisk -gt 512 -and $PDisk -le 1024){
            $P30+=1
        }
        elseif($PDisk -gt 1024 -and $PDisk -le 2048){
            $P40+=1
        }
        else{
            $P50+=1
        }
    }
    if((($PremiumStorageMaxGbps*8)/1000) -gt $PremiumStorageLimitGbps){
            $uri = Get-AutomationVariable -Name 'TeamsURI'  
            $payload1 = @{
            "text" = "I found out that the following premium virtual hard disk has exceeded its gigabytes per second maximum capability: $PremiumVM. Consider upgrading it."
            }
            $json1 = ConvertTo-Json $payload1      
            Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
    }
    if((($P10*$P10Size)+($P20*$P20Size)+($P30*$P30Size)+($P40*$P40Size)+($P50*$P50Size)) -gt $PremiumStorageLimitGB)
    {
            $uri = Get-AutomationVariable -Name 'TeamsURI'             
            $payload1 = @{
            "text" = "I found out that the following premium virtual hard disk has exceeded its storage capacity: $PremiumVM. Consider upgrading it."
            }
            $json1 = ConvertTo-Json $payload1      
            Invoke-RestMethod -uri $uri -Method Post -body $json1 -ContentType 'Application/Json'
        }
}     

 