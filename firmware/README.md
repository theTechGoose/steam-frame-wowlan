# Firmware: the fix location

The Wake-on-WLAN failure is a single policy decision inside the WCN7850 Wi-Fi
firmware (`amss.bin`, build `WLAN.IOE_HMT.1.1-00018`). It was recovered by two
independent static reverse-engineering passes that converged on the same result;
full notes are in `findings-wow-path.md` and `findings-gpio-m3.md`.

## The decision

The firmware chooses how to signal a wake in the function its own debug strings
call **`pcie_i_assert_wake`**, and the choice is gated on the **PERST# reset pin
level**:

| PERST# state | What the firmware does | Firmware's own log string |
|---|---|---|
| HIGH (link kept up across suspend, the Frame's normal case) | Does **not** assert WAKE#; issues in-band **PME#** instead | `PERST GPIO line is HIGH. Not asserting WAKE#, D-state: %d` / `D3 Hot State, PERST HIGH. Issue PME#` |
| LOW (host has asserted reset) | Asserts **WAKE#** | `Endpoint assert WAKE# since PERST is LOW` |

So in exactly the state a Linux magic-packet suspend produces, link powered,
PERST# high, the firmware withholds WAKE# (the only signal that can reach the
SM8650 PDC wake controller) and sends PME# (which on this SoC reaches nothing;
see `../TECHNICAL.md`). This is the whole bug.

The in-band PME# is itself gated by the firmware global `g_pcie_pme_in_d3cold`
(function `pcie_control_pme_in_d3cold`), which is the knob the host's
`WMI_WOW_FLAG_SEND_PM_PME` (0x2) toggles, matching the measured behaviour that
the endpoint sets PME_Status only when that flag is set
(`../logs/wake-handoff-v12-pme-s2idle-20261105-232758.log`).

## Why this is a small change, not new hardware support

The capability already exists in the shipped firmware:

- The WAKE# GPIO is driven by `pci_e0_wake` through the chip's internal TLMM at
  `0x01900000`.
- A host-driven wake workaround that synthesises a PERST event already exists
  (`Fake PERST WAR, wakeup received from host`), proving the firmware can drive
  the M-state wake path on demand.
- The PME-enable flag plumbing (`g_pcie_pme_in_d3cold`) is already wired to a
  host WMI flag.

## Proposed change (Qualcomm / Valve)

In `pcie_i_assert_wake` (`pcie_patch.c`), assert WAKE# (`pci_e0_wake`) on a WoW
match **regardless of PERST# level**, or expose a config/WMI flag that selects
WAKE# as the WoW carrier instead of PME#. Alternatively, enable the AOP / DRV
PCIe-L1ss-sleep mode (`WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP`, 0x10) so the
always-on processor keeps the link in L1ss and watches CLKREQ#. Either way,
ath12k must also set `WMI_WOW_FLAG_SEND_PM_PME` in `WMI_WOW_ENABLE_CMDID`
(mainline sends 0); the host-side change is in `../kernel/`.

## Honest limits of this analysis

- The exact branch **instruction** and a binary patch cannot be produced from
  `amss.bin` alone: the PCIe/MHI logic is demand-paged (dlpager) compressed
  ROM-patch code, the logging is QSHRINK/QDSS (format strings referenced by
  numeric ID, not by pointer, confirmed by four independent search methods),
  and the image is signed. Qualcomm can jump straight to the site using their
  QSHRINK database for the quoted strings.
- Behaviour is read from the firmware's own developer log strings, which
  describe the branches in `pcie_i_assert_wake`; it is not a disassembled
  instruction trace.
- `m3.bin` is radio PHY microcode (`_binary_phy_ucode_*`), not a power/AOP
  image, it has no role in suspend or host wake.

## Recovered WCN7850 internal register map

Internal TLMM `0x01900000` (drives WAKE#), `SYSPM_SYSPM_REG` `0x01f82000`,
`PMU_WLAN_PMU_TOP` `0x01f88000`, `WLAON_WL_AON_REG` `0x01f80000`,
`PCIE_PCIE_TOP_WRAPPER` `0x01e00000`.

See `findings-wow-path.md` and `findings-gpio-m3.md` for the per-string vaddrs
and the full evidence.
