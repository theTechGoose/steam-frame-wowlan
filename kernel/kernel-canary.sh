#!/bin/sh
# Runs at every boot. Only acts when the experimental kernel is running and /home/steamos/kernel-ok was not touched in time.
new=$1; stock=$2
[ "$(uname -r)" = "$new" ] || exit 0
sleep 600
[ -f /home/steamos/kernel-ok ] && exit 0
logger -t kernel-canary "experimental kernel $new not confirmed in 10 min; rolling back to $stock and rebooting"
steamos-readonly disable
ln -sfn "Image-$stock" /boot/Image
ln -sfn "dtbs/$stock/qcom" /boot/dtbqcom
ln -sfn "dtbs/$stock/qcom/sm8650-mp.dtb" /boot/maindtb.dtb
sync
steamos-readonly enable
systemctl reboot
