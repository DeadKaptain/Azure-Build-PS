<#
Script to automate the creation of enviroment in Azure and upload pre configured disks to the vms
Create by Tech Services - Cor Financial 13/03/2017
#>

# Import the correct Azure Module and Login to Azure account
Import-Module AzureRM
Login-AzureRmAccount 

# Function to automate the file explorer call
Function Get-FileName($initialDirectory)
{
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
    
    $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $OpenFileDialog.initialDirectory = $initialDirectory
    $OpenFileDialog.filter = 'CSV (*.csv)| *.csv'
    $OpenFileDialog.ShowDialog() | Out-Null
    $OpenFileDialog.filename
}

# Create table listing the types of storage in Azure since azure do not do it them selfs.
$storageSkuNames = @{"Standard_LRS"="Locally-redundant storage";"Standard_ZRS"="Zone-redundant storage";"Standard_GRS"="Geo-redundant storage";"Standard_RAGRS"="Read access geo-redundant storage";"Premium_LRS"="Premium locally-redundant storage"}

Write-Host 'Cor Financial Azure Enviroment Provisioning Utility v1.0'
Write-Host 'This program will walk through the Provisioning of an enviroment in Azure on the Cor Financial account.'
Write-Host 'Current Resource Groups and Location'
Get-AzureRmResourceGroup | Format-Table ResourceGroupName, Location

#Get option from user to create new VM or rebuild VM by attaching uploaded disk
$forkRoad = Read-Host -Prompt 'Please press 1 if you would like to create a new Enviroment and VM or 2 if you would like to create new Enviroment and restore backed up disks to VMs'

# Request Resource Group Name - currenty do not use anything other than upper / lower case and numbers as this is used else where in the code
$rgName = Read-Host -Prompt 'Enter the Resource Group Name (i.e. Salerio - This must be unique, listed above are the current Resource Group Names)'
Write-Host 'Available Data Center Locations'
Get-AzureRmLocation | Format-Table Location, DisplayName

# Request the locaton for the Resource Group and all VMs and storage.
$location = Read-Host -Prompt 'Enter the location of DC (i.e. uksouth - This must be a valid DC from the list above)'
New-AzureRmResourceGroup -Name $rgName -Location $location

# Request the IPAddress for RDP access
$rdpIP = Read-Host -Prompt 'Enter the Source IP address for RDP access (This will be your external ip address)'

# This code makes sure the storage name is lowercase and then creates it in azure ready for disk upload
$storageSkuNames | Format-Table -AutoSize
$Storage = ($rgName+'storage').ToLower()
$skuName = Read-Host -Prompt 'Enter the kind of storage you would like from the list above'
New-AzureRmStorageAccount -ResourceGroupName $rgName -Name $Storage -SkuName $skuName -Kind 'Storage' -Location $location

# Creating a Subnet and Vnet to configure the network for the Azure VMs
$subnetName = $rgName+'Subnet'
$vnetName = $rgName+'Vnet'
$singleSubnet = New-AzureRmVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix 10.0.0.0/24
$vnet = New-AzureRMVirtualNetwork -Name $vnetName -ResourceGroupName $rgName -Location $location -AddressPrefix 10.0.0.0/16 -Subnet $singleSubnet

if ($forkRoad -eq 1)
    {
        write-host 'not done this bit yet'
    }
else {

# Select CSV file for import of multiple VM setails into a custom object
Write-Host 'Select the csv file containing VM details'
$vmList = @()
$inputFile = Get-FileName 'C:\'
$vmImpList = Import-Csv $inputFile
ForEach ($objVM in $vmImpList)
    {
        $objVMDetail = New-Object System.Object
        $objVMDetail | Add-Member -Type NoteProperty -Name Name -Value $objVM.Name
        $objVMDetail | Add-Member -Type NoteProperty -Name Disk -Value $objVM.Disk
        $objVMDetail | Add-Member -Type NoteProperty -Name DiskName -Value $objVM.DiskName
        $objVMDetail | Add-Member -Type NoteProperty -Name URL -Value $objVM.URL
        # Capture the imput of VM size per VM in the list
        Get-AzureRmVmSize -Location $location | Sort-Object Name | Format-Table Name, NumberOfCores, MemoryInMB, MaxDataDiskCount -AutoSize
        $vmSelectSize = Read-Host -Prompt 'From the available VM size templates listed above, please enter one that fits best'
        $objVMDetail | Add-Member -Type NoteProperty -Name vmSize -Value $vmSelectSize
        $vmList += $objVMDetail
    }

# For each of the VM Disks in the Custom object, upload to the storage account created earlier
ForEach ($object in $vmList)
    {
       $uploadUri = 'https://'+$Storage+'.blob.core.windows.net/vhds/'+$object.DiskName
       Add-AzureRmVhd -ResourceGroupName $rgName -Destination $uploadUri -LocalFilePath $object.URL
    }

# This section does a ton of stuff so see comments inside the loop
ForEach ($object in $vmList)
    {
        # If the current entry in the custom object created from the list of VMs is for disk 1 then do this 
        if ($object.Disk -eq 1)
        {
            # Obtain Ext IP adddress
            $ipName = $object.Name+'IP'
            $pip = New-AzureRmPublicIpAddress -Name $ipName -ResourceGroupName $rgName -Location $location -AllocationMethod Dynamic
            # Set up nic for VM and associate with Ext IP for access
            $nicName = $object.Name+'Nic'
            $nic = New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $rgName -Location $location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id
            # Confgure Network Secutiry Group and add rule to firewall to allow RDP Access
            $nsgName = $object.Name+'NSG'
            $rdpRule = New-AzureRmNetworkSecurityRuleConfig -Name RDPRule -Description 'Allow RDP to Office' -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix $rdpIP -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389
            $nsg = New-AzureRmNetworkSecurityGroup -ResourceGroupName $rgName -Location $location -Name $nsgName -SecurityRules $rdpRule
            # Create New VM vmConfig
            $vmName = $object.Name
            $vmConfig = New-AzureRmVMConfig -VMName $vmName -VMSize $object.vmSize
            # Add the nic to the VM config file
            $vm = Add-AzureRmVMNetworkInterface -VM $vmConfig -Id $nic.Id
            # Add the Disk uploaded to the VM
            $osDiskUri = 'https://'+$Storage+'.blob.core.windows.net/vhds/'+$object.DiskName
            $osDiskName = $object.Name+'osDisk'
            $vm = Set-AzureRmVMOSDisk -VM $vm -Name $osDiskName -VhdUri $osDiskUri -CreateOption Attach -Windows
            # Create the VM using all the config created above
            New-AzureRmVM -ResourceGroupName $rgName -Location $location -VM $vm
        }
    else {
            # If the current entry in the custom object created from the list of vms is for disk 2 or more then do this
            $dataDiskName = $object.Name+'dataDisk'+$object.Disk
            $dataDiskUri = 'https://'+$Storage+'.blob.core.windows.net/vhds/'+$object.DiskName
            $vm = Add-AzureRmVMDataDisk -VM $vm -Name $dataDiskName -VhdUri $dataDiskUri -Lun 1 -CreateOption attach
         }
    }
}
# As always, Double check your work
Write-Host 'Please confirm your new vms appear in the list below :'

Get-AzureRmVM -Status | Format-Table

<#
Refrence Material for the above script :
https://docs.microsoft.com/en-us/azure/virtual-machines/virtual-machines-windows-create-vm-specialized
https://technet.microsoft.com/en-us/library/ff730946.aspx
http://www.workingsysadmin.com/open-file-dialog-box-in-powershell/
https://mcpmag.com/articles/2016/03/09/working-with-the-if-statement.aspx

Still to Do :

1. Validate properly all inputs for length/special/hacks to prevent errors and or data loss
2. Write code to allow for creation of new VM in Azure in a new resource group or existing
3. Supress warnings and confirmation outputs on screen to keep the dialogue clean
#>