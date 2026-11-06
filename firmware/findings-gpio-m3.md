# Firmware RE findings: GPIO/WAKE# path + M3 image (WCN7850, Steam Frame)

Scope of this note: (A) GPIO/TLMM and "force wake" machinery in `amss.bin`, and whether the
firmware can drive the host WAKE# line; (B) characterization of `m3.bin`. All addresses are
virtual (vaddr) in `amss.bin` unless noted. Evidence is cited inline; limits are called out.

## TL;DR
- **`m3.bin` is radio PHY microcode, not a power processor.** It does not touch PCIe/suspend/wake. Irrelevant to WoWLAN.
- **The firmware's WAKE# policy is explicit in its own log strings:** it asserts WAKE# to the host **only while PERST# is LOW**, and when PERST# is HIGH (link kept up, the Frame's case) it **issues in-band PME# instead and explicitly does not assert WAKE#.** This matches every host-side measurement exactly.
- The decision code lives in `pcie_patch.c`, which is **ROM-patch / demand-paged (dlpager) code, not present as plaintext ARM in this file**, so the exact instruction/flag cannot be extracted by static RE of `amss.bin` alone. Qualcomm, who hold the ROM, the dlpager compressor, and the QSHRINK log database, can.
- I recovered the **internal register map** of the WCN7850 (TLMM/GPIO, PMU, SYSPM, AON, PCIe wrapper bases), which pins where WAKE# is driven from.

## (B) m3.bin, PHY microcode, not the power/AOP processor
`rabin2 -s m3.bin` shows the whole file is two linker blobs wrapped in an ELF:
`_binary_phy_ucode_per_phy_bin_start/_end/_size` (section `.per_phy`, 0x20000) and
`_binary_phy_ucode_shared_bin_*` (section `.shared`, 0x28000). No code symbols, no strings
(`rabin2 -z` empty). The `e_machine = EM_386` is a packaging placeholder; the payload is radio
PHY ucode, not an executable we can trace. **Conclusion: m3.bin governs the baseband/PHY, not
PCIe L1ss or host wake. The brief's assumption that m3 is the power-management image is wrong, 
all PCIe/PMU/suspend logic is in `amss.bin` (and the ROM it patches).**

## amss.bin shape, why string→code pivots fail
- ELF32 EM_ARM, stripped of sections; 26 PT_LOAD segments. Plaintext code segments (entropy
  ~6.2-6.9): vaddr 0x1362000, 0x1418000, 0x146e000, 0x14b1000, 0x1795000, 0x1792000(2.4MB).
  rodata/strings at 0x14d2000 (seg 14, entropy 5.75). **Segment 25 @0x1670000 (0xdf040, entropy
  7.77) is the compressed dlpager swap store.**
- The image is a **dlpager (demand-paged) build**: `dlpager.c`, `dlpager_prefetch.c`,
  `dlpager_main.c`, `swap_ops.c`, `sram_mgr.c`. Most operational code is compressed and only
  decompressed into SRAM at runtime; it is not plaintext ARM in the file.
- Of 41 referenced `*.c` names, the PCIe/PMU ones are **patch** modules: `pcie_patch.c`,
  `pmu_driver_patch.c`, `mhi_patch.c`. These patch on-chip **ROM**, the base logic is in ROM,
  not in this image.
- Logging uses **QSHRINK/QDSS**: format strings are present in rodata but referenced by numeric
  message ID, **not by pointer**. Verified: raw LE32 searches for the vaddr of every target
  string (`tlmm_total_gpio`, `WHAL_SR_INT_FORCE_WAKE_ASSERT`, `D3 Hot State… Issue PME#`,
  `Endpoint assert WAKE#…`, `PERST GPIO line is HIGH. Not asserting WAKE#`, `g_couple_perst_in_rddm`,
  `l1ss_sleep…`) return **0 references**, and r2 `aae` emulation finds no xrefs. Their `__func__`
  strings are likewise unreferenced. So the functions that print them are in ROM or in paged code,
  not in the plaintext we can disassemble. This is the hard ceiling for external static RE.

## (A) The WAKE# decision, recovered from the firmware's own strings (rodata seg 14)
These format strings are present verbatim and describe the exact policy (grep `strings -n 6 amss.bin`):

- `(%s): D3 Hot State, PERST HIGH. Issue PME#`                               (vaddr 0x14fb2eb)
- `(%s): Endpoint assert WAKE# since PERST is LOW`                           (vaddr 0x14fb316)
- `(%s): PERST GPIO line is HIGH. Not asserting WAKE#, D-state: %d`          (vaddr 0x14fb21c)
- `(%s): GPIO PERST# is asserted` / `… is deasserted`
- `(%s): Enable Fake PERST Fix : %x` / `Enable Fake PERST WAR : %x`
- `(%s): L23_READY set in PERST# ISR for fake PERST# WAR`
- `(%s): PCIE perst coupling from wlan, enable_val : %d reg_val : %d`
- `(%s): WLAN_EN = %d, g_couple_perst_in_rddm = %d`
- `(%s): D3hot sleep inactivity timer enabled` ; `(%s): counters: l1:%u l1ss:%u l2:%u` ; `l1ss_sleep entry failed`
- MHI: `mhi_sm_set_mhiState: DLpager failed to suspend on M3 entry`, `Could not enter sleep mode:LPM`,
  `device_wake db is pending`, `link inactivity intr fired but device_wake asserted`

**Reading:** the WCN7850 ties its host-WAKE# assertion to the PERST# line state. In D3hot with the
link kept up (PERST# HIGH), it takes the PME# branch and logs that it is *not* asserting WAKE#.
It only drives WAKE# when it sees PERST# LOW. There is a configurable "PERST coupling" / "fake
PERST WAR" (`g_couple_perst_in_rddm`, `Enable Fake PERST WAR`) around this, which is the knob most
likely relevant to changing the behavior, but its code is in the paged/ROM `pcie_patch.c`.

Note `device_wake` here is the **MHI inbound** doorbell (host→device wake), not the WAKE# sideband
(device→host); don't conflate them.

## Internal register map (recovered from the firmware's register-block base table @0x1528614, stride 20B: name, base, size, remap)
WAKE# is a GPIO driven through the WCN7850's **own internal TLMM**, not the host SoC's TLMM:

| block | base | size | note |
|---|---|---|---|
| TLMM | 0x01900000 | 0x200000 | internal GPIO controller, drives the package WAKE# ball |
| WL_TLMM | 0x01bc0000 | 0x20000 | WLAN GPIO |
| PCIE_PCIE_TOP_WRAPPER | 0x01e00000 | 0x20000 | PCIe EP core |
| WLAON_WL_AON_REG | 0x01f80000 | 0x7c8 | always-on domain |
| SYSPM_SYSPM_REG | 0x01f82000 | 0x1000 | system power mgmt / sleep |
| PMU_WLAN_PMU_TOP | 0x01f88000 | 0x344 | WLAN PMU |
| PMU_NOC | 0x01f8a000 | 0x80 | |
| GCC_GCC | 0x01e40000 |, | clocks (gcc_pcie_{ahb,apb,axi,slp}_clk) |

(The `0xE2xxxxxx/0xE3xxxxxx` 4th column is each block's second AHB window.) The `tlmm_total_gpio`
and `wal_pm_gpio_pwr_profile` routines operate on the 0x01900000 TLMM; the specific GPIO index
wired to WAKE# is not labeled in plaintext.

## What this means for the handoff
- The fix is **not** host-side and **not** extractable as a binary patch from `amss.bin`: the
  WAKE#-vs-PME# decision is ROM/paged `pcie_patch.c` code, and the image is signed, so a modified
  image won't boot. This confirms the kernel-only dead end from a second, independent angle.
- The precise, actionable ask for Valve/Qualcomm: **make the firmware assert WAKE# (internal TLMM
  @0x01900000) on a WoW wake event even when PERST# is HIGH**, i.e. change the PERST-coupled WAKE#
  gating (`g_couple_perst_in_rddm` / "Enable Fake PERST WAR" path in `pcie_patch.c`), or enable the
  AOP/DRV L1SS-sleep mode. Qualcomm can locate the exact site instantly via the QSHRINK message DB
  for the strings quoted above.

## Limits / unverified
- No disassembly of the decision function (ROM/paged; not in plaintext). Behavior inferred from
  verbatim log strings, which is strong but not an instruction-level trace.
- Exact WAKE# GPIO index within TLMM not identified (would need the paged `pcie_patch.c` or a
  Qualcomm pinmap).
- `WHAL_SR_INT_FORCE_WAKE_ASSERT` ("SR" subsystem force-wake) could not be xref'd (QSHRINK);
  it appears to be an internal subsystem wake, not the host WAKE# line.
