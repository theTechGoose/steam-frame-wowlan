#!/bin/sh
# REQ-019 (and REQ-018 baseline): Wake-on-WLAN test against the Frame.
# Arms WoWLAN + PCI wakeup on the Frame, suspends it, sends magic packets from the Mac, and
# asserts the Frame answers ssh within WAIT seconds. Journal evidence is saved to the log.
# Usage: FRAME_SUDO_PW=... sh tests/wake-test.sh [deep|s2idle] [label]
# Exit 0 = woke by magic packet; 1 = did not wake (an RTC alarm then wakes it as safety net).
mode=${1:-deep}; label=${2:-baseline}
WAIT=${WAIT:-90}; RTC_SAFETY=${RTC_SAFETY:-240}
log=build/kernel/wake-$label-$mode-$(date +%Y%m%d-%H%M%S).log
mkdir -p build/kernel
S="echo '$FRAME_SUDO_PW' | sudo -S -p ''"
say() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$log"; }

mac=$(ssh -o BatchMode=yes frame "cat /sys/class/net/wlan0/address") || { say "FAIL: frame unreachable"; exit 1; }
ip=$(ssh -o BatchMode=yes frame "ip -4 -o addr show wlan0 | awk '{print \$4}' | cut -d/ -f1")
bcast=$(ssh -o BatchMode=yes frame "ip -4 -o addr show wlan0 | sed -n 's/.*brd \([0-9.]*\).*/\1/p'")
kver=$(ssh -o BatchMode=yes frame uname -r)
say "label=$label mode=$mode kernel=$kver mac=$mac ip=$ip bcast=$bcast"

# Arm (remote helper, uploaded each run to avoid nested quoting): WoWLAN magic in the driver, PCI wakeup on the
# WLAN function and its root port, RTC safety alarm, then suspend by writing the sleep state to the kernel directly
# (bypasses logind inhibitors; NetworkManager keeps the association, which is what WoWLAN needs).
ssh -o BatchMode=yes frame 'cat > /home/steamos/wake-arm.sh' <<'REMOTE'
mode=$1; rtc=$2
iw phy phy0 wowlan enable magic-packet
echo enabled > /sys/bus/pci/devices/0000:01:00.0/power/wakeup
echo enabled > /sys/bus/pci/devices/0000:00:00.0/power/wakeup
[ -f /sys/devices/platform/soc@0/1c00000.pcie/power/wakeup ] && echo enabled > /sys/devices/platform/soc@0/1c00000.pcie/power/wakeup
echo "$mode" > /sys/power/mem_sleep
echo 0 > /sys/class/rtc/rtc0/wakealarm; echo "+$rtc" > /sys/class/rtc/rtc0/wakealarm
iw phy phy0 wowlan show
echo "mem_sleep: $(cat /sys/power/mem_sleep)  wakeup 01:00.0=$(cat /sys/bus/pci/devices/0000:01:00.0/power/wakeup) 00:00.0=$(cat /sys/bus/pci/devices/0000:00:00.0/power/wakeup) pcie=$(cat /sys/devices/platform/soc@0/1c00000.pcie/power/wakeup 2>/dev/null || echo n/a)"
echo "boot-id $(cat /proc/sys/kernel/random/boot_id)"
systemctl stop wake-test-suspend.timer wake-test-suspend.service 2>/dev/null; systemctl reset-failed wake-test-suspend.service 2>/dev/null
# Recovery guard: if Wi-Fi is dead after the sleep (REQ-019 amendment 4: v6 came back with ath12k in SYS ERROR), reboot so the Frame is reachable again.
# --on-active is CLOCK_MONOTONIC, which pauses in deep sleep, so this fires ~7 min of awake time after arming — well past the RTC safety alarm.
systemctl stop wake-test-recover.timer wake-test-recover.service 2>/dev/null; systemctl reset-failed wake-test-recover.service 2>/dev/null
systemd-run --quiet --on-active=420 --unit=wake-test-recover sh -c 'ping -c3 -W3 '"$(ip route | awk '/default/ {print $3; exit}')"' >/dev/null 2>&1 || { logger -t wake-test "no network after resume, rebooting"; systemctl reboot; }'
systemd-run --quiet --on-active=2 --unit=wake-test-suspend sh -c 'echo mem > /sys/power/state'
REMOTE
ssh -o BatchMode=yes frame "$S sh /home/steamos/wake-arm.sh $mode $RTC_SAFETY" 2>&1 | tee -a "$log"
say "suspend requested; waiting 25 s for it to go down"
sleep 25
if ssh -o ConnectTimeout=3 -o BatchMode=yes frame true 2>/dev/null; then say "FAIL: frame never suspended"; exit 1; fi
say "frame is down; ${NOMAGIC:+NOT }sending magic packets to $mac via $bcast and $ip for $WAIT s"
t0=$(date +%s); woke=0
while [ $(( $(date +%s) - t0 )) -lt "$WAIT" ]; do
  [ -n "${NOMAGIC:-}" ] || python3 -I - "$mac" "$bcast" "$ip" <<'PY'
import socket,sys
mac=bytes.fromhex(sys.argv[1].replace(':','')); pkt=b'\xff'*6+mac*16
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
for dst in sys.argv[2:]:
    for port in (9,7):
        try: s.sendto(pkt,(dst,port))
        except OSError as e: print("send",dst,port,e)
PY
  sleep 3
  if ssh -o ConnectTimeout=3 -o BatchMode=yes frame true 2>/dev/null; then woke=1; break; fi
done
elapsed=$(( $(date +%s) - t0 ))
if [ $woke = 1 ]; then say "WOKE after ${elapsed}s (magic packets)"; else say "did not wake in ${WAIT}s; waiting for RTC safety alarm"; fi
for i in $(seq 1 60); do ssh -o ConnectTimeout=3 -o BatchMode=yes frame true 2>/dev/null && break; sleep 5; done
say "--- journal (this suspend cycle)"
ssh -o BatchMode=yes frame "$S journalctl -b --no-pager --since '-6 min' -o short-monotonic | grep -iE 'suspend|resume|wake|pcie|mhi|ath12k|wow|rtc|PM:' | tail -60" 2>&1 | tee -a "$log"
ssh -o BatchMode=yes frame "$S sh -c 'echo 0 > /sys/class/rtc/rtc0/wakealarm; echo deep > /sys/power/mem_sleep'" >/dev/null 2>&1
say "log: $log"
[ $woke = 1 ]
