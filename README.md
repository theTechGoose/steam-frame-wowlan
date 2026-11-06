# Steam Frame Wake-on-WLAN — engineering handoff

## Conclusion

The Steam Frame (Qualcomm SM8650 SoC; Qualcomm WCN7850 Wi-Fi on PCIe, `17cb:1107`,
driven by `ath12k_pci`) cannot be woken from system suspend by a Wake-on-WLAN magic
packet, and no Linux-only change can make it. Proven on hardware: the WCN7850 firmware
*detects* the magic packet in every sleep mode, but it signals the host only with an
**in-band PCIe PM_PME** — and only when the host sets `WMI_WOW_FLAG_SEND_PM_PME` (0x2)
in `WMI_WOW_ENABLE` (mainline `ath12k` sends 0). It **never asserts the WAKE# sideband
pin**. On SM8650 an in-band PME cannot wake the SoC while it is asleep: the root port's
PME interrupt is a GIC ITS MSI, and no PCIe interrupt is routed through the PDC wake
controller. So the wake has no path to the power-management hardware. A complete,
hardware-tested host-side kernel patch is included here; it finishes the feature the
moment the firmware (or AOP) cooperates.

## What works / what is blocked / what we need from Valve

**Works today (on the 7.2 kernel):**
- The radio survives suspend with Wake-on-WLAN armed: clean MHI M3 entry and resume, no
  firmware crash, no RESET. (`skip_pwrctrl_off` keeps the rails up — already in Valve's
  `sm8650-7.2` branch.)
- The firmware detects the magic packet during sleep and reports
  `WOW_REASON_RECV_MAGIC_PATTERN` on the next resume.
- With one line added to `ath12k` (`WMI_WOW_FLAG_SEND_PM_PME`), the chip does raise an
  in-band PM_PME during the sleep — endpoint `PMCSR PME_Status` and root-port `RTSTA PME`
  are both set afterward.

**Blocked (cannot be fixed in the kernel):**
- The firmware never pulls WAKE# (tlmm 96) for a WoW event — not in L1ss, not in L2, with
  or without the PME flag. It only pulls WAKE# as a reaction to PERST# assertion.
- The in-band PM_PME cannot wake the SoC. The PME interrupt is a GIC ITS MSI; `enable_irq_wake()`
  on it fails, and even marked `IRQCHIP_SKIP_SET_WAKE` the PME MSI does not end the sleep
  (deep or s2idle) because no pcie0 interrupt is PDC-wakeable once the cluster collapses.
- CLKREQ# (tlmm 95), the one pin the device must toggle, is invisible to the TLMM/PDC while
  the PCIe controller owns the pad — and the controller has to own it (muxing it away kills
  the link mid-suspend and leaves Wi-Fi dead until reboot).

**Needed from Valve / Qualcomm (either one unblocks it):**
1. WCN7850 firmware that asserts **WAKE#** (tlmm 96) on a WoW event. The host side is done:
   this patch registers `wake-gpios` as a wakeup IRQ.
2. Or the **AOP PCIe DRV / L1ss-sleep** path, where the AOP keeps the link in L1ss and
   watches CLKREQ# — `WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP` (0x10) exists in the same
   firmware API for exactly this, and is how Qualcomm phones on this SoC do it.
3. Either way, `ath12k` must set the matching `WMI_WOW_ENABLE` flag; today it sends 0 and
   the chip stays silent.
4. Separately: backport the upstream `pci_host_common_d3cold_possible()` / `skip_pwrctrl_off`
   change to the 6.18 stable kernel (or ship 7.2 to stable). On 6.18 the radio is powered
   off in suspend, so WoWLAN cannot even arm; 7.2 already fixes that.

## Navigation

| File | What it holds |
|------|---------------|
| `TECHNICAL.md` | The full evidence chain, step by step, each citing the log that proves it |
| `repro/REPRO.md` | Numbered steps to reproduce the failure on a Frame + a second LAN host |
| `kernel/0001-PCI-qcom-wake.patch` | The host-side patch (current best, v12) — apply on Valve commit `9a8c8ea46950` |
| `kernel/history/` | The full versioned patch series (v3→v12); each version fixed a specific blocker |
| `kernel/BUILD.md` | Podman build recipe, and the deploy / rollback / canary procedure |
| `kernel/deploy-slot.sh`, `rollback.sh`, `kernel-canary.sh` | A/B-slot deploy, rollback, and boot-canary safety net |
| `tests/` | `wake-test.sh` (reproduction), `verify-kernel.sh` (build/deploy check), and how to read them |
| `logs/` | Every hardware test log; `logs/INDEX.md` maps each log to the claim it supports |
| `firmware/` | Placeholder for the firmware reverse-engineering track (ARM32 binary, in progress) |

## Target / provenance

- Device: Steam Frame. SoC: Qualcomm SM8650. Wi-Fi: WCN7850 on `pcie0` (`1c00000.pcie`),
  BDF `0000:01:00.0`, root port `0000:00:00.0`.
- Stock image 0.4.5 (`BUILD_ID 20261022.6150929`) ships kernel `6.18.0-ge66bc2ca6f8c`.
- Beta image 0.5.7 ships the 7.2 kernel; all hardware evidence here was gathered on
  `7.2.0-g9a8c8ea46950` (baseline) and a patched build of that same commit (`7.2.0-wake+`).
- Wi-Fi firmware: `WLAN.IOE_HMT.1.1-00018-QCAHMTSWPL_V1.0_V2.0_SILICONZ-1` (`0x110a0012`,
  2025-08-20), `board_77.bin`.
