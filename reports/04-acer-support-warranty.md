# Acer support / warranty claim

**Submit at:** https://www.acer.com/us-en/support (Contact Support) or your local Acer service centre.

---

**Subject:** Aspire A314-23P, spontaneous warm resets logged by the CPU as an uncorrected data fabric error (AMD sync flood)

**Product:** Acer Aspire A314-23P
**System serial number:** SERIAL-SISTEMA-REDACTED
**Board:** Evelyne_MDU, serial SERIAL-PLACA-REDACTED
**BIOS:** Insyde V1.13, dated 06/09/2026 (currently installed; no newer version offered by Acer support or LVFS/fwupd)

---

Dear Acer Support,

The laptop identified above restarts itself without warning during normal use. On 2026-09-03 it did so eight times in approximately twelve hours, with the machine staying up anywhere between 76 seconds and 3 hours between events.

These are not operating-system crashes. The AMD processor records the cause of each reset in its own hardware register (FCH S5_RESET_STATUS), and on every restart following one of these events the register decodes as:

> `an uncorrected error caused a data fabric sync flood event` (status 0x08000800)

A "data fabric sync flood" is a protective reset performed by the AMD SoC itself when it detects an uncorrectable error on the internal interconnect that links the CPU, memory, PCIe and the integrated graphics. By design the operating system is reset before it can log anything, which is consistent with what we observe: no crash logs of any kind exist. For contrast, restarts we performed deliberately are recorded by the same register as ordinary software reboots (0x00080800), so the register is being read and cleared correctly on each boot.

We also confirmed the SSD never loses power across these events (its SMART power-cycle and unsafe-shutdown counters do not increase), which rules out a power interruption or the power button being held.

## What has been checked and excluded

* No overheating: under a 15-minute full-load stress test the package temperature stabilised at 92 C, which is the firmware's own limit, and dropped to 46 C within 30 seconds of the load ending. Cooling is working. No thermal events were logged, and the resets also happen at idle.
* No storage fault: the SSD reports zero media errors, 17% wear, and no controller errors.
* No memory errors were reported by the OS, though the machine has no ECC memory and the RAM is soldered, so a marginal DRAM cell cannot be excluded from software alone.
* Extensive operating-system-side troubleshooting was performed. Disabling the deepest CPU idle state, the SSD's autonomous power-state transitions, PCIe active-state power management and the GPU's power-gating feature appears to stop the resets. These are all power-management features of the platform, which is what points to a firmware or hardware issue rather than a software one.

## What we are asking for

1. Whether a BIOS/AGESA update newer than V1.13 exists or is planned for this model that addresses platform stability or memory training on the Ryzen 5 7520U. AMD's guidance for this class of fault is that it must be investigated by the system vendor's BIOS team.
2. Failing that, inspection of the mainboard and its soldered memory under warranty.

We are happy to provide the complete diagnostic evidence listed below, and to reproduce the fault on request.

Kind regards,

---

## Attachments

| File | Contents |
| --- | --- |
| `boots.txt` | list of boots with start and end timestamps |
| `motivo-reset-por-boot.txt` | reset reason recorded by the CPU for each boot |
| `motivo-reset.log` | ongoing log of reset reasons |
| `dmesg-boot0.txt` | full kernel log of a boot |
| `dmidecode.txt` | system, board and BIOS identification |
| `nvme-smart-log.txt` | SSD health report |
| `lspci-vvnn.txt` | PCI device and link state inventory |
| `prueba-estres-2026-09-03.log` | 15-minute stress test with temperature curve |
