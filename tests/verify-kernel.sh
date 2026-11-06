#!/bin/sh
# REQ-018 / REQ-019 verification. Run from the repo root on the Mac. Exit 1 on any failure.
# Usage: sh tests/verify-kernel.sh [--stage beta|kernel]   (default: all checks)
RECOVERY_DIR="$HOME/Downloads/steam-frame-recovery"
QDL="steamframe-oobe-repair-qdl-20260922.5153644-0.3.0.tar.gz"; QDL_SIZE=4100462821
IMG="steamframe-oobe-repair-20260922.5153644-0.3.0.img.bz2";    IMG_SIZE=4068109407
STOCK_TITLE="SteamOS-B-0.4.5-20261022.6150929"
fail=0
ok()   { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }
size() { [ -f "$1" ] || { echo 0; return; }; wc -c < "$1" | tr -d " "; }
stage=all; [ "$1" = "--stage" ] && stage=$2

echo "== REQ-018: recovery kit on the Mac"
[ "$(size "$RECOVERY_DIR/$QDL")" = "$QDL_SIZE" ] && ok "QDL package complete" || bad "QDL package missing/incomplete ($(size "$RECOVERY_DIR/$QDL")/$QDL_SIZE)"
[ "$(size "$RECOVERY_DIR/$IMG")" = "$IMG_SIZE" ] && ok "USB repair image complete" || bad "USB repair image missing/incomplete ($(size "$RECOVERY_DIR/$IMG")/$IMG_SIZE)"

echo "== REQ-018: Frame tracks beta, runs 7.2, stock slot B untouched"
# atomupd-manager and /esp/SteamOS/conf need root on the Frame: pass the sudo password in FRAME_SUDO_PW (never stored here).
remote=$(ssh -o ConnectTimeout=10 -o BatchMode=yes frame "echo '$FRAME_SUDO_PW' | sudo -S -p '' sh -c 'echo branch=\$(atomupd-manager tracked-branch); echo kernel=\$(uname -r); echo titleB=\$(grep ^title: /esp/SteamOS/conf/B.conf | cut -d\" \" -f2); echo booted=\$(tr \" \" \"\\n\" < /proc/cmdline | grep rauc.slot)'" 2>/dev/null)
[ -n "$remote" ] || bad "Frame unreachable over ssh"
echo "$remote" | grep -q '^branch=beta$'   && ok "tracked branch is beta"  || bad "tracked branch: $(echo "$remote" | grep ^branch=)"
echo "$remote" | grep -q '^kernel=7\.2\.'  && ok "running kernel 7.2"      || bad "running kernel: $(echo "$remote" | grep ^kernel=)"
echo "$remote" | grep -q "^titleB=$STOCK_TITLE$" && ok "slot B still $STOCK_TITLE" || bad "slot B title: $(echo "$remote" | grep ^titleB=)"

if [ "$stage" = all ] || [ "$stage" = kernel ]; then
  echo "== REQ-019: patched kernel built and deployed to the non-stock slot"
  [ -f build/kernel/Image ] && [ -f build/kernel/sm8650-mp.dtb ] && ok "patched Image + dtb built" || bad "build/kernel/Image or sm8650-mp.dtb missing"
  [ -f build/kernel/COMMIT ] && [ -f build/kernel/PATCH_APPLIED ] && ok "pinned commit + patch recorded" || bad "build/kernel/COMMIT or PATCH_APPLIED missing"
  echo "$remote" | grep -q '^booted=rauc.slot=A$' && ok "booted from slot A (7.2)" || bad "booted: $(echo "$remote" | grep ^booted=)"
  want=$(cat build/kernel/KERNELRELEASE 2>/dev/null)
  if [ "${EXPECT_PATCHED:-0}" = 1 ]; then
    [ -n "$want" ] && echo "$remote" | grep -q "^kernel=$want$" && ok "patched kernel $want is running" || bad "patched kernel not running (want $want, got $(echo "$remote" | grep ^kernel=))"
  else
    printf 'INFO running %s (set EXPECT_PATCHED=1 to require %s)\n' "$(echo "$remote" | grep ^kernel= | cut -d= -f2)" "$want"
  fi
  [ -f tests/wake-test.sh ] && ok "wake-test.sh present (run it separately: sh tests/wake-test.sh)" || bad "tests/wake-test.sh missing"
fi
exit $fail
