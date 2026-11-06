#!/bin/sh
# REQ-019: install the patched kernel beside Valve's in the *booted* slot (must be the 7.2 slot, never the stock 0.4.5 slot).
# Runs on the Frame as root:  sh deploy-slot.sh <tarball> <new-release> <stock-release>
# Writes /boot/Image-<new>, /boot/dtbs/<new>/, /usr/lib/modules/<new>/ and repoints the three symlinks U-Boot follows
# (/boot/Image, /boot/dtbqcom, /boot/maindtb.dtb). Valve's files are left in place; rollback.sh repoints the symlinks back.
set -eu
tar=$1; new=$2; stock=$3
case "$(cat /proc/cmdline)" in *rauc.slot=A*) ;; *) echo "refusing: not booted from slot A"; exit 2;; esac
case "$(uname -r)" in "$stock"|"$new"|*wake*) ;; *) echo "refusing: running $(uname -r), expected $stock or an experimental build"; exit 2;; esac
[ -f "/boot/Image-$stock" ] || { echo "refusing: /boot/Image-$stock missing"; exit 2; }
grep -q "SteamOS-B-0.4.5" /esp/SteamOS/conf/B.conf || { echo "refusing: slot B is not the stock 0.4.5 image"; exit 2; }
steamos-readonly disable
tar -C / --no-same-owner -xf "$tar" "boot/Image-$new" "boot/dtbs/$new" "usr/lib/modules/$new"
depmod "$new"
printf 'Image -> %s\ndtbqcom -> %s\nmaindtb.dtb -> %s\n' "$(readlink /boot/Image)" "$(readlink /boot/dtbqcom)" "$(readlink /boot/maindtb.dtb)" > /home/steamos/kernel-symlinks.before
ln -sfn "Image-$new" /boot/Image
ln -sfn "dtbs/$new/qcom" /boot/dtbqcom
ln -sfn "dtbs/$new/qcom/sm8650-mp.dtb" /boot/maindtb.dtb
# boot canary: if nobody confirms the new kernel within 10 min of boot, roll the symlinks back and reboot
install -m 755 /home/steamos/kernel-canary.sh /usr/local/bin/kernel-canary.sh
cat > /etc/systemd/system/kernel-canary.service <<UNIT
[Unit]
Description=Roll back the experimental kernel if it is not confirmed
After=multi-user.target
[Service]
Type=simple
ExecStart=/usr/local/bin/kernel-canary.sh $new $stock
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable kernel-canary.service >/dev/null 2>&1
rm -f /home/steamos/kernel-ok
sync
steamos-readonly enable
echo "--- deployed"; ls -la /boot | grep -E "^l|Image-"; ls /usr/lib/modules/
ls -la /boot/dtbqcom/sm8650-mp.dtb
