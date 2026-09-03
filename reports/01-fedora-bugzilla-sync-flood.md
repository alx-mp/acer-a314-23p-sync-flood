# Red Hat Bugzilla report: spontaneous hardware resets

**Submit at:** https://bugzilla.redhat.com/enter_bug.cgi?product=Fedora
**Product:** Fedora · **Version:** 44 · **Component:** kernel · **Hardware:** x86_64 · **OS:** Linux · **Severity:** high

---

## Summary

Spontaneous hardware resets (AMD data fabric sync flood, S5_RESET_STATUS 0x08000800) on Acer Aspire A314-23P (Ryzen 5 7520U "Mendocino") with kernel 7.1.12-200.fc44; worked around by disabling deep C-states, NVMe APST, PCIe ASPM and GFXOFF

## Description of problem

On a freshly installed Fedora 44 Workstation the machine resets itself spontaneously, several times per hour under normal desktop use. Uptimes before a reset ranged from 76 seconds to about 3 hours. The journal simply stops mid-line with no shutdown sequence, `last -x` records `crash`, and there is no panic, oops, MCE, hung task, AER event or pstore record of any kind.

The reason is recorded by the kernel itself on the following boot. `arch/x86/kernel/cpu/amd.c` reads and clears `FCH::PM::S5_RESET_STATUS` on Zen CPUs, so each message describes exactly the preceding reset:

```
x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused a data fabric sync flood event
```

Boots that followed an ordinary reboot instead report:

```
x86/amd: Previous system reset reason [0x00080800]: software wrote 0x6 to reset control register 0xCF9
```

A data fabric sync flood is a platform-level reset performed by the SoC when an uncorrected error is detected on the interconnect, which is why the OS never gets the chance to log anything.

## Version-Release number of selected component

```
kernel-core-7.1.12-200.fc44.x86_64   (also installed: kernel-core-6.19.10-300.fc44.x86_64)
systemd-259.8-1.fc44.x86_64
mesa-dri-drivers-26.1.8-1.fc44.x86_64
mutter-50.4-1.fc44.x86_64 / gnome-shell-50.4-1.fc44.x86_64
linux-firmware-20260810-1.fc44.noarch
amd-gpu-firmware-20260810-1.fc44.noarch
amd-ucode-firmware-20260810-1.fc44.noarch  (microcode revision 0x08a0000a)
```

## Hardware

| Item | Value |
| --- | --- |
| System | Acer Aspire A314-23P, board Evelyne_MDU |
| BIOS | Insyde V1.13, 06/09/2026 (latest offered; not on LVFS) |
| CPU | AMD Ryzen 5 7520U with Radeon Graphics (family 17h, model A0h, Mendocino/Zen2) |
| GPU | Radeon 610M `1002:1506` rev c1, amdgpu, DCN 3.1.6 |
| RAM | 8 GB LPDDR5 soldered, 2x4 GiB Samsung K3LKBKB0BM-MGCP at 5500 MT/s, no ECC |
| Storage | Micron 2450 MTFDKBA512TFK `1344:5411`, firmware V5MA010, DRAM-less, 64 MiB HMB |
| WiFi | MediaTek MT7902 `14c3:7902` (mt7921e) |
| Display | Lid closed, internal eDP-1 connected but disabled, external LG monitor on HDMI-A-1 |

## How reproducible

Always, during ordinary desktop use (web browser, a GNOME Boxes VM, a terminal). No specific trigger was identified: one reset happened 76 seconds after boot while a process was starting, another after three hours of light use.

## Actual results

Ten consecutive boots, with the reset reason each one reported for its predecessor:

| Boot | Kernel | Started | Last journal entry | Uptime | Reset reason reported next boot |
| --- | --- | --- | --- | --- | --- |
| -9 | 6.19.10 | 2026-09-02 23:44 | 2026-09-03 00:15:43 | 31 min | 0xCF9 software reboot (clean, post-update) |
| -8 | 7.1.12 | 00:16 | 00:18:49 | 176 s | **0x08000800 sync flood** |
| -7 | 7.1.12 | 00:19 | 00:40:54 | 21 min | 0xCF9 (clean shutdown by user) |
| -6 | 7.1.12 | 05:40 | 06:11:16 | 31 min | **0x08000800 sync flood** |
| -5 | 7.1.12 | 06:11 | 07:22:55 | 71 min | **0x08000800 sync flood** |
| -4 | 7.1.12 | 07:29 | 10:34:18 | 177 min | **0x08000800 sync flood** |
| -3 | 7.1.12 | 10:39 | 10:40:16 | 76 s | **0x08000800 sync flood** |
| -2 | 7.1.12 | 10:42 | 11:19:55 | 38 min | **0x08000800 sync flood** |
| -1 | 7.1.12 | 11:22 | 11:28:49 | 6 min | **0x08000800 sync flood** |
| 0 | 7.1.12 | 11:39 | (mitigations applied) | n/a | 0xCF9 (deliberate reboot) |

The correlation between an abrupt journal cut and a sync flood is one to one.

The NVMe SMART counters `power_cycles` (69822) and `unsafe_shutdowns` (60435) did **not** increase across one of these resets, which confirms the drive never lost power: these are warm resets driven by the SoC, not power loss and not a user holding the power button.

## Expected results

No spontaneous resets, or at minimum a platform quirk / documented default that prevents them on this SoC.

## Additional info

### What was ruled out

* `WARNING ... dcn31_hubbub.c:151 dcn31_program_compbuf_size` appears on almost every boot, including the ones that survived, and on the currently stable boot. It is the known 7.0 regression from commit `592c5b80110d` and is cosmetic here. Filed separately as a backport request.
* `Failed to setup vendor infoframe on connector HDMI-A-1: -22`, because the monitor's EDID has a 5-byte HDMI VSDB without `HDMI_Video_present`; present on clean boots too.
* `ACPI BIOS Error ... [\TPST], AE_ALREADY_EXISTS`, `WMBF method ... not found`, `Bluetooth: hci0: Failed to read MSFT supported features (-56)`, `Lockdown: systemd-logind: hibernation is restricted`, all identical on boots that did not reset.
* A kernel OOM killed a qemu process 8 minutes before one reset, but other resets happened with no memory pressure at all (one 76 seconds after boot).
* No MCE, no EDAC, no thermal events, no NVMe controller resets, no hung tasks in any boot.

### Why nothing is captured

pstore is compiled with `CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y`, the platform exposes no BERT/HEST tables, and the firmware refuses AER to the OS (`acpi PNP0A08:00: _OSC: platform does not support [SHPCHotplug AER]`). More importantly, a sync flood resets the SoC before the OS can run any handler, so kdump and pstore cannot help by design.

### Mitigation that appears to work

Applied together on 2026-09-03:

```
processor.max_cstate=2 nvme_core.default_ps_max_latency_us=0 pcie_ports=native \
amdgpu.ppfeaturemask=0xfff73fff pcie_aspm.policy=performance
```

Verified after reboot: `cpuidle` exposes only POLL/C1/C2 (the ACPI C3 IOPORT 0x415 state, 350 us latency, was being entered hundreds of thousands of times per hour); NVMe APST disabled; `LnkCtl: ASPM Disabled` on both the NVMe and the WiFi endpoint; GFXOFF cleared from `ppfeaturemask`; AER now enabled natively on all three root ports.

**Note for whoever documents this:** `pcie_aspm=off` does **not** work on this platform. Per `Documentation/admin-guide/kernel-parameters.txt`, `off` means "Don't touch ASPM configuration at all. Leave any configuration done by firmware unchanged", and this Acer firmware leaves L1/L1.1/L1.2 enabled. `pcie_aspm.policy=performance` is required to actually clear it. Many community write-ups recommend `pcie_aspm=off` for this class of problem and it silently does nothing here.

A 15-minute `stress-ng` run (`--cpu 6 --cpu-method all --vm 2 --vm-bytes 1G --vm-method all --io 2 --hdd 1`) completed with 0 failures, no reset and no errors from rasdaemon, at a sustained 92 C package temperature.

### What is being asked

1. Whether these five parameters can be narrowed to the single responsible one, and whether a DMI-matched quirk is warranted for this platform, as was done for other Mendocino laptops.
2. Whether Fedora should note in the AMD debugging documentation that `pcie_aspm=off` is a no-op when firmware has already enabled ASPM.
3. Prior art on the same SoC: https://gitlab.freedesktop.org/drm/amd/-/work_items/3556 reported "random reboots with no logs" on a Ryzen 5 7520U / Radeon 610M laptop, bisected to a GFXOFF-related SDMA commit and fixed by reverting it in 6.10.4. GFXOFF is one of the four things disabled here.

### References

* https://docs.kernel.org/arch/x86/amd-debugging.html
* https://raw.githubusercontent.com/torvalds/linux/master/arch/x86/kernel/cpu/amd.c (`s5_reset_reason_txt`)
* https://gitlab.freedesktop.org/drm/amd/-/issues/4841 (same message on a Radeon 610M laptop; AMD's comment attributed it to bad memory)
* https://community.frame.work/t/fw13-amd-ai-300-hx-370-48-data-fabric-sync-flood-crashes-in-2-months-comprehensive-data/80338 (102 sync floods traced to DRAM-less NVMe firmware)
* https://forum.proxmox.com/threads/0x08000800-an-uncorrected-error-caused-a-data-fabric-sync-flood-event.182401/

### Attachments

`boots.txt`, `motivo-reset-por-boot.txt`, `motivo-reset.log`, `dmesg-boot0.txt`, `lspci-vvnn.txt`, `dmidecode.txt`, `nvme-smart-log.txt`, `paquetes.txt`, `cpuidle-antes-del-cambio.txt`, `bls-despues-del-cambio.txt`, `prueba-estres-2026-09-03.log`


---

All logs, the full boot table and the stress test results are published at
https://github.com/alx-mp/acer-a314-23p-sync-flood
