param(
    [string]$ImagePath = "C:\crabbox\images\win10-arm64-clean-qemu-ready.vhdx"
)

$ErrorActionPreference = "Stop"

$disk = $null
$osPartition = $null
$driveLetter = $null
$loadedSoftware = $false
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
    $disk = Mount-VHD -Path $ImagePath -PassThru | Get-Disk
    $osPartition = Get-Partition -DiskNumber $disk.Number |
        Where-Object { $_.GptType -eq "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" } |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if (!$osPartition) {
        throw "Could not find the Windows OS partition in $ImagePath."
    }

    if (!$osPartition.DriveLetter) {
        $driveLetter = "W"
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -NewDriveLetter $driveLetter
    }
    else {
        $driveLetter = $osPartition.DriveLetter
    }

    $root = "${driveLetter}:"
    $softwareHive = Join-Path $root "Windows\System32\Config\SOFTWARE"
    $systemHive = Join-Path $root "Windows\System32\Config\SYSTEM"

    & reg.exe load HKLM\CBXOFF_SOFTWARE $softwareHive | Out-Null
    $loadedSoftware = $true
    & reg.exe load HKLM\CBXOFF_SYSTEM $systemHive | Out-Null
    $loadedSystem = $true

    # Crabbox only needs SSH for command execution. Interactive autologon makes
    # every disposable overlay pay Windows' first desktop/profile setup cost,
    # which blocks OpenSSH readiness under QEMU. Leave the guest at the login
    # screen and let the LocalSystem sshd service accept the crabbox password.
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v ForceAutoLogon /t REG_SZ /d 0 /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d crabbox /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultDomainName /t REG_SZ /d "CRABBOX-W10" /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f | Out-Null
    Remove-ItemProperty -Path "HKLM:\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name AutoLogonCount -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\CBXOFF_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name DefaultPassword -ErrorAction SilentlyContinue
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v CrabboxStartSshd /t REG_SZ /d "cmd.exe /c C:\ProgramData\crabbox\start-sshd.cmd" /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f | Out-Null
    & reg.exe add "HKLM\CBXOFF_SOFTWARE\Policies\Microsoft\Windows\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f | Out-Null

    $controlSets = Get-ChildItem -Path "HKLM:\CBXOFF_SYSTEM" |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } |
        Select-Object -ExpandProperty PSChildName

    foreach ($controlSet in $controlSets) {
        $serviceKey = "HKLM:\CBXOFF_SYSTEM\$controlSet\Services\sshd"
        New-Item -Path $serviceKey -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name Type -PropertyType DWord -Value 16 -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name Start -PropertyType DWord -Value 2 -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name ErrorControl -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name DelayedAutoStart -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name ImagePath -PropertyType ExpandString -Value '"C:\Program Files\OpenSSH\sshd.exe" -E C:\ProgramData\ssh\logs\sshd.log' -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name ObjectName -PropertyType String -Value LocalSystem -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name DisplayName -PropertyType String -Value "OpenSSH SSH Server" -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name Description -PropertyType String -Value "OpenSSH SSH Server" -Force | Out-Null
        New-ItemProperty -Path $serviceKey -Name RequiredPrivileges -PropertyType MultiString -Value @(
            "SeAssignPrimaryTokenPrivilege",
            "SeTcbPrivilege",
            "SeBackupPrivilege",
            "SeRestorePrivilege",
            "SeImpersonatePrivilege"
        ) -Force | Out-Null

        # Windows can block unattended boot with the first network discovery
        # prompt. Suppress that prompt in the offline SYSTEM hive so a fresh
        # QEMU overlay reaches the SSH startup path without console input.
        $networkPromptKey = "HKLM:\CBXOFF_SYSTEM\$controlSet\Control\Network\NewNetworkWindowOff"
        New-Item -Path $networkPromptKey -Force | Out-Null
    }

    $startupDir = Join-Path $root "ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    $programDataCrabbox = Join-Path $root "ProgramData\crabbox"
    $programDataSSHLogs = Join-Path $root "ProgramData\ssh\logs"
    New-Item -ItemType Directory -Force -Path $programDataCrabbox | Out-Null
    New-Item -ItemType Directory -Force -Path $programDataSSHLogs | Out-Null
    New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
    $startupScript = @'
@echo off
sc.exe config sshd start= auto >NUL 2>NUL
netsh advfirewall firewall add rule name="OpenSSH-Server-In-TCP" dir=in action=allow protocol=TCP localport=22 >NUL 2>NUL
net start sshd >NUL 2>NUL
'@
    Set-Content -Path (Join-Path $startupDir "crabbox-start-sshd.cmd") -Value $startupScript -Encoding ASCII
    Set-Content -Path (Join-Path $programDataCrabbox "start-sshd.cmd") -Value $startupScript -Encoding ASCII

    [pscustomobject]@{
        imagePath = $ImagePath
        status = "patched"
        autologon = "disabled"
        networkPrompt = "suppressed"
        firstLogonAnimation = "disabled"
        controlSets = $controlSets
        startupScript = Join-Path $programDataCrabbox "start-sshd.cmd"
    } | ConvertTo-Json -Compress
}
finally {
    if ($loadedSystem) {
        Invoke-RegUnload -HiveName "HKLM\CBXOFF_SYSTEM"
    }
    if ($loadedSoftware) {
        Invoke-RegUnload -HiveName "HKLM\CBXOFF_SOFTWARE"
    }
    if ($disk -and $osPartition -and $driveLetter -eq "W") {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $osPartition.PartitionNumber -AccessPath "W:\" -ErrorAction SilentlyContinue
    }
    if ($disk) {
        Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
    }
}
