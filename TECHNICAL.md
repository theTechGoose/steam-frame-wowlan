# Technical evidence chain

Every hardware claim below names the log under `logs/` that proves it. The device is the
Steam Frame: SM8650 SoC, WCN7850 on `pcie0` (`1c00000.pcie`), endpoint BDF `0000:01:00.0`,
root port `0000:00:00.0`. Tests were driven by `tests/wake-test.sh`, which arms WoWLAN +
PCI wakeup, suspends the Frame, floods magic packets from a second LAN host, and checks
whether the Frame answers SSH before an RTC safety alarm fires. A test that "did not wake
in 90s; waiting for RTC safety alarm" is a FAIL.

The hardware evidence here was gathered on the 7.2 kernel. The 6.18 behaviour (step 1) is
read from Valve's published kernel sources; there is no 6.18 hardware log in this set,
because the fix for it is already in 7.2 and all wake testing moved there.

---

## 1. On 6.18 the radio is powered off in suspend, so WoWLAN cannot even arm

Source-derived (no 6.18 log; the stock 0.4.5 image ships `6.18.0-ge66bc2ca6f8c`).

`dw_pcie_suspend_noirq()` asks `pci_host_common_can_enter_d3cold()` whether the port may
power the slot off. That helper allows it when the endpoint is in D3hot and either wakeup
is disabled, or wakeup is enabled and the endpoint *claims* PME from D3cold. WCN7850 claims
exactly that, so the port runs `qcom_pcie_host_deinit()` → `qcom_pcie_perst_assert()` →
`pci_pwrctrl_power_off_devices()` and the `pwrseq_qcom_wcn` sequencer drops the radio's
rails. A chip whose supply is cut cannot assert PME from "D3cold"; the capability bit is
not trustworthy for a pwrctrl-powered endpoint. On resume the port retrains from scratch,
so the firmware never sat in the WoW-armed state.

Upstream fixed this in April 2026 (`1d2a29ccd3a1` "PCI: host-common: Add
`pci_host_common_d3cold_possible()` helper"; `56378c03c1a8` "PCI: dwc: Use common D3cold
eligibility helper in suspend path"), which sets `pp.skip_pwrctrl_off = pme_capable` and
keeps the rails on. Valve's `sm8650-7.2` branch already carries that; 6.18 stable does not.
This is why all wake testing was done on 7.2.

## 2. On 7.2 the radio survives suspend (baseline)

Proof: `logs/wake-baseline-stock72-deep-20261105-190311.log`,
`logs/wake-baseline-stock72-s2idle-20261105-190757.log` (stock `7.2.0-g9a8c8ea46950`).

With Wake-on-WLAN armed, the suspend/resume cycle is clean: the journal shows
`PM: suspend entry` → `qcom-pcie 1c00000.pcie: PCIe Gen.3 x2 link up` → `PM: suspend exit`
with no MHI RESET and no `ath12k` failure. The chip stays in the Qualcomm WoW sleep state
(link L2, PERST# asserted, rails kept via `skip_pwrctrl_off`) and resumes from MHI M3
cleanly. But the magic-packet flood does not wake it — both runs slept until the RTC
safety alarm. `ath12k` on 7.2 only powers the chip down in suspend when Wi-Fi is off
(`ath12k_core_continue_suspend_resume()` needs `ATH12K_HW_STATE_OFF`); with Wi-Fi up the
WoW path (`ath12k_wow_op_suspend` → MHI M3) runs instead. So keeping power is necessary but
not sufficient — the wake signal still has to reach the SoC.

## 3. The firmware detects the magic packet and signals it in-band (PM_PME) — but only when asked

Proof: `logs/wake-patched-v10-pme-deep-20261105-222502.log` (`7.2.0-wake+`, v10,
`ath12k.wow_flags=2`, link kept in L1ss).

After an RTC-timed resume the firmware reports the event it caught during sleep:

```
ath12k_wifi7_pci 0000:01:00.0: wmi tlv wow enable flags 0x2
ath12k_wifi7_pci 0000:01:00.0: wow wakeup host reason 10 WOW_REASON_RECV_MAGIC_PATTERN
qcom-pcie 1c00000.pcie: 0000:00:00.0: RTSTA 0x00030100 (PME SET, requester 0100)
qcom-pcie 1c00000.pcie: 0000:01:00.0: PMCSR 0x810b (D3, PME_En 1, PME_Status SET)
```

The endpoint's `PMCSR PME_Status` and the root port's `RTSTA PME` (requester `01:00`) are
both set after the sleep: the chip did raise an in-band PM_PME during the sleep, and it did
detect the magic packet. This is the one signal the firmware produces.

## 4. The SEND_PM_PME flag — the firmware is silent without it

Citation: Qualcomm public `wmi_unified.h` (wlan-fw-api) documents
`WMI_WOW_FLAG_SEND_PM_PME = 0x2` on `WMI_WOW_ENABLE_CMDID`: "don't send PM_PME after WoW
unless the host uses this flag to request it." Mainline `ath12k` sends `flags = 0`, so the
chip never raises PME.

The v10 patch adds an `ath12k.wow_flags` module param written straight into
`WMI_WOW_ENABLE_CMDID` (`drivers/net/wireless/ath/ath12k/wmi.c`:
`cmd->flags = cpu_to_le32(ath12k_wow_flags)`). The log in step 3 shows `wow enable flags
0x2` and the resulting PME bits. Run the same config with `wow_flags=0` and no PME bit is
set. So the in-band PME exists only with the flag — the first thing any real fix must set.

## 5. WAKE# is never asserted for a WoW event

Proof:
- `logs/wake-patched-v2-deep-20261105-193313.log`,
  `logs/wake-patched-v2-control-deep-20261105-194418.log` — link in L2 + PERST#, WAKE#
  armed. The journal shows `WAKE# toggled (level now 0)` / `WAKE# disarmed (level 0)`:
  the chip pulls WAKE# low, but it does so within ~10 ms of PERST# assertion, with and
  without network traffic (the "control" run sent no magic packets and behaved identically).
  WAKE# here is a reaction to PERST#, not a wake request. (v2 also armed WAKE# too late, in
  `suspend_noirq`, after `suspend_device_irqs()` had masked it — fixed from v4 by arming in
  `suspend_late`. See `kernel/history/`.)
- `logs/wake-patched-v4-deep-20261105-202120.log` — L2 + PERST# with WAKE# armed in
  `suspend_late` aborts the suspend outright (`FAIL: frame never suspended`): the WAKE#
  assertion that follows PERST# is seen as a wakeup event and `echo mem` returns EAGAIN.
- `logs/wake-patched-v4-keeplink-deep-20261105-202838.log`,
  `logs/wake-patched-v9-deep-20261105-220810.log` — link kept in L1ss (no PERST#), WAKE#
  armed. WAKE# stays high the entire sleep (`resume, WAKE# level 1` / `WAKE# disarmed
  (level 1)`), and no magic packet wakes it. The firmware still reports
  `WOW_REASON_RECV_MAGIC_PATTERN` on resume: it caught the packet but signalled only
  in-band, never on WAKE#.
- `logs/wake-patched-v10-pme-deep-20261105-222502.log` — even with `wow_flags=2` forcing
  the PME, WAKE# still stays high (`resume, WAKE# level 1`). PME and WAKE# are independent;
  turning on PME does not make the firmware use WAKE#.

Conclusion: in no configuration (L1ss or L2, PME flag or not) does this firmware pull WAKE#
for a WoW event. It only pulls it as a reaction to PERST#.

## 6. CLKREQ# cannot carry the wake either

Proof: `logs/wake-patched-v6-deep-20261105-212710.log` +
`logs/wake-patched-v6-postmortem.log`; and REQ-019 amendment 5 for the edge-count measurement.

CLKREQ# (tlmm 95, PDC pin 118) is the pin the endpoint must assert to leave L1.2 before it
can send PME, so it was the obvious PDC-wakeable carrier. It is a dead end both ways:

- Mux CLKREQ# away from the controller to a wake GPIO for the sleep (v6): the link cannot
  leave L1.2 (the root complex drives CLKREQ# itself), so it dies inside the same suspend.
  The post-mortem log shows the aftermath: `Unable to change power state from D0 to D3hot,
  device inaccessible`, `ath12k` back in SYS_ERROR, and `fail to start mac operations in
  pdev idx 0 ret -11` repeating — Wi-Fi dead until a hand reboot. (This is why
  `tests/wake-test.sh` arms a `wake-test-recover` unit and why deployment uses the boot
  canary.)
- Leave CLKREQ# on the controller and map its TLMM/PDC IRQ instead (v9/v11): the link
  survives, but the TLMM sees **0 edges in 2 s under a ping flood** while the pad is on the
  PCIe function — the TLMM only sees the pad when it is muxed as GPIO (REQ-019 amendment 5).
  So the controller must own the pad, and while it does the TLMM/PDC is blind to it.

## 7. The in-band PME MSI cannot wake the SoC — deep or s2idle

Proof: `logs/wake-patched-v10-pme-deep-20261105-222502.log` (PME raised, no wake);
`logs/wake-patched-v12-pme-s2idle-20261105-224750.log` (s2idle MSI-wake attempt, no wake).

The root port's PME interrupt is a GIC ITS MSI (`ITS-PCI-MSI … PCIe PME`).
`enable_irq_wake()` on it fails (`-ENXIO`), so `pcie_pme_suspend()` disables PME signalling
for the sleep. The v12 patch marks the PCI-MSI / MSI-X irq chips `IRQCHIP_SKIP_SET_WAKE`
(as x86 already does) so `pcie_pme_suspend()` keeps the PME interrupt armed
(`drivers/pci/msi/irqdomain.c`). Even so:

- Deep (v10): PME is raised during the sleep (step 3) but the system never wakes; the RTC
  alarm ends it.
- s2idle (v12): the GIC/ITS stay powered, so the PME MSI should in principle end the sleep.
  It does not. Per REQ-019 amendment 6, the endpoint `PME_Status` and root-port `RTSTA PME`
  are set again, but PME IRQ 273 did not end the sleep — `pm_wakeup_irq` was the RTC (143).

The reason is topological: the SM8650 PDC wake controller (`qcom,pdc-ranges` in
`sm8650.dtsi`) covers GPIOs and SPIs 480–573, 609–639, 63, 716–727, 251–255, 244–247.
`pcie0`'s own interrupts are SPIs 140–148 and its MSIs are ITS LPIs — none of them is in the
PDC's range, so none can wake the SoC once the cluster is collapsed, in deep or in s2idle.
The in-band PME physically has no path to the wake hardware.

---

## Why this cannot be fixed in the kernel, and what unblocks it

Putting steps 3–7 together: the only host-wake signal this firmware produces is in-band
PM_PME (and only with `WMI_WOW_FLAG_SEND_PM_PME`); it never uses WAKE#; the one pin it must
toggle, CLKREQ#, is invisible to the TLMM/PDC while the PCIe block owns it, and the PCIe
block has to own it; and the in-band PME has no route to the PDC. So no change confined to
Linux can turn a magic packet into an SoC wake.

Two Valve/Qualcomm-side changes each close the gap, and the host side for the first is
already written and tested in `kernel/0001-PCI-qcom-wake.patch`:

1. **Firmware asserts WAKE#** (tlmm 96, PDC pin 119) on a WoW event. The patch registers
   `wake-gpios` as a wakeup IRQ and arms it in `suspend_late`; it is inert today only
   because the firmware never pulls the line.
2. **AOP PCIe DRV / L1ss-sleep**: hand the link to the AOP, which keeps it in L1ss and
   watches CLKREQ#. `WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP = 0x10` exists in the same
   firmware API for exactly this; it is how Qualcomm phones on this SoC do WoWLAN.

Either path still requires `ath12k` to set the matching `WMI_WOW_ENABLE` flag (step 4).

## Substantiation notes (claims not fully backed by a log in this set)

- The 6.18 power-off chain (step 1) is read from published kernel sources; no 6.18 hardware
  log is included (testing moved to 7.2, which fixes it).
- The MHI RESET failure cascade and the s2idle `ieee80211_reconfig` "Hardware became
  unavailable upon resume" warning quoted in the GitHub issue draft do **not** appear
  verbatim in any log here. The only matching line captured is `fail to start mac
  operations in pdev idx 0 ret -11`, and only in `logs/wake-patched-v6-postmortem.log` (the
  CLKREQ#-remux link-death case, not a stock 6.18 power-off). Treat those quoted blocks as
  reconstructed from the original 0.4.5 repro, not as logs in this handoff.
- The v11 `WOW_REASON_PAGE_FAULT` result (L2 + PERST# deasserted + `wow_flags=2`) and the
  v12 `pm_wakeup_irq 143` / "PME IRQ 273 did not end the sleep" detail are asserted in
  REQ-019 amendments 5–6, but the corresponding log files
  (`logs/wake-patched-v11-l2-pme-deep-20261105-223913.log`,
  `logs/wake-patched-v12-pme-s2idle-20261105-224750.log`) did not capture those journal
  lines — their captured journal tail is WCN7850 channel-scan output. The in-band/WAKE#
  conclusions above rest on the v10 deep log, which did capture the PME and WAKE# state.
- The CLKREQ# "0 edges in 2 s" measurement (step 6) is from REQ-019 amendment 5; it was
  taken interactively via the v11 `clkreq_probe` knob and is not saved as a line in any
  wake log.
