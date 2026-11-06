# Tests

Both scripts run on a Mac (or any host) that can reach the Frame over SSH as the host
alias `frame` (key-based login). Commands that need root on the Frame read the sudo
password from `FRAME_SUDO_PW` (never stored in the scripts).

## wake-test.sh, the reproduction / acceptance test

```
FRAME_SUDO_PW=... sh tests/wake-test.sh [deep|s2idle] [label]
```

It arms WoWLAN (`iw phy phy0 wowlan enable magic-packet`) and PCI wakeup on the WLAN
function (`0000:01:00.0`), its root port, and the pcie0 platform device; sets an RTC safety
alarm; suspends the Frame by writing `/sys/power/state` directly (bypassing logind
inhibitors while keeping the Wi-Fi association, which WoWLAN needs); then floods magic
packets (UDP 9 and 7, broadcast + unicast) from the host for `WAIT` seconds (default 90).

- **PASS (exit 0)** = the Frame answered SSH within `WAIT` seconds, i.e. a magic packet
  woke it. This is the acceptance criterion for a working fix.
- **FAIL (exit 1)** = it did not wake; the RTC alarm (`RTC_SAFETY`, default +240 s) then
  brings it back. Every run in `../logs/` is a FAIL, the feature is blocked until Valve
  ships firmware/AOP support.

It appends a timestamped journal of the suspend cycle to `build/kernel/wake-<label>-<mode>-<ts>.log`.
Safety net: it arms a `wake-test-recover` unit that reboots the Frame if the default gateway
is unreachable ~7 minutes of wall-clock-awake after the sleep (REQ-019 amendment 4: a v6
build came back with Wi-Fi dead; this guarantees the Frame returns to the network).

`mode`: `deep` = PSCI system suspend (SoC powered down); `s2idle` = suspend-to-idle (GIC/ITS
stay alive, the only mode where an in-band PME MSI could in principle end the sleep).
`NOMAGIC=1` suppresses the packets for a control run (prove a toggle is independent of
traffic). `WAIT=`/`RTC_SAFETY=` override the timings.

## verify-kernel.sh, build / deploy verification

```
FRAME_SUDO_PW=... sh tests/verify-kernel.sh [--stage beta|kernel]
```

Checks (exit 1 on any failure, each line `PASS`/`FAIL`):

- REQ-018: Valve's recovery kit is on the Mac at the exact expected sizes (QDL package and
  USB repair image), so recovery never depends on a later download.
- REQ-018: the Frame tracks the `beta` branch, runs a `7.2` kernel, and slot B is still the
  stock `SteamOS-B-0.4.5-20261022.6150929` image (untouched).
- REQ-019: a patched `Image` + `sm8650-mp.dtb` were built, the pinned commit and patch are
  recorded, and the Frame is booted from slot A. With `EXPECT_PATCHED=1` it additionally
  requires the running kernel to equal `build/kernel/KERNELRELEASE` (`7.2.0-wake+`);
  otherwise it just reports what is running.

Note: these scripts reference `build/kernel/...` paths (the live working tree they were
written against). In this handoff the same files live under `../kernel/` and `../logs/`.
