param(
    [string]$ImagePath = "C:\crabbox\images\win10-arm64-clean-qemu-ready.vhdx",
    [string]$SourceGitPath = "C:\Program Files\Git"
)

$ErrorActionPreference = "Stop"

$disk = $null
$osPartition = $null
$driveLetter = $null
$loadedSystem = $false

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
    if (!(Test-Path $SourceGitPath)) {
        throw "Missing source Git installation: $SourceGitPath"
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
    $targetGitPath = Join-Path $root "Program Files\Git"
    New-Item -ItemType Directory -Force -Path (Split-Path $targetGitPath -Parent) | Out-Null
    $robocopyOutput = & robocopy.exe $SourceGitPath $targetGitPath /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NP
    if ($LASTEXITCODE -ge 8) {
        throw "Failed to copy Git into image: $robocopyOutput"
    }

    $systemHive = Join-Path $root "Windows\System32\Config\SYSTEM"
    & reg.exe load HKLM\CBXGIT_SYSTEM $systemHive | Out-Null
    $loadedSystem = $true

    $gitPathEntries = @(
        "C:\Program Files\Git\cmd",
        "C:\Program Files\Git\bin",
        "C:\Program Files\Git\clangarm64\bin"
    )
    $controlSets = Get-ChildItem -Path "HKLM:\CBXGIT_SYSTEM" |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        Select-Object -ExpandProperty PSChildName

    foreach ($controlSet in $controlSets) {
        $envKey = "HKLM:\CBXGIT_SYSTEM\$controlSet\Control\Session Manager\Environment"
        $pathValue = (Get-ItemProperty -Path $envKey -Name Path -ErrorAction SilentlyContinue).Path
        if (!$pathValue) {
            $pathValue = "%SystemRoot%\system32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0\"
        }

        foreach ($entry in $gitPathEntries) {
            if ($pathValue -notlike "*$entry*") {
                $pathValue = "$pathValue;$entry"
            }
        }

        New-ItemProperty -Path $envKey -Name Path -PropertyType ExpandString -Value $pathValue -Force | Out-Null
    }

    [pscustomobject]@{
        imagePath = $ImagePath
        sourceGitPath = $SourceGitPath
        targetGitPath = "C:\Program Files\Git"
        controlSets = $controlSets
    } | ConvertTo-Json -Compress
}
finally {
    if ($loadedSystem) {
        Invoke-RegUnload -HiveName "HKLM\CBXGIT_SYSTEM"
    }
    if ($disk -and $osPartition -and $driveLetter -eq "W") {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -AccessPath "W:\" -ErrorAction SilentlyContinue
    }
    if ($disk) {
        Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
    }
}
