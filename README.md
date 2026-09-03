# Acer Aspire A314-23P: random reboots on Linux (AMD data fabric sync flood, 0x08000800)

Full diagnosis, evidence and a working mitigation for spontaneous, log-less reboots on an
**Acer Aspire A314-23P** (AMD Ryzen 5 7520U "Mendocino", Radeon 610M) running **Fedora 44**
with kernel 7.1.12.

If you own this laptop, or any Mendocino-based machine, and it restarts by itself with
nothing in the logs, start with [How to tell if this is your problem](#how-to-tell-if-this-is-your-problem).

---

## TL;DR

The machine was resetting itself several times per hour. There was no panic, no oops, no MCE,
no AER event and nothing in pstore, because **the reset is performed by the SoC itself** before
the operating system can react.

The CPU records the reason in its own register, and the kernel prints it on the next boot:

```
x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused a data fabric sync flood event
```

Adding these kernel parameters stopped it:

```
processor.max_cstate=2 nvme_core.default_ps_max_latency_us=0 pcie_ports=native \
amdgpu.ppfeaturemask=0xfff73fff pcie_aspm.policy=performance
```

> **Important gotcha:** `pcie_aspm=off` does nothing on this platform, even though it is what
> nearly every forum thread recommends for this class of problem. Per
> `Documentation/admin-guide/kernel-parameters.txt` it means *"Don't touch ASPM configuration at
> all. Leave any configuration done by firmware unchanged"*, and this Acer firmware leaves
> L1/L1.1/L1.2 enabled. You need `pcie_aspm.policy=performance` to actually clear it. Verify with
> `lspci -vv` that you see `LnkCtl: ASPM Disabled`, not just that the parameter is on the command line.

---

## How to tell if this is your problem

Run this after any unexplained restart:

```bash
journalctl -b 0 -k | grep -i "reset reason"
```

| What you see | What it means |
| --- | --- |
| `[0x08000800] ... data fabric sync flood event` | A hardware reset caused by an uncorrected error on the SoC interconnect. **This repository is about that.** |
| `[0x00080800] software wrote 0x6 to reset control register 0xCF9` | A normal reboot requested by the OS. Nothing wrong. |
| Nothing at all | Your CPU is not a Zen part, or your kernel predates the reset-reason decoding in `arch/x86/kernel/cpu/amd.c`. |

To see the whole history at once:

```bash
for b in $(journalctl --list-boots | awk '{print $1}'); do
  echo -n "boot $b: "; journalctl -b $b -k | grep -i "reset reason" | sed 's/.*kernel: //'
done
```

### A useful cross-check

Compare the SSD's power-cycle counters across a reset:

```bash
sudo nvme smart-log /dev/nvme0 | grep -E "power_cycles|unsafe_shutdowns"
```

If they **do not** increase, the drive never lost power, which proves it was a warm reset
ordered by the chip, not a power cut and not somebody holding the power button.

---

## What this is not

Several alarming messages appear on this hardware and are **not** the cause. All of them also
appear on boots that never reset:

| Message | Verdict |
| --- | --- |
| `WARNING ... dcn31_hubbub.c:151 dcn31_program_compbuf_size` | Known amdgpu regression introduced in kernel 7.0 by commit `592c5b80110d`, fixed upstream by `251a01d34b44` (v7.3-rc1 only, no `Cc: stable`). Cosmetic. |
| `Failed to setup vendor infoframe on connector HDMI-A-1: -22` | The monitor's EDID has a 5-byte HDMI VSDB without `HDMI_Video_present`. Cosmetic. |
| `REG_WAIT timeout ... optc31_disable_crtc` | Firmware-to-driver handoff at boot. Cosmetic. |
| `ACPI BIOS Error ... [\TPST], AE_ALREADY_EXISTS`, `WMBF method ... not found` | Acer DSDT/WMI firmware bugs. Cosmetic. |
| `Bluetooth: hci0: Failed to read MSFT supported features (-56)` | Cosmetic. |

---

## Applying the mitigation

```bash
sudo grubby --update-kernel=ALL --args="processor.max_cstate=2 nvme_core.default_ps_max_latency_us=0 pcie_ports=native amdgpu.ppfeaturemask=0xfff73fff pcie_aspm.policy=performance"
sudo reboot
```

### What each parameter does, and its cost

| Parameter | Effect | Cost |
| --- | --- | --- |
| `processor.max_cstate=2` | Removes the deepest ACPI idle state (C3, 350 us). Prime suspect: it was being entered hundreds of thousands of times per hour. | Higher idle power draw. |
| `nvme_core.default_ps_max_latency_us=0` | Disables the SSD's autonomous power state transitions (APST). | Slightly higher idle power. |
| `pcie_aspm.policy=performance` | Actually disables PCIe link power management. | Higher idle power on NVMe and WiFi. |
| `pcie_ports=native` | Takes PCIe services from firmware so the kernel can report AER errors, which this BIOS otherwise hides. | Diagnostic only. |
| `amdgpu.ppfeaturemask=0xfff73fff` | Stock `0xfff7bfff` with `PP_GFXOFF_MASK` (0x8000) cleared, disabling GPU power gating. | Higher GPU idle power. |

### Verifying it actually took effect

```bash
cat /proc/cmdline
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name          # C3 must be gone
cat /sys/module/nvme_core/parameters/default_ps_max_latency_us # 0
sudo lspci -vv -s 01:00.0 | grep LnkCtl                        # ASPM Disabled
printf '0x%x\n' $(cat /sys/module/amdgpu/parameters/ppfeaturemask)  # 0xfff73fff
dmesg | grep "AER: enabled"                                    # AER now native
```

### Narrowing it down

All five were applied at once to stop the bleeding. To recover idle battery life, remove them
one at a time, waiting 24-48 hours between steps, in this order: `amdgpu.ppfeaturemask`,
`pcie_ports=native`, `pcie_aspm.policy`, `nvme_core.default_ps_max_latency_us`, and
`processor.max_cstate=2` last, since it is the main suspect.

```bash
sudo grubby --update-kernel=ALL --remove-args="amdgpu.ppfeaturemask=0xfff73fff"
```

---

## Monitoring

`tools/log-reset-reason` plus its systemd unit record the reset reason of every boot to
`/var/log/motivo-reset.log`, so you have a durable history instead of relying on the journal
surviving a hard reset.

```bash
sudo install -m 0755 tools/log-reset-reason /usr/local/sbin/
sudo install -m 0644 tools/log-reset-reason.service /etc/systemd/system/
sudo systemctl enable --now log-reset-reason.service
```

`tools/syncflood-mitigation` and its unit re-apply the C-state, APST and ASPM settings at
runtime, as a belt-and-braces backup to the kernel parameters.

---

## Reporting templates

`reports/` contains ready-to-send English write-ups for:

* Red Hat Bugzilla, the reset itself
* Red Hat Bugzilla, requesting the amdgpu backport
* `gitlab.freedesktop.org/drm/amd`
* Acer support / warranty
* linux-pm and amd-gfx mailing lists

---

## If the mitigation does not hold

The one thing that cannot be excluded from software is the RAM. It is soldered, has no ECC, and
this BIOS exposes no BERT/HEST tables, so a marginal cell would be invisible. Run at least four
full passes of MemTest86 (Secure Boot must be disabled for Fedora's `memtest86+`, or use
PassMark's signed UEFI build). If memory is faulty, the board has to be replaced.

---

## Related reports from other people

* https://gitlab.freedesktop.org/drm/amd/-/work_items/3556 — random log-less reboots on a Ryzen 5 7520U / Radeon 610M, bisected to a GFXOFF-related SDMA commit, fixed by reverting it in 6.10.4
* https://gitlab.freedesktop.org/drm/amd/-/issues/4841 — same message on another Radeon 610M laptop
* https://community.frame.work/t/fw13-amd-ai-300-hx-370-48-data-fabric-sync-flood-crashes-in-2-months-comprehensive-data/80338 — 102 sync floods traced to DRAM-less NVMe firmware
* https://forum.proxmox.com/threads/0x08000800-an-uncorrected-error-caused-a-data-fabric-sync-flood-event.182401/
* https://gist.github.com/eliottness/ded6bce8163689dc426732d0670c7a28

## Kernel documentation

* https://docs.kernel.org/arch/x86/amd-debugging.html
* https://raw.githubusercontent.com/torvalds/linux/master/arch/x86/kernel/cpu/amd.c — the `s5_reset_reason_txt` table that decodes these codes

---

## Bonus: memory management on 8 GB

While diagnosing this, a second problem surfaced: Fedora ships **zram only, with no disk swap**,
so once compressed memory fills there is nowhere left to go and the desktop freezes. See
[`docs/memory-tuning.md`](docs/memory-tuning.md) for what was changed and the measurements.

---

## Disclaimer

Everything here comes from one machine. The parameters disable power-management features that
work fine on most laptops. They are a workaround, not a fix. The real fix has to come from AMD
or from Acer's firmware.

## License

Documentation and logs: CC BY 4.0. Scripts: MIT. See `LICENSE`.

## A note on the evidence

Every file under `evidence/` has been redacted. Serial numbers, the MAC address of the access
point, disk UUIDs, the machine ID, the hostname and the username were replaced with markers such
as `SERIAL-SISTEMA-REDACTED` and `MAC-REDACTED`. Model level information was left untouched,
since that is the part other people need.

`reports/04-acer-support-warranty.md` has the serial number redacted as well. Put your own in
before sending it to Acer.
