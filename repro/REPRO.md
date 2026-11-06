# Reproducing the failure

You need: a Steam Frame in Developer Mode (SSH enabled), a second machine on the same LAN,
and the Frame's Wi-Fi MAC. The failure reproduces on both the stock 0.4.5 (6.18) image and
the 0.5.7 beta (7.2) kernel; the two behave differently (see step 5).

1. **Arm WoWLAN and PCI wakeup on the Frame** (SSH in):
   ```
   nmcli con modify <ssid> 802-11-wireless.wake-on-wlan magic
   nmcli con up <ssid>
   iw phy phy0 wowlan show          # -> "wake up on magic packet"
   echo enabled > /sys/bus/pci/devices/0000:01:00.0/power/wakeup
   echo enabled > /sys/bus/pci/devices/0000:00:00.0/power/wakeup
   ```
   The radio advertises the capability (`iw … wowlan show` lists magic-packet; `lspci -vv`
   on `01:00.0` shows `PME(D3hot+,D3cold+)`), and NetworkManager accepts the setting.

2. **Suspend the Frame.** Default is `deep`; for the s2idle variant first
   `echo s2idle > /sys/power/mem_sleep`.
   ```
   systemctl suspend
   ```
   (logind refuses a direct suspend from a service; the test harness writes
   `/sys/power/state` in a transient unit instead. Either way keep the Wi-Fi association up.)

3. **From the second LAN host, send magic packets** to the Frame's Wi-Fi MAC — broadcast and
   unicast, UDP ports 9 and 7 — for a few minutes. (The payload is `ff*6` followed by the
   6-byte MAC repeated 16 times; `tests/wake-test.sh` sends it from Python.)

4. **Observe: the headset does not wake.** Press the power button to bring it back and read
   `journalctl -k -b`.

5. **What the journal shows:**
   - **6.18 (stock 0.4.5):** the radio was powered off in suspend (D3cold rails dropped), so
     the WoW state was never armed; on resume the port retrains from scratch. WoWLAN cannot
     work here regardless of the wake path.
   - **7.2 (beta 0.5.7):** the radio survives suspend (clean MHI M3, no crash — see
     `../logs/wake-baseline-stock72-*.log`). On a patched build with `ath12k.wow_flags=2`,
     after an RTC-timed resume the firmware reports a WoW wakeup (`WOW_REASON_RECV_MAGIC_PATTERN`
     in the deep run; `WOW_REASON_PAGE_FAULT` in the clean s2idle run) and the endpoint/root-port
     PME bits are set (`PMCSR 0x810b … PME_Status SET`, `RTSTA 0x00030100 … PME SET`), while
     `WAKE# disarmed (level 1)` shows WAKE# was never pulled — the packet was caught and
     signalled in-band, but nothing on the SoC turned that into a wake. See the decisive run
     `../logs/wake-handoff-v12-pme-s2idle-20261105-232758.log`, `../TECHNICAL.md`, and the
     firmware root cause in `../firmware/README.md`.
   - In the **s2idle** case on some patched builds Wi-Fi can come back dead until reboot (a
     known `ath12k`-crash-on-suspend hazard); `tests/wake-test.sh` arms a recovery unit for
     exactly this.

The acceptance test for any fix is `tests/wake-test.sh deep` (and `s2idle`) returning exit 0
— the Frame answering SSH from a magic packet before the RTC safety alarm.
