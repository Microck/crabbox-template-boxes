param(
    [string]$ImagePath = "C:\crabbox\images\win10-arm64-clean-qemu-ready.vhdx",
    [string]$CrabboxSid = "S-1-5-21-2794893809-2807624048-130396024-1000"
)

$ErrorActionPreference = "Stop"

$disk = $null
$osPartition = $null
$driveLetter = $null
$loadedSoftware = $false

function Grant-SidFullControl {
    param(
        [string]$Path,
        [string]$Sid
    )

    $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    $containerRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $fileRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $acl = Get-Acl -LiteralPath $_.FullName
            if ($_.PSIsContainer) {
                $acl.SetAccessRule($containerRule)
            }
            else {
                $acl.SetAccessRule($fileRule)
            }
            Set-Acl -LiteralPath $_.FullName -AclObject $acl
        }

    $rootAcl = Get-Acl -LiteralPath $Path
    $rootAcl.SetAccessRule($containerRule)
    Set-Acl -LiteralPath $Path -AclObject $rootAcl
}

function Invoke-RegUnload {
    param([string]$HiveName)

    for ($i = 0; $i -lt 5; $i++) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $result = & reg.exe unload $HiveName 2>&1
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "Failed to unload $HiveName after retries: $result"
}

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
    $defaultProfile = Join-Path $root "Users\Default"
    $crabboxProfile = Join-Path $root "Users\crabbox"
    $staleProfile = Join-Path $root "Users\crabbox.CRABBOX-W10"

    if (!(Test-Path $defaultProfile)) {
        throw "Missing Default profile: $defaultProfile"
    }

    New-Item -ItemType Directory -Force -Path $crabboxProfile | Out-Null
    $robocopyOutput = & robocopy.exe $defaultProfile $crabboxProfile /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NP
    if ($LASTEXITCODE -ge 8) {
        throw "Failed to seed crabbox profile from Default: $robocopyOutput"
    }

    Remove-Item -Recurse -Force $staleProfile -ErrorAction SilentlyContinue

    Grant-SidFullControl -Path $crabboxProfile -Sid $CrabboxSid

    $softwareHive = Join-Path $root "Windows\System32\Config\SOFTWARE"
    & reg.exe load HKLM\CBXPROFILE_SOFTWARE $softwareHive | Out-Null
    $loadedSoftware = $true

    $profileKey = "HKLM:\CBXPROFILE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$CrabboxSid"
    New-Item -Path $profileKey -Force | Out-Null
    New-ItemProperty -Path $profileKey -Name ProfileImagePath -PropertyType ExpandString -Value "C:\Users\crabbox" -Force | Out-Null
    New-ItemProperty -Path $profileKey -Name Flags -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $profileKey -Name State -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $profileKey -Name RefCount -PropertyType DWord -Value 0 -Force | Out-Null

    [pscustomobject]@{
        imagePath = $ImagePath
        sid = $CrabboxSid
        profilePath = "C:\Users\crabbox"
        seeded = $true
    } | ConvertTo-Json -Compress
}
finally {
    if ($loadedSoftware) {
        Invoke-RegUnload -HiveName "HKLM\CBXPROFILE_SOFTWARE"
    }
    if ($disk -and $osPartition -and $driveLetter -eq "W") {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -AccessPath "W:\" -ErrorAction SilentlyContinue
    }
    if ($disk) {
        Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
    }
}
