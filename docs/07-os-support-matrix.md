# OS support matrix

Which guest operating systems can actually be migrated from BIOS to UEFI, and by which route. Use this before planning a migration wave — it is the difference between "convert in place in 20 minutes" and "this needs a rebuild".

Verdict legend:

| | Meaning |
|---|---|
| ✅ | In-place conversion supported by the scripts in this repository |
| ⚠️ | Possible, but with a documented constraint (offline media, Secure Boot off, …) |
| ❌ | Not supported — rebuild the workload on a modern OS instead |

---

## Windows Server

| Version | Build | UEFI boot | Secure Boot | `MBR2GPT` native | Hyper-V Gen 2 guest | Support status | Verdict |
|---|---|---|---|---|---|---|---|
| 2003 / 2003 R2 | 5.2 | ❌ | ❌ | ❌ | ❌ | Ended Jul 2015 | ❌ Rebuild |
| 2008 / 2008 R2 | 6.0 / 6.1 | ✅ (x64) | ❌ | ❌ | ❌ **not a supported Gen 2 guest** | Ended Jan 2020 | ❌ Rebuild |
| 2012 / 2012 R2 | 9200 / 9600 | ✅ | ✅ | ❌ (build < 15063) | ✅ | Extended ended Oct 2023; ESU ends **Oct 2026** | ⚠️ WinPE route only |
| 2016 | 14393 | ✅ | ✅ | ❌ (build < 15063) | ✅ | Ends **Jan 2027** | ⚠️ WinPE route only |
| 2019 | 17763 | ✅ | ✅ | ✅ | ✅ | Ends Jan 2029 | ✅ |
| 2022 | 20348 | ✅ | ✅ | ✅ | ✅ | Ends Oct 2031 | ✅ |
| 2025 | 26100 | ✅ | ✅ | ✅ | ✅ | Ends Nov 2034 | ✅ |

### The Server 2016 / 2012 R2 trap

`MBR2GPT.exe` shipped with Windows 10 version **1703 (build 15063)**. Windows Server 2016 is built on the 1607 codebase (build 14393) and **does not include it**; Server 2012 R2 (9600) is older still. The common assumption that "Server 2016 has MBR2GPT" is wrong.

For these two versions the conversion is still possible, but only offline:

1. Boot the VM from **WinPE 10.0.15063 or later** media (Windows 10 1703+ / Server 2019+ ADK).
2. Run `mbr2gpt /validate /disk:0` then `mbr2gpt /convert /disk:0` — note: **no `/allowFullOS`**, which is only for a running OS.
3. Shut down, switch the firmware, boot.

`scripts/windows/Test-UefiReadiness.ps1` detects this case and tells you so rather than failing with a bare "tool not found".

> Copying `mbr2gpt.exe` from a newer Windows into an older one is not supported by Microsoft and is not recommended: the binary depends on the servicing stack of the OS it ships with.

### Windows guests on Hyper-V Generation 2

Generation 2 requires a **64-bit** guest and supports **Windows Server 2012 and later** (and Windows 8 x64 and later). Windows Server 2008 R2 and 2003 have no Generation 2 path at all — there is no firmware to switch to. For those, the answer is a rebuild, not a migration.

On VMware this constraint does not exist in the same form: you can set `firmware = efi` on a VM running an older Windows, but the guest still has to be able to boot UEFI, so 2008 R2 and earlier remain a rebuild in practice.

---

## Red Hat Enterprise Linux

Applies equally to the RHEL-compatible rebuilds of each generation (CentOS, AlmaLinux, Rocky Linux).

| Version | UEFI boot | Secure Boot | Hyper-V Gen 2 guest | Support status | Verdict |
|---|---|---|---|---|---|
| RHEL 5 | ❌ not viable on x86_64 | ❌ | ❌ | EOL Nov 2020 (ELS ended) | ❌ Rebuild |
| RHEL 6 | ⚠️ present but unreliable | ❌ | ❌ (Gen 2 needs 7.0+) | EOL Nov 2020; ELS ended Jun 2024 | ❌ Rebuild |
| RHEL 7 | ✅ | ✅ (first RHEL with Secure Boot, Jun 2014) | ✅ (7.0+) | EOL Jun 2024; ELS available | ⚠️ Works, but the OS is EOL |
| RHEL 8 | ✅ | ✅ | ✅ | Full support ended May 2024; maintenance to May 2029 | ✅ |
| RHEL 9 | ✅ | ✅ | ✅ | Full support to May 2027; maintenance to May 2032 | ✅ |
| RHEL 10 | ✅ | ✅ | ✅ | Released May 2025; maintenance to ~May 2035 | ✅ |

### Why RHEL 6 is marked unreliable rather than supported

RHEL 6 ships `efibootmgr` and anaconda can install in UEFI mode, so on paper it qualifies. In practice the GPT/UEFI path in RHEL 6 carried known defects — including `efibootmgr` failing to create a boot entry when boot variables exceeded 1024 bytes — and several Red Hat products built on RHEL 6 shipped with legacy-only boot. Combined with the OS being past even its extended life phase, converting a RHEL 6 guest is effort spent on a system that should be replaced.

### Secure Boot on Linux guests

Secure Boot needs a signed shim (`shim-x64`), which RHEL provides from version 7. The firmware template matters and is a frequent cause of a VM that converts cleanly then refuses to boot:

- **Hyper-V**: use `MicrosoftUEFICertificateAuthority`, **not** `MicrosoftWindows`. `scripts/hyperv/Convert-Gen1ToGen2.ps1 -OSType Linux` selects this for you; `-DisableSecureBoot` turns it off entirely for unsigned kernels.
- **VMware**: hardware version ≥ 13, and the guest must have a signed shim and kernel.

> **Planning flag:** several Secure Boot signing certificates reach expiry during 2026, which affects how shims are signed and trusted going forward. If your migration wave is specifically motivated by enabling Secure Boot, check Red Hat's and Microsoft's current guidance on the 2026 certificate rollover before committing to a schedule.

---

## How to read this for a migration wave

Sort the estate into three buckets and treat them differently:

| Bucket | Contents | Action |
|---|---|---|
| **Convert** | Server 2019/2022/2025, RHEL 8/9/10 | Run the standard workflow from [00-overview.md](00-overview.md) |
| **Convert offline** | Server 2012 R2, Server 2016 | Same workflow, but the disk conversion step needs WinPE 1703+ media |
| **Rebuild** | Server 2003/2008/2008 R2, RHEL 5/6 | Do not convert. These are past end of support; build the replacement on a current OS and migrate the workload |

RHEL 7 sits between the last two: technically convertible, but out of full support since June 2024. Converting it buys a UEFI boot on an OS you will have to replace anyway — usually worth folding into the RHEL 8/9 upgrade instead of doing twice.

Generate the inventory to sort against with the audit scripts:

```powershell
.\scripts\vmware\Get-VMFirmwareReport.ps1 -VMName "*"      # VMware
.\scripts\hyperv\Get-VMGenerationReport.ps1                # Hyper-V
```

---

## Sources

Support dates and tool availability change; verify against the vendor before committing to a plan.

- [MBR2GPT.exe — Microsoft Learn](https://learn.microsoft.com/en-us/windows/deployment/mbr-to-gpt)
- [Should I create a generation 1 or 2 virtual machine in Hyper-V? — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v)
- [Supported Windows guest operating systems for Hyper-V — Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-windows-guest-operating-systems-for-hyper-v-on-windows)
- [Windows Server end of support — Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-365-apps/end-of-support/windows-server-support)
- [Red Hat Enterprise Linux Life Cycle — Red Hat Customer Portal](https://access.redhat.com/support/policy/updates/errata)
- [UEFI Secure Boot in Red Hat Enterprise Linux 7 — Red Hat Customer Portal](https://access.redhat.com/articles/1180943)
- [Secure Boot certificate changes in 2026: guidance for RHEL environments — Red Hat Developer](https://developers.redhat.com/articles/2026/02/04/secure-boot-certificate-changes-2026-guidance-rhel-environments)
