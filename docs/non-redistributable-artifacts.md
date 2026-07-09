# Non-Redistributable Artifacts

The following local artifacts are required to reproduce this exact setup, but
they are not published in this repository:

| Artifact | Reason |
| --- | --- |
| Windows ISO files under `C:\crabbox\isos` | Microsoft licensing |
| Windows VHDX images under `C:\crabbox\images` and `C:\crabbox\boxes` | Microsoft licensing and local machine state |
| PortableGit archives copied from the Windows host | Third-party binary redistribution should use upstream source URLs |
| VirtIO ISO under `C:\crabbox\sources` | Fetch from the upstream VirtIO release source |
| SSH private keys and Windows host password | credentials |

The scripts in this repository are intended to recreate those artifacts from
locally licensed media and upstream downloads.
