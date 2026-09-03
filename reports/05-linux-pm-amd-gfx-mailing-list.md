# Mailing list report

**To:** linux-pm@vger.kernel.org
**Cc:** amd-gfx@lists.freedesktop.org, linux-kernel@vger.kernel.org
**Subject:** [BUG] Mendocino laptop: data fabric sync flood resets (0x08000800), stopped by disabling C3 + NVMe APST + PCIe ASPM + GFXOFF

*(Plain text only. Send with `git send-email` or a client with rich text disabled.)*

---

Hi,

I am reporting log-less spontaneous warm resets on an AMD Mendocino laptop, and a set of power-management parameters that appears to stop them, in case it helps identify whether a quirk is warranted.

Hardware:
  Acer Aspire A314-23P, board Evelyne_MDU, Insyde BIOS V1.13 (2026-06-09)
  AMD Ryzen 5 7520U (family 17h, model A0h), microcode 0x08a0000a
  Radeon 610M [1002:1506] rev c1, amdgpu, DCN 3.1.6
  8 GB LPDDR5 soldered, no ECC
  Micron 2450 NVMe [1344:5411], DRAM-less, 64 MiB HMB
  MediaTek MT7902 [14c3:7902], mt7921e

Kernel: 7.1.12-200.fc44 (Fedora 44), Secure Boot enabled.

Symptom: the machine resets itself with no kernel output at all. Eight events in
twelve hours, uptimes from 76 seconds to 3 hours, under load and near idle alike.
No panic, no oops, no MCE, no hung task.

On each subsequent boot the kernel's own reset-reason decoding reports:

  x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused
  a data fabric sync flood event

Boots following a deliberate reboot instead report [0x00080800] (0xCF9 write), so
the write-1-to-clear in print_s5_reset_status_mmio() is working and each message
describes exactly the preceding reset.

NVMe SMART power_cycles and unsafe_shutdowns do not increment across these events,
so the drive keeps power: SoC-level warm reset, not power loss.

Nothing survives the reset: pstore is disabled in Fedora's config
(CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y), there are no BERT/HEST tables, and the
firmware refuses AER to the OS:

  acpi PNP0A08:00: _OSC: platform does not support [SHPCHotplug AER]

Mitigation, applied together, no reset since (plus a clean 15-minute stress-ng run):

  processor.max_cstate=2
  nvme_core.default_ps_max_latency_us=0
  pcie_ports=native
  amdgpu.ppfeaturemask=0xfff73fff      # stock 0xfff7bfff with PP_GFXOFF_MASK cleared
  pcie_aspm.policy=performance

Before the change, cpuidle exposed an ACPI C3 (IOPORT 0x415, 350 us) that was being
entered several hundred thousand times per hour; it is gone with max_cstate=2.

One documentation note that cost me time and may be worth clarifying: pcie_aspm=off
is a no-op on this platform. Per Documentation/admin-guide/kernel-parameters.txt it
means "Don't touch ASPM configuration at all. Leave any configuration done by
firmware unchanged", and this firmware enables L1/L1.1/L1.2. lspci still showed
"LnkCtl: ASPM L1 Enabled" after booting with it. pcie_aspm.policy=performance is
what actually clears it. A great deal of community advice for exactly this class of
problem recommends pcie_aspm=off and silently achieves nothing.

I have not yet bisected which of the five parameters is responsible; I can do so
one at a time if that is useful, though each iteration needs a day or two of uptime
to be meaningful.

Possibly related prior report on the same SoC: random reboots with no logs on a
Ryzen 5 7520U / Radeon 610M, bisected to a GFXOFF-related SDMA doorbell workaround
and fixed by reverting it in 6.10.4:
https://gitlab.freedesktop.org/drm/amd/-/work_items/3556

Happy to provide full logs, lspci -vvnn, dmidecode and the stress test output.

Thanks,


---

All logs, the full boot table and the stress test results are published at
https://github.com/alx-mp/acer-a314-23p-sync-flood
