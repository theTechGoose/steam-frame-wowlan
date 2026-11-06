#!/bin/sh
# REQ-019 rollback: point the boot symlinks back at Valve's kernel. Runs on the Frame as root: sh rollback.sh <stock-release>
set -eu
stock=$1
steamos-readonly disable
ln -sfn "Image-$stock" /boot/Image
ln -sfn "dtbs/$stock/qcom" /boot/dtbqcom
ln -sfn "dtbs/$stock/qcom/sm8650-mp.dtb" /boot/maindtb.dtb
systemctl disable kernel-canary.service >/dev/null 2>&1 || true
sync
steamos-readonly enable
ls -la /boot | grep -E "^l"
