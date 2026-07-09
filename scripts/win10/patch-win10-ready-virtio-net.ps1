param(
    [string]$ImagePath = "C:\crabbox\images\win10-arm64-clean-qemu-ready.vhdx",
    [string]$DriverIsoPath = "C:\crabbox\sources\virtio-win-0.1.285.iso"
)

$ErrorActionPreference = "Stop"

$disk = $null
$osPartition = $null
$driveLetter = $null
$driverImage = $null

try {
    if (!(Test-Path $ImagePath)) {
        throw "Missing Windows image: $ImagePath"
    }
    if (!(Test-Path $DriverIsoPath)) {
        throw "Missing VirtIO driver ISO: $DriverIsoPath"
    }

    $driverImage = Mount-DiskImage -ImagePath $DriverIsoPath -PassThru
    $driverVolume = $driverImage | Get-Volume
    $driverRoot = "$($driverVolume.DriveLetter):"
    $driverPath = Join-Path $driverRoot "NetKVM\w10\ARM64"

    if (!(Test-Path $driverPath)) {
        throw "Missing ARM64 NetKVM driver path in ISO: $driverPath"
    }

    $disk = Mount-VHD -Path $ImagePath -PassThru | Get-Disk
    $osPartition = Get-Partition -DiskNumber $disk.Number |
        Where-Object { $_.GptType -eq "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" } |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if (!$osPartition) {
        throw "Could not find Windows OS partition in $ImagePath."
    }

    if (!$osPartition.DriveLetter) {
        $driveLetter = "W"
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $driveLetter
    }
    else {
        $driveLetter = $osPartition.DriveLetter
    }

    $root = "${driveLetter}:"
    $result = Add-WindowsDriver -Path $root -Driver $driverPath -Recurse

    [pscustomobject]@{
        imagePath = $ImagePath
        driverPath = $driverPath
        added = @($result | ForEach-Object { $_.Driver })
    } | ConvertTo-Json -Compress
}
finally {
    if ($disk -and $osPartition -and $driveLetter -eq "W") {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -AccessPath "W:\" -ErrorAction SilentlyContinue
    }
    if ($disk) {
        Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
    }
    if ($driverImage) {
        Dismount-DiskImage -ImagePath $DriverIsoPath -ErrorAction SilentlyContinue
    }
}
