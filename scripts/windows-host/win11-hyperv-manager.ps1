param(
    [ValidateSet("doctor", "create", "destroy", "status", "list")]
    [string]$Action = "status",

    [string]$Name = "cbx-win11",
    [string]$Template = "win11-arm64",
    [string]$SwitchName = "Default Switch",
    [int]$MemoryMb = 3072,
    [int]$CpuCount = 2
)

$ErrorActionPreference = "Stop"

$Root = "C:\crabbox"
$VmRoot = Join-Path $Root "vms"
$ImageRoot = Join-Path $Root "images"
$BoxRoot = Join-Path $Root "boxes"

function Get-TemplateDisk {
    param([string]$TemplateName)

    switch ($TemplateName) {
        "win11-arm64" { return Join-Path $ImageRoot "win11-arm64-hyperv-base.vhdx" }
        "win11-arm64-hyperv" { return Join-Path $ImageRoot "win11-arm64-hyperv-base.vhdx" }
        default { throw "Unsupported Hyper-V template: $TemplateName" }
    }
}

function Get-VMIPv4 {
    param([string]$VMName)

    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $ip = (Get-VM -Name $VMName -ErrorAction SilentlyContinue | Get-VMNetworkAdapter).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.*' } |
            Select-Object -First 1
        if ($ip) { return $ip }
        Start-Sleep -Seconds 2
    }
    return ""
}

function Stop-And-RemoveVM {
    param([string]$VMName)

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        if ($vm.State -ne "Off") {
            Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        }
        Remove-VM -Name $VMName -Force
    }
    $dir = Join-Path $VmRoot $VMName
    if (Test-Path $dir) {
        Remove-Item -Recurse -Force $dir
    }
}

function Get-BoxState {
    param([string]$VMName)

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (!$vm) {
        return [pscustomobject]@{
            name = $VMName
            state = "missing"
            ip = ""
        }
    }

    $ip = ($vm | Get-VMNetworkAdapter).IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.*' } |
        Select-Object -First 1

    [pscustomobject]@{
        name = $VMName
        state = $vm.State.ToString()
        ip = if ($ip) { $ip } else { "" }
    }
}

switch ($Action) {
    "doctor" {
        $templateDisk = Get-TemplateDisk -TemplateName $Template
        if (!(Test-Path $templateDisk)) { throw "Missing template disk: $templateDisk" }
        if (!(Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { throw "Missing switch: $SwitchName" }
        [pscustomobject]@{ ok = $true; template = $Template; disk = $templateDisk; switch = $SwitchName } |
            ConvertTo-Json -Compress
    }
    "create" {
        $templateDisk = Get-TemplateDisk -TemplateName $Template
        if (!(Test-Path $templateDisk)) { throw "Missing template disk: $templateDisk" }

        Stop-And-RemoveVM -VMName $Name

        $dir = Join-Path $VmRoot $Name
        New-Item -ItemType Directory -Force $dir | Out-Null
        $disk = Join-Path $dir "$Name.vhdx"
        $memoryBytes = [int64]$MemoryMb * 1MB
        New-VHD -Path $disk -ParentPath $templateDisk -Differencing | Out-Null

        New-VM -Name $Name -Generation 2 -MemoryStartupBytes $memoryBytes -VHDPath $disk -SwitchName $SwitchName -Path $dir | Out-Null
        Set-VMFirmware -VMName $Name -EnableSecureBoot Off
        Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes 512MB -StartupBytes $memoryBytes -MaximumBytes 1TB
        Set-VMProcessor -VMName $Name -Count $CpuCount
        Start-VM -Name $Name

        $ip = Get-VMIPv4 -VMName $Name
        if (!$ip) { throw "No IPv4 address obtained for VM $Name" }
        Write-Output "IP: $ip"
        [pscustomobject]@{ name = $Name; state = "Running"; ip = $ip; disk = $disk; template = $Template } |
            ConvertTo-Json -Compress
    }
    "destroy" {
        Stop-And-RemoveVM -VMName $Name
        [pscustomobject]@{ ok = $true; name = $Name } | ConvertTo-Json -Compress
    }
    "status" {
        Get-BoxState -VMName $Name | ConvertTo-Json -Compress
    }
    "list" {
        Get-VM | Where-Object { $_.Name -like "cbx-*" -or $_.Name -like "box-*" } | ForEach-Object {
            Get-BoxState -VMName $_.Name
        } | ConvertTo-Json -Compress
    }
}
