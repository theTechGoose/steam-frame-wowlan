# Steam Frame Wake-on-WLAN: why it fails, and where the fix is

The Steam Frame does not wake from suspend when it receives a Wake-on-WLAN magic
packet, and no Linux-only change can make it. The Wi-Fi firmware (Qualcomm WCN7850,
`amss.bin` build `WLAN.IOE_HMT.1.1-00018`) detects the packet but signals it with an
in-band PME# that nothing on the SM8650 can turn into a system wake. The one signal
that could, the WAKE# line on tlmm 96, is withheld by a single policy check in the
firmware: it asserts WAKE# only while PERST# is low, and during a Linux suspend
PERST# stays high. Fixing it is a gating change in one firmware function. The
host-side kernel change is written and hardware tested here, and it becomes live the
moment the firmware asserts WAKE#.

Every claim below cites a saved journal in `logs/` (mapped in `logs/INDEX.md`). The
single exception is the 6.18 power-off behaviour, which is read from the published
kernel sources and marked as such.

## Reproduce it in two minutes

Tested on the 0.5.7 beta image, kernel `7.2.0-g9a8c8ea46950` (Valve commit
`9a8c8ea46950`). You need Developer Mode with SSH and a second machine on the same
LAN.

On the Frame:

```
nmcli con modify <ssid> 802-11-wireless.wake-on-wlan magic && nmcli con up <ssid>
iw phy phy0 wowlan show                      # must list "wake up on magic packet"
echo enabled > /sys/bus/pci/devices/0000:01:00.0/power/wakeup
echo enabled > /sys/bus/pci/devices/0000:00:00.0/power/wakeup
systemctl suspend                            # default deep; s2idle: echo s2idle > /sys/power/mem_sleep first
```

From the second machine, send magic packets to the Frame's Wi-Fi MAC (broadcast and
unicast, UDP ports 9 and 7) for a minute. The headset stays asleep. Wake it with the
power button and read `journalctl -k -b`.

Scripted version, from any host that reaches the Frame as the ssh alias `frame`:

```
FRAME_SUDO_PW=... sh tests/wake-test.sh deep     # or s2idle
```

Exit 0 means a magic packet woke it. Every run in `logs/` exits 1. That exit code is
the acceptance test for any fix.

## What the evidence shows

| # | Claim | Log | What it records |
|---|-------|-----|-----------------|
| 1 | On 7.2 the radio survives suspend with WoWLAN armed: clean MHI M3 entry and resume, no reset | `wake-baseline-stock72-deep-20261105-190311.log` | no wake, clean resume |
| 2 | The firmware sees the magic packet during the sleep | `wake-patched-v10-pme-deep-20261105-222502.log` | `WOW_REASON_RECV_MAGIC_PATTERN` (reason 10) reported on resume |
| 3 | It signals in-band PME#, and only when ath12k sets `WMI_WOW_FLAG_SEND_PM_PME` (0x2); mainline sends 0 | `wake-handoff-v12-pme-s2idle-20261105-232758.log` | `wow enable flags 0x2`, endpoint `PMCSR 0x810b (PME_Status SET)`, root port `RTSTA 0x00030100 (PME SET)` |
| 4 | WAKE# (tlmm 96) is never asserted for the event | same log; `wake-patched-v2-control-deep-20261105-194418.log` | `WAKE# disarmed (level 1)`; the control run with no packets still shows WAKE# low after PERST#, so the toggle is a PERST# reaction |
| 5 | CLKREQ# (tlmm 95) cannot carry the wake: no TLMM edges while PCIe owns the pad, and muxing it to GPIO kills the link | `clkreq-probe-handoff-233235.log`; `wake-patched-v6-postmortem.log` | `CLKREQ# probe: 0 edges in 2000 ms` under a ping flood; `Unable to change power state from D0 to D3hot`, `SYS ERROR`, Wi-Fi dead until reboot |
| 6 | The PME MSI cannot end the sleep, deep or s2idle | `clkreq-probe-handoff-233235.log` | `pm_wakeup_irq_after_last_suspend=143` (the RTC, not the PME MSI) |

The full chain, one step per claim with the exact lines, is in `TECHNICAL.md`.

## Root cause

There are two halves, and both have to hold for the bug to exist.

On the SoC, the root port's PME interrupt is a GIC ITS MSI. No PCIe interrupt on
sm8650 is routed through the PDC wake controller, so once the CPU cluster collapses
an in-band PME has nowhere to land. `enable_irq_wake()` on it fails. Marking the
PCI-MSI irq chip `IRQCHIP_SKIP_SET_WAKE` keeps it armed, and the sleep still ends on
the RTC rather than the MSI, even in s2idle.

In the firmware, the function its own debug strings call `pcie_i_assert_wake` picks
the wake signal by PERST# level. Its log strings, verbatim:

```
(%s): PERST GPIO line is HIGH. Not asserting WAKE#, D-state: %d
(%s): D3 Hot State, PERST HIGH. Issue PME#
(%s): Endpoint assert WAKE# since PERST is LOW
```

There is no path that asserts WAKE# for a WoW event while PERST# is high, and
PERST# high with the link powered is exactly the Frame's suspend state. So the
firmware sends the signal the SoC cannot receive and withholds the one it could. The
PME# path is itself gated by the firmware global `g_pcie_pme_in_d3cold`, which is
what the 0x2 WMI flag toggles, matching claim 3. Addresses, the register map, and the
two independent passes that reached this are in `firmware/README.md`.

## What Valve can do now, and what needs Qualcomm

Valve, in the kernel, today:

1. Set `WMI_WOW_FLAG_SEND_PM_PME` in `ath12k_wmi_wow_enable()`. One line; mainline
   sends 0. Measured effect: the chip raises PME during the sleep. Not a wake on its
   own, but it is the host half of any firmware fix and it is testable now.
2. Register pcie0's existing `wake-gpios` (tlmm 96) as a wakeup IRQ in `pcie-qcom`.
   `kernel/0001-PCI-qcom-wake.patch` does this against commit `9a8c8ea46950`, built
   and run on the device. It is inert today only because the firmware never pulls the
   line.
3. Backport the upstream `pci_host_common_d3cold_possible()` / `skip_pwrctrl_off`
   change to the 6.18 stable kernel, or ship 7.2 to stable. On 6.18 the radio is
   powered off in suspend, so WoWLAN cannot even arm. 7.2 already has this.
4. Until a fix lands, make NetworkManager's `wake-on-wlan` a no-op or report it as
   unsupported, so users do not enable a setting that cannot work.

Qualcomm, through Valve, in the firmware:

1. In `pcie_i_assert_wake` (`pcie_patch.c`), assert WAKE# (`pci_e0_wake`) on a WoW
   match regardless of PERST# level, or add a WMI flag that selects WAKE# as the WoW
   carrier instead of PME#. The GPIO drive and the flag plumbing already exist in the
   shipped image; the firmware's own "Fake PERST WAR" path drives the same wake
   mechanism on demand.
2. Alternative that needs no WAKE#: the AOP PCIe DRV / L1ss-sleep path
   (`WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP`, 0x10), where the always-on processor
   keeps the link in L1ss and watches CLKREQ#. This is how Qualcomm phones on the same
   SoC do it.

A ticket you can paste to Qualcomm as-is is in `firmware/QUALCOMM.md`.

## What I ruled out, so you do not have to

Twelve kernel iterations, each closing one door. The patches are in `kernel/history/`
and every run is mapped in `logs/INDEX.md`.

- Keeping the link in L1ss with WAKE# armed (v1, and v4 with `keep_link`): WAKE#
  stays high through the whole sleep.
- L2 with PERST# asserted (v2): WAKE# does go low, but a control run with no magic
  packets shows the same, so it is a reaction to PERST#, not a wake. Arming it in
  `suspend_late` then aborts the suspend with EAGAIN (v4).
- L2 with PERST# left deasserted (v5, and v11 with `skip_perst`): WAKE# unused. With
  the PME flag set the firmware reports `WOW_REASON_PAGE_FAULT` instead of the magic
  pattern.
- Muxing CLKREQ# to a GPIO wake IRQ for the sleep (v6): the root complex drives
  CLKREQ# itself to leave L1.2, so the link dies inside the suspend and Wi-Fi is dead
  until reboot. Do not remux that pad while the link is up.
- CLKREQ# IRQ with the pad left on the PCIe function (v7 to v9): mapped at probe (v7
  leaked the IRQ across pcie0's deferred probes, v8 fixed that with `devm`), then
  armed in `suspend_noirq` with `IRQF_NO_SUSPEND` so the host's own D3hot config
  writes stop aborting the suspend (v9). It suspends cleanly and sees zero edges.
- The PME flag alone (v10): `PME_Status` and `RTSTA PME` set, no wake.
- PME MSI kept armed with `IRQCHIP_SKIP_SET_WAKE` in s2idle (v12): the sleep ends on
  the RTC, not the MSI.

## I can test any fix

I have a Frame on a custom-kernel A/B slot with a boot canary and rollback, the
scripted test above, and a saved baseline for every configuration in this repo. Send
a firmware image or an `ath12k` / `pcie-qcom` change and I will run deep and s2idle
and return the full journal within a day.

## Limits of this analysis

- The exact branch instruction in `pcie_i_assert_wake` cannot be produced from
  `amss.bin` externally. The PCIe/MHI code is demand-paged compressed ROM-patch, the
  logging is QSHRINK (format strings referenced by numeric ID, not by pointer, confirmed
  by four independent searches), and the image is signed. The policy is read from the
  firmware's own log strings for that function. Qualcomm can jump straight to the
  site with their QSHRINK database for the quoted strings.
- The 6.18 power-off step comes from the published sources, not a 6.18 journal.
  Testing moved to 7.2, where it is already fixed.
- `m3.bin` is radio PHY microcode and plays no part in suspend or wake.

## Layout

| Path | Contents |
|------|----------|
| `TECHNICAL.md` | The evidence chain, one step per claim, each citing its log |
| `repro/REPRO.md` | The reproduction, with what the journal shows on 6.18 and on 7.2 |
| `kernel/0001-PCI-qcom-wake.patch` | The host-side patch (v12), applies on Valve commit `9a8c8ea46950` |
| `kernel/history/` | Every version from v3 to v12 |
| `kernel/BUILD.md`, `deploy-slot.sh`, `rollback.sh`, `kernel-canary.sh` | Build recipe and the A/B deploy, rollback, and boot-canary safety net |
| `tests/` | `wake-test.sh` (the acceptance test) and `verify-kernel.sh` |
| `logs/` | Every hardware run, sanitized; `INDEX.md` maps each to the claim it supports |
| `firmware/README.md` | The fix location in the firmware |
| `firmware/QUALCOMM.md` | Paste-ready ticket text for Qualcomm |
| `firmware/findings-*.md`, `vaddrs.txt`, `amss.functions.txt` | The reverse-engineering notes behind it |

## Target

- Device: Steam Frame. SoC: Qualcomm SM8650. Wi-Fi: WCN7850 on `pcie0`
  (`1c00000.pcie`), BDF `0000:01:00.0`, root port `0000:00:00.0`, PCI id `17cb:1107`,
  driver `ath12k_pci`.
- Stock image 0.4.5 (`BUILD_ID 20261022.6150929`) ships kernel `6.18.0-ge66bc2ca6f8c`.
- Beta image 0.5.7 ships the 7.2 kernel. All hardware evidence here was gathered on
  `7.2.0-g9a8c8ea46950` and on a patched build of that same commit (`7.2.0-wake+`).
- Wi-Fi firmware: `WLAN.IOE_HMT.1.1-00018-QCAHMTSWPL_V1.0_V2.0_SILICONZ-1`
  (`0x110a0012`, 2025-08-20), `board_77.bin`.
