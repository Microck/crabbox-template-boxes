param(
    [string]$SourceVM = "box-001",
    [string]$SourceDisk = "C:\crabbox\boxes\box-001.vhdx",
    [string]$OutputDisk = "C:\crabbox\images\win11-arm64-hyperv-base.vhdx"
)

$ErrorActionPreference = "Stop"

if (!(Get-VM -Name $SourceVM -ErrorAction SilentlyContinue)) {
    throw "Missing source VM: $SourceVM"
}
if (!(Test-Path $SourceDisk)) {
    throw "Missing source disk: $SourceDisk"
}

$wasRunning = (Get-VM -Name $SourceVM).State -ne "Off"
if ($wasRunning) {
    Stop-VM -Name $SourceVM -TurnOff -Force
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-VM -Name $SourceVM).State -ne "Off" -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
}

if (Test-Path $OutputDisk) {
    Remove-Item -Force $OutputDisk
}
Copy-Item $SourceDisk $OutputDisk

if ($wasRunning) {
    Start-VM -Name $SourceVM
}

Get-Item $OutputDisk |
    Select-Object FullName, Length, LastWriteTime |
    ConvertTo-Json -Compress
