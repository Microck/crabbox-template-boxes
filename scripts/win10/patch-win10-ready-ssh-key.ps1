param(
    [string]$ImagePath = "C:\crabbox\images\win10-arm64-clean-qemu-ready.vhdx"
)

$ErrorActionPreference = "Stop"

$publicKey = [Console]::In.ReadToEnd().Trim()
if (!$publicKey) {
    throw "Public key was not provided on stdin."
}

$disk = $null
$osPartition = $null
$driveLetter = $null

try {
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
    $programDataSsh = Join-Path $root "ProgramData\ssh"
    $userSsh = Join-Path $root "Users\crabbox\.ssh"
    New-Item -ItemType Directory -Force -Path $programDataSsh, $userSsh | Out-Null

    $adminKeys = Join-Path $programDataSsh "administrators_authorized_keys"
    $userKeys = Join-Path $userSsh "authorized_keys"
    Set-Content -Encoding ASCII -Path $adminKeys -Value $publicKey
    Set-Content -Encoding ASCII -Path $userKeys -Value $publicKey

    icacls.exe $adminKeys /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null
    icacls.exe $userSsh /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null
    icacls.exe $userKeys /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null

    $sshdConfigPath = Join-Path $programDataSsh "sshd_config"
    $lines = @(
        "Port 22",
        "HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key",
        "PubkeyAuthentication yes",
        "PasswordAuthentication no",
        "AuthorizedKeysFile .ssh/authorized_keys",
        "Subsystem sftp internal-sftp",
        "Match Group administrators",
        "       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys"
    )
    Set-Content -Encoding ASCII -Path $sshdConfigPath -Value ($lines -join "`r`n")

    [pscustomobject]@{
        imagePath = $ImagePath
        authorizedKeys = "installed"
        sshdConfig = $sshdConfigPath
    } | ConvertTo-Json -Compress
}
finally {
    if ($disk -and $osPartition -and $driveLetter -eq "W") {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -AccessPath "W:\" -ErrorAction SilentlyContinue
    }
    if ($disk) {
        Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
    }
}
