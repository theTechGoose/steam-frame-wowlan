# Log index

Each log is one run of `tests/wake-test.sh <mode> <label>`. The header line records the
kernel, mode (`deep` = PSCI system suspend; `s2idle`), the Wi-Fi MAC/IP, and the broadcast
address the magic packets were sent to. 

> Sanitized for publication: device hardware serial numbers removed (shown as `REDACTED`); the
> Wi-Fi MAC `de:ad:be:ef:00:0x` and the `192.0.2.0/24` (TEST-NET-1) addresses are placeholders
> for the real unit MAC and the private LAN they were captured on.
"did not wake in 90s; waiting for RTC safety alarm"
means the magic-packet flood failed and only the RTC alarm brought it back = FAIL. "FAIL:
frame never suspended" means the suspend itself was aborted (a wakeup event fired before it
went down). Kernels: `7.2.0-g9a8c8ea46950` = stock Valve 7.2; `7.2.0-wake-ga48d72f178d1` =
first patched build; `7.2.0-wake+` = v2 onward.

| Log | Config | Result | Claim it supports (see TECHNICAL.md) |
|-----|--------|--------|--------------------------------------|
| `wake-baseline-stock72-deep-20261105-190008/190057/190150.log` | stock 7.2, deep | short/partial captures | early baseline runs (setup) |
| `wake-baseline-stock72-deep-20261105-190311.log` | stock 7.2, deep | no wake, clean resume | §2 radio survives suspend on 7.2; keep-power alone does not wake |
| `wake-baseline-stock72-s2idle-20261105-190757.log` | stock 7.2, s2idle | no wake, clean resume | §2 same, s2idle |
| `wake-patched-deep-20261105-192149.log` | v1 patched, L1ss, WAKE# armed, deep | no wake, WAKE# high | §5 first L1ss build; WAKE# stays high |
| `wake-patched-s2idle-20261105-191544.log` | v1 patched, L1ss, s2idle | no wake, WAKE# high | §5 same, s2idle |
| `wake-patched-v2-deep-20261105-193313.log` | v2, L2 + PERST#, WAKE# armed in noirq, deep | no wake, `WAKE# level 0` | §5 WAKE# pulled low only as a reaction to PERST# |
| `wake-patched-v2-s2idle-20261105-193832.log` | v2, L2 + PERST#, s2idle | no wake, `WAKE# level 0` | §5 same, s2idle |
| `wake-patched-v2-control-deep-20261105-194418.log` | v2, L2 + PERST#, **no magic packets** | WAKE# still goes low | §5 WAKE# toggle is independent of network traffic |
| `wake-patched-v4-deep-20261105-202120/202409.log` | v4, L2 + PERST#, WAKE# armed in suspend_late | `frame never suspended` | §5 WAKE#-after-PERST# aborts the suspend (EAGAIN) |
| `wake-patched-v4-keeplink-deep-20261105-202838.log` | v4, L1ss kept, deep | no wake, `WAKE# level 1` | §5 L1ss: WAKE# stays high, no wake |
| `wake-patched-v5-deep-20261105-203541.log` | v5, L2, PERST# deasserted (`skip_perst`) | no wake | §5 PERST#-deasserted variant; WAKE# unused |
| `wake-patched-v5-dbg-deep-20261105-204020.log` | v5 + debug, deep | no wake | §5 supporting debug run |
| `wake-patched-v5-wmidbg-deep-20261105-204455.log` | v5 + WMI debug, deep | no wake | §5 WMI debug (firmware WOW reason) |
| `wake-patched-v6-deep-20261105-212710.log` | v6, CLKREQ# muxed to GPIO wake IRQ | no wake, went off network | §6 CLKREQ# remux attempt |
| `wake-patched-v6-postmortem.log` | v6 aftermath, boot journal | link died in suspend; Wi-Fi dead | §6 muxing CLKREQ# away kills the link (`D0→D3hot inaccessible`, SYS_ERROR, `fail to start mac operations`) |
| `wake-patched-v8-deep-20261105-220109.log` | v8, CLKREQ# IRQ mapped at probe | `frame never suspended` | §6 stale latched CLKREQ# edge aborts suspend (→ v9) |
| `wake-patched-v9-deep-20261105-220810.log` | v9, L1ss, CLKREQ# IRQ armed in suspend_noirq | no wake, CLKREQ# count 0 | §6 CLKREQ# on the PCIe function produces no TLMM edges |
| `wake-patched-v9-s2idle-20261105-221332.log` | v9, L1ss, s2idle | no wake | §6 same, s2idle |
| `wake-patched-v10-pme-deep-20261105-222422.log` | v10, deep (first try) | `frame never suspended` | aborted setup run |
| `wake-patched-v10-pme-deep-20261105-222502.log` | v10, `wow_flags=2`, L1ss, deep | no wake; **PME raised** | §3 firmware detects magic packet (`WOW_REASON_RECV_MAGIC_PATTERN`, reason 10); PME raised; WAKE# high |
| `wake-patched-v10-pme-s2idle-20261105-222945.log` | v10, `wow_flags=2`, L1ss, s2idle | no wake | §7 same config, s2idle (PME lines not captured, superseded by the handoff run) |
| `wake-patched-v11-l2-pme-deep-20261105-223913.log` | v11, L2 + PERST# deasserted, `wow_flags=2` | no wake | §5 L2 variant (PME lines not captured, superseded by the handoff run) |
| `wake-patched-v12-pme-s2idle-20261105-224750.log` | v12, `IRQCHIP_SKIP_SET_WAKE`, `wow_flags=2`, L1ss, s2idle | no wake; RTC ended it | §7 first s2idle MSI-wake attempt (PME lines not captured, superseded by the handoff run) |
| `wake-handoff-v12-pme-s2idle-20261105-232758.log` | v12, `wow_flags=2`, L1ss, s2idle | no wake; RTC ended it | **§3/§4/§5/§7 PRIMARY**, clean capture: `wow enable flags 0x2`, endpoint `PMCSR 0x810b (PME_Status SET)`, root-port `RTSTA 0x00030100 (PME SET)`, `WAKE# disarmed (level 1)` (never low), `WOW_REASON_PAGE_FAULT` (reason 58), woke on RTC |
| `wake-handoff-v12-pme-s2idle-20261105-232758.full.log` |, |, | Full unfiltered journal for the run above (nothing elided) |
| `clkreq-probe-handoff-233235.log` | v12, CLKREQ# edge probe + wake-IRQ counts |, | §6/§7 `CLKREQ# probe: 0 edges in 2000 ms` idle and under ping-flood; `pm_wakeup_irq_after_last_suspend=143` (RTC, not the PME MSI); `_clkreq_wake` IRQ count 0 |

The decisive run is `wake-handoff-v12-pme-s2idle-20261105-232758.log` (full journal in the
`.full.log` twin): one clean capture of `wow enable flags 0x2` → endpoint/root-port PME set →
`WAKE# disarmed (level 1)` (WAKE# never toggled low) → wake on the RTC. It is the primary
citation for §3, §5/§7, with `clkreq-probe-handoff-233235.log` for the CLKREQ# edge count and
the RTC-not-PME wake source. The earlier v10/v11/v12 runs reached the same states but their
`wake-test.sh` journal window was overrun by post-resume channel-scan output (`WMI chan scan
list …`, which matches `pci`); the handoff runs captured the full journal and supersede them.
