param(
    [ValidateSet("doctor", "create", "destroy", "status", "list")]
    [string]$Action = "status",

    [string]$Name = "cbx-win10",
    [string]$Template = "win10-arm64",
    [int]$MemoryMb = 3072,
    [int]$CpuCount = 1,
    [int]$SshPort = 0,
    [string]$Machine = "virt,virtualization=on,highmem=off",
    [string]$Cpu = "cortex-a72",
    [ValidateSet("nvme", "usb", "ahci")]
    [string]$Disk = "nvme",
    [ValidateSet("e1000e", "e1000", "rtl8139", "usb-net", "i82559er", "virtio-net-pci")]
    [string]$NetDevice = "virtio-net-pci"
)

$ErrorActionPreference = "Stop"

$Root = "C:\crabbox"
$VmRoot = Join-Path $Root "vms"
$ImageRoot = Join-Path $Root "images"
$QemuRoot = "C:\Program Files\qemu"
$QemuExe = Join-Path $QemuRoot "qemu-system-aarch64.exe"
$QemuImg = Join-Path $QemuRoot "qemu-img.exe"
$FirmwareCode = Join-Path $QemuRoot "share\edk2-aarch64-code.fd"

function Get-BaseImage {
    param([string]$TemplateName)

    switch ($TemplateName) {
        "win10-arm64" { return Join-Path $ImageRoot "win10-arm64.vhdx" }
        "win10-arm64-qemu" { return Join-Path $ImageRoot "win10-arm64-qemu.vhdx" }
        "win10-arm64-clean-qemu" { return Join-Path $ImageRoot "win10-arm64-clean-qemu.vhdx" }
        "win10-arm64-clean-qemu-ready" { return Join-Path $ImageRoot "win10-arm64-clean-qemu-ready.vhdx" }
        "win10-arm64-clean-qemu-sealed" { return Join-Path $ImageRoot "win10-arm64-clean-qemu-sealed.vhdx" }
        "win11-arm64" { return Join-Path $ImageRoot "win11-arm64.vhdx" }
        default { throw "Unsupported template: $TemplateName" }
    }
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 0)
    $listener.Start()
    try {
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Get-FreeVncDisplay {
    for ($display = 20; $display -lt 100; $display++) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 5900 + $display)
            $listener.Start()
            return [pscustomobject]@{ display = $display; port = 5900 + $display }
        }
        catch {
        }
        finally {
            if ($listener) { $listener.Stop() }
        }
    }
    throw "No free VNC display in 20-99"
}

function Get-BoxState {
    param([string]$BoxName)

    $dir = Join-Path $VmRoot $BoxName
    $pidFile = Join-Path $dir "qemu.pid"
    $portFile = Join-Path $dir "ssh.port"
    $vncPortFile = Join-Path $dir "vnc.port"
    $monitorPortFile = Join-Path $dir "monitor.port"
    $taskFile = Join-Path $dir "task.name"

    $processId = $null
    $running = $false
    if (Test-Path $pidFile) {
        $processId = [int](Get-Content $pidFile -Raw)
        $running = [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue)
    }

    if (!$running -and (Test-Path $dir)) {
        $process = Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-aarch64.exe'" |
            Where-Object { $_.CommandLine -like "*$dir*" } |
            Select-Object -First 1
        if ($process) {
            $processId = [int]$process.ProcessId
            $running = $true
            Set-Content -Path $pidFile -Value $processId -Encoding ASCII
        }
    }

    $port = ""
    if (Test-Path $portFile) {
        $port = (Get-Content $portFile -Raw).Trim()
    }

    $vncPort = ""
    if (Test-Path $vncPortFile) {
        $vncPort = (Get-Content $vncPortFile -Raw).Trim()
    }

    $monitorPort = ""
    if (Test-Path $monitorPortFile) {
        $monitorPort = (Get-Content $monitorPortFile -Raw).Trim()
    }

    [pscustomobject]@{
        name = $BoxName
        pid = $processId
        running = $running
        sshPort = $port
        vncPort = $vncPort
        monitorPort = $monitorPort
        dir = $dir
        taskName = if (Test-Path $taskFile) { (Get-Content $taskFile -Raw).Trim() } else { "" }
    }
}

function Stop-Box {
    param([string]$BoxName)

    $state = Get-BoxState -BoxName $BoxName
    if ($state.running) {
        Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
    }

    if ($state.taskName) {
        $previousErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            cmd.exe /c "schtasks /End /TN `"$($state.taskName)`" >NUL 2>NUL"
            cmd.exe /c "schtasks /Delete /TN `"$($state.taskName)`" /F >NUL 2>NUL"
        }
        finally {
            $ErrorActionPreference = $previousErrorPreference
        }
    }

    if (Test-Path $state.dir) {
        Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-aarch64.exe'" |
            Where-Object { $_.CommandLine -like "*$($state.dir)*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Start-Box {
    param(
        [string]$BoxName,
        [string]$TemplateName,
        [int]$Memory,
        [int]$Cpus,
        [int]$Port,
        [string]$MachineType,
        [string]$CpuType,
        [string]$DiskType,
        [string]$NetworkDevice
    )

    if (!(Test-Path $QemuExe)) { throw "Missing QEMU executable: $QemuExe" }
    if (!(Test-Path $QemuImg)) { throw "Missing qemu-img executable: $QemuImg" }
    if (!(Test-Path $FirmwareCode)) { throw "Missing AArch64 firmware: $FirmwareCode" }

    $baseImage = Get-BaseImage -TemplateName $TemplateName
    if (!(Test-Path $baseImage)) { throw "Missing base image: $baseImage" }

    $dir = Join-Path $VmRoot $BoxName
    New-Item -ItemType Directory -Force $dir | Out-Null

    $port = $Port
    if ($port -le 0) {
        $port = Get-FreePort
    }
    $vnc = Get-FreeVncDisplay
    $monitorPort = Get-FreePort

    $overlay = Join-Path $dir "disk.qcow2"
    $vars = Join-Path $dir "vars.fd"
    $pidFile = Join-Path $dir "qemu.pid"
    $portFile = Join-Path $dir "ssh.port"
    $vncPortFile = Join-Path $dir "vnc.port"
    $monitorPortFile = Join-Path $dir "monitor.port"
    $taskFile = Join-Path $dir "task.name"
    $runnerScript = Join-Path $dir "run-qemu.ps1"
    $stdoutLog = Join-Path $dir "qemu.stdout.log"
    $stderrLog = Join-Path $dir "qemu.stderr.log"
    $serialLog = Join-Path $dir "serial.log"

    if (!(Test-Path $overlay)) {
        & $QemuImg create -f qcow2 -F vhdx -b $baseImage $overlay | Out-Null
    }

    if (!(Test-Path $vars)) {
        $varsSource = Join-Path $QemuRoot "share\edk2-arm-vars.fd"
        if (Test-Path $varsSource) {
            Copy-Item $varsSource $vars
        }
        else {
            New-Item -ItemType File -Path $vars -Force | Out-Null
        }
    }

    Stop-Box -BoxName $BoxName

    Set-Content -Path $portFile -Value $port -Encoding ASCII
    Set-Content -Path $vncPortFile -Value $vnc.port -Encoding ASCII
    Set-Content -Path $monitorPortFile -Value $monitorPort -Encoding ASCII

    $diskArgs = switch ($DiskType) {
        "nvme" { @("-device", "nvme,drive=system,serial=$BoxName,bootindex=0") }
        "usb" { @("-device", "usb-storage,drive=system,bootindex=0") }
        "ahci" { @("-device", "ich9-ahci,id=ahci", "-device", "ide-hd,drive=system,bus=ahci.0,bootindex=0") }
    }

    $args = @(
        "-M", "$MachineType",
        "-cpu", "$CpuType",
        "-accel", "tcg,thread=multi",
        "-smp", "$Cpus",
        "-m", "$Memory",
        "-drive", "if=pflash,format=raw,readonly=on,file=$FirmwareCode",
        "-drive", "if=pflash,format=raw,file=$vars",
        "-device", "ramfb",
        "-device", "qemu-xhci",
        "-device", "usb-kbd",
        "-device", "usb-tablet",
        "-drive", "if=none,id=system,format=qcow2,file=$overlay"
    ) + $diskArgs + @(
        "-boot", "strict=on",
        "-netdev", "user,id=net0,hostfwd=tcp:0.0.0.0:$port-:22",
        "-device", "$NetworkDevice,netdev=net0",
        "-serial", "file:$serialLog",
        "-monitor", "tcp:127.0.0.1:$monitorPort,server,nowait",
        "-vnc", "127.0.0.1:$($vnc.display)",
        "-no-shutdown"
    )

    $quotedArgs = ($args | ForEach-Object {
        '"' + ($_ -replace '"', '`"') + '"'
    }) -join ",`r`n        "

    $runner = @"
`$ErrorActionPreference = "Stop"
Set-Location "$dir"
`$QemuExe = "$QemuExe"
`$QemuArgs = @(
        $quotedArgs
)
& `$QemuExe @QemuArgs 1>> "$stdoutLog" 2>> "$stderrLog"
"@
    Set-Content -Path $runnerScript -Value $runner -Encoding ASCII

    $taskName = "CrabboxQemu-$BoxName"
    Set-Content -Path $taskFile -Value $taskName -Encoding ASCII

    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`""
    schtasks.exe /Create /TN $taskName /SC ONCE /ST 23:59 /TR $taskCommand /F | Out-Null
    Set-ScheduledTask -TaskName $taskName -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 72)) | Out-Null
    schtasks.exe /Run /TN $taskName | Out-Null

    $process = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $process = Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-aarch64.exe'" |
            Where-Object { $_.CommandLine -like "*$dir*" } |
            Select-Object -First 1
        if ($process) { break }
    }

    if (!$process) {
        throw "QEMU did not start for $BoxName"
    }

    Set-Content -Path $pidFile -Value $process.ProcessId -Encoding ASCII

    [pscustomobject]@{
        name = $BoxName
        pid = $process.ProcessId
        sshPort = $port
        vncPort = $vnc.port
        monitorPort = $monitorPort
        dir = $dir
        baseImage = $baseImage
        overlay = $overlay
    } | ConvertTo-Json -Compress
}

switch ($Action) {
    "doctor" {
        if (!(Test-Path $QemuExe)) { throw "Missing QEMU executable: $QemuExe" }
        if (!(Test-Path (Get-BaseImage -TemplateName $Template))) { throw "Missing template image: $Template" }
        [pscustomobject]@{
            ok = $true
            qemu = $QemuExe
            template = $Template
            image = Get-BaseImage -TemplateName $Template
        } | ConvertTo-Json -Compress
    }
    "create" {
        Start-Box -BoxName $Name -TemplateName $Template -Memory $MemoryMb -Cpus $CpuCount -Port $SshPort -MachineType $Machine -CpuType $Cpu -DiskType $Disk -NetworkDevice $NetDevice
    }
    "destroy" {
        Stop-Box -BoxName $Name
        $dir = Join-Path $VmRoot $Name
        if (Test-Path $dir) {
            $removed = $false
            for ($i = 0; $i -lt 10; $i++) {
                try {
                    Remove-Item -Recurse -Force $dir -ErrorAction Stop
                    $removed = $true
                    break
                }
                catch {
                    Start-Sleep -Milliseconds 500
                }
            }
            if (!$removed -and (Test-Path $dir)) {
                Remove-Item -Recurse -Force $dir
            }
        }
        [pscustomobject]@{ ok = $true; name = $Name } | ConvertTo-Json -Compress
    }
    "status" {
        Get-BoxState -BoxName $Name | ConvertTo-Json -Compress
    }
    "list" {
        if (!(Test-Path $VmRoot)) {
            @() | ConvertTo-Json -Compress
            exit 0
        }
        Get-ChildItem -Directory $VmRoot | ForEach-Object {
            Get-BoxState -BoxName $_.Name
        } | ConvertTo-Json -Compress
    }
}
