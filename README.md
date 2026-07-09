# Crabbox Template Boxes

Template configs and host scripts for building Crabbox boxes in a portable way.

- Linux boxes through Oracle Cloud
- Windows 10 ARM64 boxes through QEMU on a Windows ARM64 host
- Windows 11 ARM64 boxes through Hyper-V on a Windows ARM64 host

This repository intentionally does not include Microsoft ISOs, VHDX images,
PortableGit archives, VirtIO ISOs, private keys, or passwords. It publishes the
scripts and configs needed to recreate the setup from licensed/local inputs.

This is the fork-based template workspace:
- [crabbox-template-boxes](https://github.com/microck/crabbox-template-boxes)
- [crabbox windows provider fixes](https://github.com/Microck/crabbox/tree/fix/windows-native-external-sync)

## Template Guide

| Template | Platform | Backend | Image/template | Purpose | Notes |
| --- | --- | --- | --- | --- | --- |
| `linux-minimal` | Linux | External (Oracle Cloud) | `crabbox:minimal` | Fast base checks, short-lived tasks, small footprint | Verified |
| `linux-node` | Linux | External (Oracle Cloud) | `crabbox:node` | Node-first workflows, JS/TS tooling | Verified |
| `linux-full` | Linux | External (Oracle Cloud) | `crabbox:full` | Full Linux toolchain for broad CI/test work | Verified |
| `linux-browser` | Linux | External (Oracle Cloud) | `crabbox:browser` | Browser tasks and headful smoke runs | Verified |
| `win10-full` | Windows 10 ARM64 | Windows-host QEMU provider | `win10-arm64-clean-qemu-sealed` | Full Windows workflow that boots inside QEMU | Verified |
| `win11-full` | Windows 11 ARM64 | Windows-host Hyper-V provider | `win11-arm64-hyperv-base` | Lightweight Windows workspace with Hyper-V lease clones | Verified |
| `win11-full-qemu.candidate.yaml` | Windows 11 ARM64 | QEMU candidate | `win11-arm64` | Experimental path kept for reference | Not supported (SSH probe failed) |

Common Windows template settings:

- QEMU Windows guest: 4 vCPU, 3072 MB RAM, `virtio-net-pci`
- Win10 template `workRoot`: `C:\\crabbox-work`
- Win11 Hyper-V template `workRoot`: `C:\\Users\\Administrator\\work`

## Local Layout

Expected Windows host layout:

```text
C:\crabbox
  images\
    win10-arm64-clean-qemu-sealed.vhdx
    win11-arm64-hyperv-base.vhdx
  boxes\
    box-001.vhdx
  win10-qemu-manager.ps1
  win11-hyperv-manager.ps1
```

Expected Linux agent layout:

```text
~/.crabbox/
  templates/
  providers/
    windows-qemu-provider.sh
    windows-hyperv-provider.sh
    windows-hyperv-proxy.sh
  qemu-tunnels/
```

## Required Secrets

Do not commit these values. Export them in the shell or store them in a local
secret file outside this repository.

```sh
export CRABBOX_WINDOWS_HOST=<windows-host-ip-or-dns>
export CRABBOX_WINDOWS_USER=<windows-user>
export CRABBOX_WINDOWS_PASS='<windows-password>'
```

## Usage

Run a template by pointing `CRABBOX_CONFIG` at the config file:

```sh
CRABBOX_CONFIG=/path/to/templates/linux-full.yaml crabbox run -- uname -a
CRABBOX_CONFIG=/path/to/templates/win10-full.yaml crabbox run -- cmd.exe /c ver
CRABBOX_CONFIG=/path/to/templates/win11-full-hyperv.yaml crabbox run -- cmd.exe /c ver
```

## Rebuild Notes

Windows 10 QEMU requires these base-image steps:

1. Build or place a licensed Windows 10 ARM64 VHDX on the Windows host.
2. Patch VirtIO networking, OpenSSH key access, default shell, profile, and Git
   using the scripts in `scripts/win10/`.
3. Boot once with `scripts/windows-host/win10-qemu-manager.ps1`.
4. Shut down the guest and run `scripts/windows-host/seal-win10-qemu-postboot.ps1`.
5. Use `win10-arm64-clean-qemu-sealed` with 4 vCPU and 3072 MB RAM.

Windows 11 Hyper-V requires:

1. A licensed/prepared W11 ARM64 Hyper-V VHDX.
2. `scripts/windows-host/create-win11-hyperv-base.ps1` to copy it into
   `C:\crabbox\images\win11-arm64-hyperv-base.vhdx`.
3. `scripts/win10/patch-win10-ready-ssh-key.ps1` run against that base image to
   install the agent public key for Administrator SSH.
4. `scripts/windows-host/win11-hyperv-manager.ps1` to create per-lease
   differencing VMs.

## Verification Results

Recent verification:

| Path | Result |
| --- | --- |
| Linux minimal | passed, command total about 11s |
| Linux node | passed, command total about 11s |
| Linux full | passed, command total about 10s |
| Linux browser | passed, command total about 11s |
| W10 QEMU sealed full | passed, internal total about 1m17s, wall time about 2m36s |
| W11 Hyper-V full | passed, internal total about 1m13s, wall time about 3m12s |
