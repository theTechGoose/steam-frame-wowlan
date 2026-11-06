# Firmware track (in progress)

The host-side analysis in `../TECHNICAL.md` proves the wake is blocked on the WCN7850
firmware: the firmware detects the magic packet but signals it only in-band (PM_PME, and
only with `WMI_WOW_FLAG_SEND_PM_PME`), and never asserts the WAKE# sideband. The fix
therefore lives in firmware (or AOP) behaviour, not in Linux.

Reverse-engineering of the WCN7850 WLAN firmware is being done in a separate track. The
binary is ARM32; analysis is in progress. Findings will be added to this directory.

Firmware under test (for reference):
`WLAN.IOE_HMT.1.1-00018-QCAHMTSWPL_V1.0_V2.0_SILICONZ-1` (`0x110a0012`, 2025-08-20),
board file `board_77.bin`.

## Fix location (firmware)

_To be filled in._ This section will identify where in the firmware the WoW-event handler
decides how to signal the host, and what would make it assert WAKE# (tlmm 96) — or enter
the AOP PCIe DRV / L1ss-sleep path (`WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP = 0x10`) — for a
detected magic packet, instead of only raising an in-band PM_PME.
