# Crabbox Template Boxes

Template configs and host scripts for Crabbox boxes:

- Linux boxes on Oracle Paris Docker
- Windows 10 ARM64 boxes through QEMU on a Windows ARM64 host
- Windows 11 ARM64 boxes through Hyper-V on a Windows ARM64 host

This repository intentionally does not include Microsoft ISOs, VHDX images,
PortableGit archives, VirtIO ISOs, private keys, or passwords. It publishes the
scripts and configs needed to recreate the setup from licensed/local inputs.

## Verified Templates

| Template | Config | Backend | Status |
| --- | --- | --- | --- |
| `linux-minimal` | `configs/linux-minimal.yaml` | Oracle Paris Docker `crabbox:minimal` | verified |
| `linux-node` | `configs/linux-node.yaml` | Oracle Paris Docker `crabbox:node` | verified |
| `linux-full` | `configs/linux-full.yaml` | Oracle Paris Docker `crabbox:full` | verified |
| `linux-browser` | `configs/linux-browser.yaml` | Oracle Paris Docker `crabbox:browser` | verified |
| `win10-full` | `configs/win10-full.yaml` | Windows-host QEMU `win10-arm64-clean-qemu-sealed` | verified |
| `win11-full` | `configs/win11-full-hyperv.yaml` | Windows-host Hyper-V `win11-arm64-hyperv-base` | verified |

`configs/win11-full-qemu.candidate.yaml` is included only as a record of the
candidate path. It did not reach SSH during verification and is not supported.

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
export CRABBOX_WINDOWS_HOST=100.85.142.35
export CRABBOX_WINDOWS_USER=microck
export CRABBOX_WINDOWS_PASS='...'
```

## Usage

Run a template by pointing `CRABBOX_CONFIG` at the config file:

```sh
CRABBOX_CONFIG=/home/ubuntu/.crabbox/templates/linux-full.yaml crabbox run -- uname -a
CRABBOX_CONFIG=/home/ubuntu/.crabbox/templates/win10-full.yaml crabbox run -- cmd.exe /c ver
CRABBOX_CONFIG=/home/ubuntu/.crabbox/templates/win11-full-hyperv.yaml crabbox run -- cmd.exe /c ver
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

Recent verification from `/home/ubuntu/work/crabbox`:

| Path | Result |
| --- | --- |
| Linux minimal | passed, command total about 11s |
| Linux node | passed, command total about 11s |
| Linux full | passed, command total about 10s |
| Linux browser | passed, command total about 11s |
| W10 QEMU sealed full | passed, internal total about 1m17s, wall time about 2m36s |
| W11 Hyper-V full | passed, internal total about 1m13s, wall time about 3m12s |

## Crabbox Fork

The Crabbox CLI changes that make the native Windows external-provider path
stable are pushed to:

```text
https://github.com/Microck/crabbox/tree/fix/windows-native-external-sync
```

Those changes include native Windows archive sync over SSH without short
OpenSSH keepalive probes, external provider SSH trust/proxy support, and tests.
