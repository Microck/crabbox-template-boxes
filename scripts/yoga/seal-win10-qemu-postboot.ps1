param(
    [string]$Name = "seal-win10-postboot",
    [string]$OutputImage = "C:\crabbox\images\win10-arm64-clean-qemu-sealed.vhdx"
)

$ErrorActionPreference = "Stop"

$Root = "C:\crabbox"
$VmRoot = Join-Path $Root "vms"
$QemuImg = "C:\Program Files\qemu\qemu-img.exe"
$Dir = Join-Path $VmRoot $Name
$Overlay = Join-Path $Dir "disk.qcow2"

if (!(Test-Path $Overlay)) {
    throw "Missing overlay: $Overlay"
}
if (!(Test-Path $QemuImg)) {
    throw "Missing qemu-img: $QemuImg"
}

$process = Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-aarch64.exe'" |
    Where-Object { $_.CommandLine -like "*$Dir*" } |
    Select-Object -First 1
if ($process) {
    Stop-Process -Id $process.ProcessId -Force
    Start-Sleep -Seconds 5
}

$taskName = "CrabboxQemu-$Name"
cmd.exe /c "schtasks /End /TN `"$taskName`" >NUL 2>NUL"
cmd.exe /c "schtasks /Delete /TN `"$taskName`" /F >NUL 2>NUL"

if (Test-Path $OutputImage) {
    Remove-Item -Force $OutputImage
}

& $QemuImg convert -p -O vhdx $Overlay $OutputImage
if ($LASTEXITCODE -ne 0) {
    throw "qemu-img convert failed with exit $LASTEXITCODE"
}

Get-Item $OutputImage |
    Select-Object FullName, Length, LastWriteTime |
    ConvertTo-Json -Compress
