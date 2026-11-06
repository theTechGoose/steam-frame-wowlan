# Ticket text for Qualcomm

Paste-ready. Everything here is measured on hardware or read from the firmware's own
log strings; the journals are in `../logs/`.

---

Subject: WCN7850 WLAN.IOE_HMT.1.1-00018: Wake-on-WLAN never asserts WAKE# while
PERST# is high, so hosts that keep the link powered across suspend cannot wake

Platform: Qualcomm SM8650 (Steam Frame), WCN7850 on PCIe (`17cb:1107`), Linux
`ath12k_pci`. Firmware `WLAN.IOE_HMT.1.1-00018-QCAHMTSWPL_V1.0_V2.0_SILICONZ-1`
(`0x110a0012`, 2025-08-20), `board_77.bin`.

Symptom: with WoW magic-pattern armed and the host in system suspend with the link
kept powered (endpoint in D3hot, link in L1ss, PERST# deasserted), a magic packet does
not wake the host. On the next resume the firmware reports the packet was caught
(`WOW_REASON_RECV_MAGIC_PATTERN`). With `WMI_WOW_FLAG_SEND_PM_PME` set in
`WMI_WOW_ENABLE_CMDID`, the endpoint's `PMCSR PME_Status` and the root port's `RTSTA
PME` are set after the sleep, so the device did raise in-band PME#. The WAKE# sideband
(host GPIO tlmm 96, PDC-wakeable) never toggles for the event. On SM8650 the root
port's PME interrupt is a GIC ITS MSI that the PDC cannot see, so in-band PME# cannot
end the sleep. WAKE# is the only signal that can.

Where the behaviour comes from: in `pcie_i_assert_wake` (`pcie_patch.c`) the wake
signal is selected by PERST# level. The function's own log strings:

```
(%s): PERST GPIO line is HIGH. Not asserting WAKE#, D-state: %d
(%s): D3 Hot State, PERST HIGH. Issue PME#
(%s): PME not enabled in D3 Hot, so cannot send PME!
(%s): Endpoint assert WAKE# since PERST is LOW
```

There is no path that asserts WAKE# for a WoW event while PERST# is high. The in-band
PME# path is gated by `g_pcie_pme_in_d3cold` (`pcie_control_pme_in_d3cold`), which is
what `WMI_WOW_FLAG_SEND_PM_PME` toggles.

Request: on a WoW match, assert WAKE# (`pci_e0_wake`) regardless of PERST# level, or
expose a WMI flag that selects WAKE# as the WoW carrier instead of PME#. The GPIO drive
and the flag plumbing already exist in this image (the "Fake PERST WAR" host-wake path
drives the same mechanism). An alternative that needs no WAKE# is the AOP PCIe DRV /
L1ss-sleep mode (`WMI_WOW_FLAG_ENABLE_DRV_PCIE_L1SS_SLEEP`, 0x10).

Notes for locating the site: the quoted strings are QSHRINK log sites, so your
string database maps them directly to the branches in `pcie_i_assert_wake`. We could
not pin the instruction externally (demand-paged ROM-patch code, ID-based logging,
signed image), and we do not need to; the policy is unambiguous from the strings.

We can run any candidate firmware on the hardware and return the full host journal for
deep and s2idle within a day.
