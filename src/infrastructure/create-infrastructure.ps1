$ErrorActionPreference = "Stop"

$KubernetesInfrastructureFolder = "C:\kubernetes"

$UbuntuDownloadURL = "https://releases.ubuntu.com/22.04.3/ubuntu-22.04.3-live-server-amd64.iso"
$PathToUbuntuISO = "$KubernetesInfrastructureFolder\ubuntu-server.iso"

$PublicNetworkSwitchName = "k8s-public-network"
$InternalNetworkSwitchName = "k8s-internal-network"

$MasterVMConfig = @{
    Name = "k8s-master"
    CPU = 2
    Memory = 3GB
    DiskSize = 20GB
}

$WorkerVMConfig = @{
    Name = "k8s-worker"
    CPU = 4
    Memory = 7GB
    Count = 3
}

function Select-PublicNetworkAdapter {
    $netAdapters = Get-NetAdapter | Select-Object -Property Name, Status, InterfaceDescription
    
    Write-Host "Available Network Adapters:"
    $netAdapters | ForEach-Object {
        Write-Host ($netAdapters.IndexOf($_) + 1) ":" $_.InterfaceDescription "(" $_.Status ")"
    }
    
    $selectedAdapterIndex = Read-Host -Prompt "Please select the number of the network adapter to use for the external switch"
    return $netAdapters[$selectedAdapterIndex - 1].Name
}

function New-VirtualMachine {
    param (
        [string]$Name,
        [int]$CPU,
        [string]$Memory,
        [string]$DiskSize,
        [string]$OperatingSystemISOPath,
        [string]$PublicNetworkSwitchName,
        [string]$InternalNetworkSwitchName,
        [string]$FilesOutputPath
    )

    New-VM -Name $Name `
        -Path "$FilesOutputPath\$Name" `
        -MemoryStartupBytes $Memory `
        -Generation 2 `
        -NewVHDPath "$FilesOutputPath\$Name\drive.vhdx" `
        -NewVHDSizeBytes $DiskSize `
        -SwitchName $PublicNetworkSwitchName

    Set-VMProcessor -VMName $Name -Count $CPU
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
    Add-VMDvdDrive -VMName $Name -Path $OperatingSystemISOPath
    Add-VMNetworkAdapter -VMName $Name -SwitchName $InternalNetworkSwitchName

    $dvd = Get-VMDvdDrive -VMName $Name
    $hdd = Get-VMHardDiskDrive -VMName $Name
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off -BootOrder $dvd,$hdd
}

function New-KubernetesNodeTemplate {
    param (
        [string]$TemplateVirtualMachineName,
        [string]$TemplatePath
    )

    Start-VM -Name $TemplateVirtualMachineName

    Read-Host "Please install Ubuntu Server on the Template VM. Press ENTER once the installation is complete..."
    
    Stop-VM -Name $TemplateVirtualMachineName -TurnOff
    Export-VM -Name $TemplateVirtualMachineName -Path $TemplatePath
}

function New-VirtualMachineFromTemplate {
    param (
        [string]$Name,
        [string]$Memory,
        [int]$CPU,
        [string]$TemplatePath,
        [string]$FilesOutputPath
    )

    $VM = Import-VM -Path $TemplatePath `
        -Copy `
        -GenerateNewId `
        -VhdDestinationPath "$FilesOutputPath\$Name" `
        -VirtualMachinePath "$FilesOutputPath\$Name"
    
    Rename-VM -VM $VM -NewName $Name
    Set-VMProcessor -VMName $Name -Count $CPU
    Set-VMMemory -VMName $Name -StartupBytes $Memory -DynamicMemoryEnabled $false
}

if (-not(Test-Path $KubernetesInfrastructureFolder)) {
    New-Item $KubernetesInfrastructureFolder -ItemType Directory
}

Start-BitsTransfer `
    -Source $UbuntuDownloadURL `
    -Destination $PathToUbuntuISO

$selectedNetAdapterName = Select-PublicNetworkAdapter

Write-Host "Creating Public network Virtual Switch..."
New-VMSwitch -Name $PublicNetworkSwitchName `
    -NetAdapterName $selectedNetAdapterName `
    -AllowManagementOS $true `
    -Notes "K8S public network NAT switch"

Write-Host "Creating Internal network Virtual Switch..."
New-VMSwitch -Name $InternalNetworkSwitchName `
    -SwitchType Internal `
    -Notes "K8S internal network switch"

Write-Host "Creating Control Plain VM..."
New-VirtualMachine -Name $MasterVMConfig.Name `
    -CPU $MasterVMConfig.CPU `
    -Memory $MasterVMConfig.Memory `
    -DiskSize $MasterVMConfig.DiskSize `
    -OperatingSystemISOPath $PathToUbuntuISO `
    -PublicNetworkSwitchName $PublicNetworkSwitchName `
    -InternalNetworkSwitchName $InternalNetworkSwitchName `
    -FilesOutputPath $KubernetesInfrastructureFolder

Write-Host "Exporting Control Plain VM as a template.."
New-KubernetesNodeTemplate -TemplateVirtualMachineName $MasterVMConfig.Name `
    -TemplatePath "$KubernetesInfrastructureFolder\kubernetes-node-template"

$templatePath = Get-ChildItem `
    -Recurse `
    -Path "$KubernetesInfrastructureFolder\kubernetes-node-template" *.vmcx | % { $_.FullName }

Write-Host "Creating Workers VMs..."
1..$WorkerVMConfig.Count | ForEach-Object {
    $Name = "$($WorkerVMConfig.Name)-$($_)"
    New-VirtualMachineFromTemplate -Name $Name `
        -Memory $WorkerVMConfig.Memory `
        -CPU $WorkerVMConfig.CPU `
        -TemplatePath $templatePath `
        -FilesOutputPath $KubernetesInfrastructureFolder
}

Write-Host "Setup complete"