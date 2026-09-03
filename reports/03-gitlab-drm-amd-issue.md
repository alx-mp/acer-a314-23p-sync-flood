# New issue for gitlab.freedesktop.org/drm/amd

**Submit at:** https://gitlab.freedesktop.org/drm/amd/-/issues/new

---

**Title:** Mendocino (Ryzen 5 7520U / Radeon 610M): data fabric sync flood resets (0x08000800), mitigated by disabling GFXOFF + deep C-states + NVMe APST + PCIe ASPM

## Brief summary

An Acer Aspire A314-23P laptop running Fedora 44 with kernel 7.1.12 resets itself spontaneously several times per hour. The reset reason register decoded by the kernel reports a data fabric sync flood on every occurrence. Disabling GFXOFF together with deep C-states, NVMe APST and PCIe ASPM has so far stopped it. Filing here because GFXOFF on this exact SoC has previously caused log-less reboots (work item 3556) and because the display engine is one of the fabric agents that could be involved.

## Hardware description

* GPU: `03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Mendocino [Radeon 610M] [1002:1506] (rev c1)`, subsystem `Acer Incorporated [ALI] [1025:1653]`
* Display Core v3.2.378 on DCN 3.1.6; DMUB firmware 0x06001300
* CPU: Ryzen 5 7520U (family 17h model A0h), microcode 0x08a0000a
* RAM: 8 GB LPDDR5 soldered, no ECC
* Storage: Micron 2450 `1344:5411`, DRAM-less with 64 MiB HMB
* Platform: Acer Aspire A314-23P, board Evelyne_MDU, Insyde BIOS V1.13 (06/09/2026)
* Displays: lid closed, eDP-1 connected but disabled, single external LG monitor on HDMI-A-1 at 1366x768, 8 bpc

## System information

Fedora 44, kernel 7.1.12-200.fc44, mesa 26.1.8, mutter/gnome-shell 50.4, GNOME on Wayland, linux-firmware and amd-gpu-firmware 20260810.

## How to reproduce

Ordinary desktop use (browser, a VM, a terminal). No deterministic trigger found; resets occurred anywhere from 76 seconds to 3 hours into a session, both under load and near idle.

## Actual behaviour

The machine performs a warm reset with no kernel output whatsoever. On the next boot:

```
x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused a data fabric sync flood event
```

Eight consecutive occurrences, one-to-one with abrupt journal cuts. Boots ended by a normal reboot instead report `[0x00080800] software wrote 0x6 to reset control register 0xCF9`. NVMe SMART power-cycle and unsafe-shutdown counters do not increment across these events, confirming the drive keeps power: this is a SoC-level warm reset.

There is no MCE, no AER (the firmware refuses AER to the OS: `_OSC: platform does not support [SHPCHotplug AER]`), no BERT/HEST table, and pstore is disabled by Fedora's kernel config, so nothing survives the reset except the reset-reason register.

## Regression status

Unknown. The problem appeared on a fresh Fedora 44 install running 7.1.12. Kernel 6.19.10 is installed but only ran for 31 minutes total, so it cannot be cleared. The reporter's previous OS on the same hardware (Windows 11) did not exhibit spontaneous resets under heavy use.

## Mitigation

```
processor.max_cstate=2 nvme_core.default_ps_max_latency_us=0 pcie_ports=native \
amdgpu.ppfeaturemask=0xfff73fff pcie_aspm.policy=performance
```

`0xfff73fff` is the stock `0xfff7bfff` with `PP_GFXOFF_MASK` (0x8000) cleared. After this, a 15-minute mixed CPU/memory/IO stress run completed with no reset and no errors.

## Unrelated noise present in the logs

`dcn31_program_compbuf_size` WARNING (known 7.0 regression `592c5b80110d`, fixed by `251a01d34b44` in 7.3-rc1), `Failed to setup vendor infoframe on connector HDMI-A-1: -22` (monitor EDID has a 5-byte HDMI VSDB without HDMI_Video_present), and `REG_WAIT timeout ... optc31_disable_crtc` at driver init. All three also occur on boots that did not reset.

## Prior art on this SoC

https://gitlab.freedesktop.org/drm/amd/-/work_items/3556 — "Random reboots with AMD CPUs on kernel 6.10.3", included a Ryzen 5 7520U / Radeon 610M laptop, bisected to a GFXOFF/SDMA doorbell workaround and fixed by reverting it in 6.10.4.

https://gitlab.freedesktop.org/drm/amd/-/issues/4841 — same reset message on another Radeon 610M laptop.

## Question for AMD

Is there a known interaction on Mendocino between GFXOFF (or the display engine's system-memory scanout) and the data fabric that can raise an uncorrected fabric error, and is there a recommended firmware level or quirk? If the sync flood is expected to be diagnosable only from the BIOS side, please say so, so the report can be redirected to Acer.


---

All logs, the full boot table and the stress test results are published at
https://github.com/alx-mp/acer-a314-23p-sync-flood
