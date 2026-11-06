# WCN7850 firmware: the Wake-on-WLAN host-signal decision

Target: `amss.bin` (WCN7850 hw2.0, `WLAN.IOE_HMT.1.1-00018`, build 2025-08-20). ELF32 little-endian, `EM_ARM`, Thumb-2, stripped of section headers. All addresses are virtual addresses in that image.

## Bottom line

The firmware decides how to signal a wake **on the PERST# GPIO level**, and that gate is the whole bug. Its own log strings spell the policy out:

- **PERST# HIGH** (link retained, host not resetting, a normal Linux suspend that keeps the device powered): it does **not** assert WAKE#, it issues an in-band **PME#**.
- **PERST# LOW** (host has asserted reset): it asserts **WAKE#**.

There is no code path that asserts WAKE# for a WoW event while PERST# is HIGH. So on this platform, where the host keeps the link up across suspend and the root-port PME MSI cannot wake the SoC, the firmware's only wake signal in that state (PME#) has nowhere to land, and the one signal that could reach the PDC (WAKE#) is deliberately withheld. This matches the host-side measurements exactly: the chip sets PME_Status when asked, and never toggles WAKE# except as a reaction to PERST# assertion.

## Evidence (the firmware's own developer log text)

Decision function **`pcie_i_assert_wake___RAM`** (name token @ `0x014fb256`). Branch log strings, in logical order:

| vaddr | string | meaning |
|---|---|---|
| `0x014fb21c` | `(%s): PERST GPIO line is HIGH. Not asserting WAKE#, D-state: %d` | PERST# high -> WAKE# suppressed |
| `0x014fb2eb` | `(%s): D3 Hot State, PERST HIGH. Issue PME#` | take the in-band PME# path instead |
| `0x014fb345` | `(%s): PME not enabled in D3 Hot, so cannot send PME!` | unless host never set PME_En |
| `0x014fb316` | `(%s): Endpoint assert WAKE# since PERST is LOW` | the only WAKE# path |
| `0x014fb374` | `(%s): Endpoint assert WAKE#` | WAKE# assertion |

PME# sender **`pcie_core_generate_pme___RAM`** (@ `0x014fb928`): `Device State D0: Skipping PME` (@ `0x014fb90a`); `PM_STTS: ... pme_retry ... send_failure_cnt ... ack_failure_cnt` (@ `0x014fb945`).

Firmware-side PME gate **`pcie_control_pme_in_d3cold`** (@ `0x014fbacf`), log `PME in D3cold feature: %x` (@ `0x014fbab5`), global **`g_pcie_pme_in_d3cold`** (@ `0x014fb468`, in `pcie_reset: %u, g_pcie_pme_in_d3cold: %x`). This is the firmware knob the host's `WMI_WOW_FLAG_SEND_PM_PME` (0x2) toggles, consistent with PME# appearing only when that flag is set.

PERST# input: **`pcie_i_perst_isr___RAM`** (@ `0x014fbb43`), `GPIO PERST# is asserted/deasserted` (@ `0x014fbbdc` / `0x014fbc98`). WAKE# output GPIO is **`pci_e0_wake`** (@ `0x014f5141`; `pci_e1_wake` @ `0x014f55b4`), TLMM base behind `GPIOINT_PHYSICAL_ADDRESS` (@ `0x014f4f12`).

## Relevant existing mechanism: "Fake PERST WAR"

The MHI state machine already has a host-driven wake workaround that fakes a PERST event: `Fake PERST WAR, wakeup received from host` (@ `0x014f9205`), `Fake PERST WAR, Process wakeup from host` (@ `0x014f9b85`). It shows the firmware can already drive the M-state wake path from a synthesized PERST. It is host-initiated, not WoW-initiated, but it is suggestive for how a WoW-triggered WAKE# could be wired.

## What could NOT be pinned, and why (honest limit)

No instruction-level disassembly of these functions, because the image uses Qualcomm's **compressed-logging (QDSS/QSR) token scheme**. Verified three ways, all negative: no 4-byte literal-pool pointer to any of these strings/tokens/GPIO names (`/v4` + raw-byte search); no Thumb-2 `MOVW`/`MOVT` pair building any of those addresses (full scan of all executable segments); radare2 `/r` returns nothing. The code refers to each log site by an opaque ID; the ID->site map normally lives in a companion QDSS string ELF we don't have, which is also why `aaa` recovered only 566 functions. Pinning the exact branch instruction needs that metadata file from Valve/Qualcomm or dynamic tracing on the chip. The policy-level evidence does not depend on it, the log strings are developer descriptions of the actual branches in `pcie_i_assert_wake___RAM`.

## Proposed change (for Qualcomm / Valve)

In **`pcie_i_assert_wake___RAM`**, WAKE# assertion is gated on PERST# == LOW. For Wake-on-WLAN on a platform that keeps the link up across suspend (PERST# stays HIGH) and cannot receive in-band PME# as a system wake, the firmware must assert WAKE# (`pci_e0_wake`) on a WoW match **regardless of PERST# level**, or expose a config/WMI flag selecting WAKE# as the WoW carrier instead of PME#. The existing "Fake PERST WAR" and the `g_pcie_pme_in_d3cold` gate show both the GPIO-drive capability and the flag plumbing already exist; this is a policy/gating change, not new hardware support. Secondary, host-side (already prototyped, REQ-019): ath12k must set `WMI_WOW_FLAG_SEND_PM_PME` (0x2) in `WMI_WOW_ENABLE_CMDID`; mainline sends 0.
