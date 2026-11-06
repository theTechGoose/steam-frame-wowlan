# Technical evidence chain

Every hardware claim below names the log under `logs/` that proves it. The device is the
Steam Frame: SM8650 SoC, WCN7850 on `pcie0` (`1c00000.pcie`), endpoint BDF `0000:01:00.0`,
root port `0000:00:00.0`. Tests were driven by `tests/wake-test.sh`, which arms WoWLAN +
PCI wakeup, suspends the Frame, floods magic packets from a second LAN host, and checks
whether the Frame answers SSH before an RTC safety alarm fires. A test that "did not wake
in 90s; waiting for RTC safety alarm" is a FAIL.

The host-side evidence (steps 1–7) proves the wake has no path to the SoC and points at the
firmware. Step 8 is the firmware root cause itself, recovered by static reverse-engineering
and matching every host measurement: the WCN7850 firmware chooses PME# over WAKE# by the
PERST# pin level, and withholds WAKE# in exactly the Frame's suspend state. Full firmware
notes are in `firmware/` (`firmware/README.md`, `findings-wow-path.md`, `findings-gpio-m3.md`).

The hardware evidence was gathered on the 7.2 kernel. The 6.18 behaviour (step 1) is read
from Valve's published kernel sources; there is no 6.18 hardware log in this set, because the
fix for it is already in 7.2 and all wake testing moved there.

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

Primary proof: `logs/wake-handoff-v12-pme-s2idle-20261105-232758.log` (`7.2.0-wake+`, v12,
`ath12k.wow_flags=2`, link kept in L1ss) — the clean, fully-captured decisive run:

```
ath12k_wifi7_pci 0000:01:00.0: wmi tlv wow enable flags 0x2
qcom-pcie 1c00000.pcie: suspend with WAKE# armed, link kept in L1ss
qcom-pcie 1c00000.pcie: 0000:00:00.0: RTSTA 0x00030100 (PME SET, requester 0100)
qcom-pcie 1c00000.pcie: 0000:01:00.0: PMCSR 0x810b (D3, PME_En 1, PME_Status SET)
qcom-pcie 1c00000.pcie: WAKE# disarmed (level 1)
ath12k_wifi7_pci 0000:01:00.0: wow wakeup host reason 58 WOW_REASON_PAGE_FAULT
```

The endpoint's `PMCSR PME_Status` and the root port's `RTSTA PME` (requester `01:00`) are
both set after the sleep: the chip raised an in-band PM_PME during the sleep. It processed
the WoW event (here `WOW_REASON_PAGE_FAULT`, reason 58). In the equivalent deep run
(`logs/wake-patched-v10-pme-deep-20261105-222502.log`) the firmware reports
`WOW_REASON_RECV_MAGIC_PATTERN` (reason 10) — the magic packet itself, detected. Either way
the signal is in-band PM_PME only.

## 4. The SEND_PM_PME flag — the firmware is silent without it

Citation: Qualcomm public `wmi_unified.h` (wlan-fw-api) documents
`WMI_WOW_FLAG_SEND_PM_PME = 0x2` on `WMI_WOW_ENABLE_CMDID`: "don't send PM_PME after WoW
unless the host uses this flag to request it." Mainline `ath12k` sends `flags = 0`, so the
chip never raises PME.

The v10/v12 patch adds an `ath12k.wow_flags` module param written straight into
`WMI_WOW_ENABLE_CMDID` (`drivers/net/wireless/ath/ath12k/wmi.c`:
`cmd->flags = cpu_to_le32(ath12k_wow_flags)`). The log in step 3 shows `wow enable flags
0x2` and the resulting PME bits. With `wow_flags=0` no PME bit is set. So the in-band PME
exists only with the flag — the first thing any real fix must set. On the firmware side this
flag toggles the global `g_pcie_pme_in_d3cold` (step 8).

## 5. WAKE# is never asserted for a WoW event

Proof:
- `logs/wake-handoff-v12-pme-s2idle-20261105-232758.log` (PRIMARY) — link kept in L1ss,
  WAKE# armed, `wow_flags=2`. WAKE# is high the whole sleep and `WAKE# disarmed (level 1)`
  at resume: it never toggled low, even though the firmware processed the WoW event and
  raised PME. PME and WAKE# are independent; forcing PME does not make the firmware use WAKE#.
- `logs/wake-patched-v2-deep-20261105-193313.log`,
  `logs/wake-patched-v2-control-deep-20261105-194418.log` — link in L2 + PERST#, WAKE#
  armed. The journal shows `WAKE# toggled (level now 0)` / `WAKE# disarmed (level 0)`:
  the chip pulls WAKE# low, but only within ~10 ms of PERST# assertion, with and without
  network traffic (the "control" run sent no magic packets and behaved identically). WAKE#
  here is a reaction to PERST#, not a wake request. (v2 also armed WAKE# too late, in
  `suspend_noirq`, after `suspend_device_irqs()` had masked it — fixed from v4 by arming in
  `suspend_late`. See `kernel/history/`.)
- `logs/wake-patched-v4-deep-20261105-202120.log` — L2 + PERST# with WAKE# armed in
  `suspend_late` aborts the suspend outright (`FAIL: frame never suspended`): the WAKE#
  assertion that follows PERST# is seen as a wakeup event and `echo mem` returns EAGAIN.
- `logs/wake-patched-v4-keeplink-deep-20261105-202838.log`,
  `logs/wake-patched-v9-deep-20261105-220810.log` — link kept in L1ss (no PERST#), WAKE#
  armed, no PME flag. WAKE# stays high the entire sleep and no magic packet wakes it.

Conclusion: in no configuration (L1ss or L2, PME flag or not) does this firmware pull WAKE#
for a WoW event. It only pulls it as a reaction to PERST# assertion. Step 8 shows why, from
the firmware's own code.

## 6. CLKREQ# cannot carry the wake either

Proof: `logs/clkreq-probe-handoff-233235.log` (edge measurement);
`logs/wake-patched-v6-deep-20261105-212710.log` + `logs/wake-patched-v6-postmortem.log`
(the remux-kills-the-link case).

CLKREQ# (tlmm 95, PDC pin 118) is the pin the endpoint must assert to leave L1.2 before it
can send PME, so it was the obvious PDC-wakeable carrier. It is a dead end both ways:

- Leave CLKREQ# on the controller and map its TLMM/PDC IRQ (v9/v12): the link survives, but
  the TLMM sees `CLKREQ# probe: 0 edges in 2000 ms with the IRQ enabled` — both idle and
  under a Wi-Fi ping-flood (`logs/clkreq-probe-handoff-233235.log`). The TLMM only sees the
  pad when it is muxed as GPIO; while the PCIe controller owns it, the TLMM/PDC is blind.
- Mux CLKREQ# away from the controller to a wake GPIO for the sleep (v6): the link cannot
  leave L1.2 (the root complex drives CLKREQ# itself), so it dies inside the same suspend.
  The post-mortem log shows the aftermath: `Unable to change power state from D0 to D3hot,
  device inaccessible`, `ath12k` back in SYS ERROR, and `fail to start mac operations in
  pdev idx 0 ret -11` repeating — Wi-Fi dead until a hand reboot. (This is why
  `tests/wake-test.sh` arms a `wake-test-recover` unit and why deployment uses the boot
  canary.)

So the controller must own the pad, and while it does the TLMM/PDC cannot wake on it.

## 7. The in-band PME MSI cannot wake the SoC — deep or s2idle

Proof: `logs/wake-handoff-v12-pme-s2idle-20261105-232758.log` (PME raised, no wake, woke on
RTC); `logs/clkreq-probe-handoff-233235.log` (`pm_wakeup_irq_after_last_suspend=143`, the
RTC — not the PME MSI); `logs/wake-patched-v10-pme-deep-20261105-222502.log` (deep variant).

The root port's PME interrupt is a GIC ITS MSI (`ITS-PCI-MSI … PCIe PME`).
`enable_irq_wake()` on it fails (`-ENXIO`), so `pcie_pme_suspend()` disables PME signalling
for the sleep. The v12 patch marks the PCI-MSI / MSI-X irq chips `IRQCHIP_SKIP_SET_WAKE`
(as x86 already does) so `pcie_pme_suspend()` keeps the PME interrupt armed
(`drivers/pci/msi/irqdomain.c`). Even so:

- Deep: PME is raised during the sleep but the system never wakes; the RTC alarm ends it.
- s2idle: the GIC/ITS stay powered, so the PME MSI should in principle end the sleep. It
  does not — the endpoint `PME_Status` and root-port `RTSTA PME` are set, but the sleep ends
  on the RTC (`pm_wakeup_irq_after_last_suspend=143`), not on the PME MSI.

The reason is topological: the SM8650 PDC wake controller (`qcom,pdc-ranges` in
`sm8650.dtsi`) covers GPIOs and SPIs 480–573, 609–639, 63, 716–727, 251–255, 244–247.
`pcie0`'s own interrupts are SPIs 140–148 and its MSIs are ITS LPIs — none of them is in the
PDC's range, so none can wake the SoC once the cluster is collapsed, in deep or in s2idle.
The in-band PME physically has no path to the wake hardware.

## 8. Firmware root cause — the fix location

Recovered by static reverse-engineering of the WCN7850 firmware (`amss.bin`, build
`WLAN.IOE_HMT.1.1-00018`); full notes and per-string virtual addresses in `firmware/`.

The firmware decides how to signal a wake in the function its own debug strings call
**`pcie_i_assert_wake`**, and the choice is gated on the **PERST# reset pin level**:

| PERST# | Firmware action | Its own log string |
|---|---|---|
| HIGH (link kept up — the Frame's suspend state) | does **not** assert WAKE#; issues in-band **PME#** | `PERST GPIO line is HIGH. Not asserting WAKE#` / `D3 Hot State, PERST HIGH. Issue PME#` |
| LOW (host asserted reset) | asserts **WAKE#** | `Endpoint assert WAKE# since PERST is LOW` |

This is the whole bug, and it matches every measurement above exactly: in the Frame's
suspend state (link powered, PERST# high) the firmware withholds WAKE# — the only signal
that can reach the PDC (steps 5, 7) — and sends PME#, which on SM8650 reaches nothing
(step 7). The in-band PME# is itself gated by the firmware global `g_pcie_pme_in_d3cold`
(function `pcie_control_pme_in_d3cold`), the knob the host's `WMI_WOW_FLAG_SEND_PM_PME`
(0x2) toggles — which is why the endpoint sets PME_Status only when that flag is set (step 4).

The capability to fix it already ships in the firmware: WAKE# is driven by `pci_e0_wake`
through the chip's internal TLMM (`0x01900000`), and a host-driven wake path that synthesises
a PERST event already exists (`Fake PERST WAR, wakeup received from host`). The fix is a
gating change in `pcie_patch.c`, not new hardware.

Honest limit: the exact branch instruction and a binary patch cannot be produced from
`amss.bin` alone — the PCIe/MHI logic is demand-paged (dlpager) compressed ROM-patch code,
the logging is QSHRINK/QDSS (format strings referenced by numeric ID, confirmed by four
independent search methods), and the image is signed. Qualcomm can locate the site directly
via their QSHRINK database for the quoted strings. `m3.bin` is radio PHY microcode and has no
role in suspend or host wake. See `firmware/README.md`.

---

## What this means, and what unblocks it

The fix is one policy decision in the WCN7850 firmware (step 8): in `pcie_i_assert_wake`,
assert WAKE# (`pci_e0_wake`) on a WoW match regardless of PERST# level — or expose a
config/WMI flag that selects WAKE# as the WoW carrier instead of PME#. The existing
"Fake PERST WAR" and the `g_pcie_pme_in_d3cold` gate show both the GPIO-drive capability and
the flag plumbing already exist.

The host side is already written and tested in `kernel/0001-PCI-qcom-wake.patch`: it
registers `wake-gpios` (tlmm 96) as a wakeup IRQ, armed in `suspend_late` — inert today only
because the firmware never pulls the line. An alternative that needs no WAKE# is the AOP
PCIe DRV / L1ss-sleep path (`WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP = 0x10`, in the same
firmware API; how Qualcomm phones on this SoC do WoWLAN). Either path still requires `ath12k`
to set the matching `WMI_WOW_ENABLE` flag (step 4). Separately, the 6.18 D3cold fix (step 1)
should be backported to stable, or 7.2 shipped to stable.

## Substantiation notes

- **6.18 power-off chain (step 1): source-derived.** No 6.18 hardware log is included;
  testing moved to 7.2, which fixes it. This is the only remaining non-log step, and it is
  honest: the fix for it is already in 7.2.
- **In-band PME + WAKE#-never-asserted (steps 3, 5, 7): closed.** The clean, fully-captured
  run `logs/wake-handoff-v12-pme-s2idle-20261105-232758.log` shows `wow enable flags 0x2`,
  endpoint `PMCSR 0x810b (PME_Status SET)`, root-port `RTSTA 0x00030100 (PME SET)`,
  `WAKE# disarmed (level 1)` (never toggled low), and a wake on the RTC — all in one journal.
- **`WOW_REASON_PAGE_FAULT` (formerly item 4, uncaptured): closed.** The same new log shows
  `wow wakeup host reason 58 WOW_REASON_PAGE_FAULT`.
- **CLKREQ# "0 edges in 2 s" (formerly item 6, uncaptured): closed.**
  `logs/clkreq-probe-handoff-233235.log` shows `CLKREQ# probe: 0 edges in 2000 ms` both idle
  and under a ping-flood, plus `pm_wakeup_irq_after_last_suspend=143` (RTC, not the PME MSI).
- **The MHI RESET failure cascade** once quoted from the issue draft
  (`Resuming from non M3 state (RESET)` / `RESUME(7)` / `timed out while waiting for wow
  wakeup completion` / `failed to wakeup from wow: -110`) does not appear verbatim in any
  saved log. The real, saved equivalent is the v6 CLKREQ#-remux link death in
  `logs/wake-patched-v6-postmortem.log`: `Unable to change power state from D0 to D3hot,
  device inaccessible`, `ath12k … SYS ERROR`, `fail to start mac operations in pdev idx 0
  ret -11`. Step 6 cites those actual lines; the unverifiable block is not used.
- **The `ieee80211_reconfig … util.c:1818` "Hardware became unavailable upon resume"
  warning** is in no saved log and has been dropped entirely.
