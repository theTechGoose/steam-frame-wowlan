# Building, deploying, and rolling back the patched kernel

## What the patch does

`0001-PCI-qcom-wake.patch` (current best, = history/v12) applies on Valve's 7.2 kernel
commit `9a8c8ea4695083b9847e301e9722225151a7302e` (evlaV/deckard-linux-no-oopsies,
`sm8650-7.2`). Diffstat:

```
 arch/arm64/boot/dts/qcom/sm8650-mp.dts |  30 ++-
 drivers/net/wireless/ath/ath12k/core.c |   6 +
 drivers/net/wireless/ath/ath12k/core.h |   2 +
 drivers/net/wireless/ath/ath12k/wmi.c  |   4 +-
 drivers/pci/controller/dwc/pcie-qcom.c | 400 +++-
 drivers/pci/msi/irqdomain.c            |   4 +-
```

- `pcie-qcom.c`: register `wake-gpios` (tlmm 96) as a wakeup IRQ for a wakeup-enabled
  endpoint, armed in `suspend_late`; map the CLKREQ# (tlmm 95, PDC) IRQ once at probe and
  enable it as a wake source only for a sleep; `keep_link` (default on) keeps the link in
  L1ss across suspend, `skip_perst` leaves PERST# deasserted; log RTSTA/PMCSR in
  `resume_noirq`. Both knobs are module params (`/sys/module/qcom_pcie/parameters/`).
- `ath12k` (`wmi.c` + `core.c`/`core.h`): add `ath12k.wow_flags`, written into
  `WMI_WOW_ENABLE_CMDID` (`cmd->flags = cpu_to_le32(ath12k_wow_flags)`). Set `wow_flags=2`
  for `WMI_WOW_FLAG_SEND_PM_PME`. Mainline sends 0.
- `irqdomain.c`: mark the PCI-MSI / MSI-X irq chips `IRQCHIP_SKIP_SET_WAKE` so
  `pcie_pme_suspend()` keeps the root port's PME interrupt armed (as x86 does).
- `sm8650-mp.dts`: `clkreq-gpios`, a `pcie0_sleep_state` pinctrl node, and `pinctrl-1`.

`history/` holds v3→v12. Each version fixed one blocker: v4 moved WAKE# arming from
`suspend_noirq` to `suspend_late` (so `suspend_device_irqs()` does not mask it); v6 tried
muxing CLKREQ# to GPIO (killed the link — see the postmortem log); v8→v9 mapped the CLKREQ#
IRQ at probe with the pad left on the controller and armed it `IRQF_NO_SUSPEND` in
`suspend_noirq`; v10 added `wow_flags` + RTSTA/PMCSR logging; v11 added the `clkreq_probe`
diagnostic knob; v12 added `IRQCHIP_SKIP_SET_WAKE`. See the per-version story in
`requirements.md` (REQ-019 amendments 1–6) and `../logs/INDEX.md`.

## Build recipe (podman on macOS)

A Fedora 42 kbuild container cross-compiles for arm64.

1. `podman machine` named `frame-build` (12 CPU / 16 GB).
2. Container `kbuild` from `fedora:42` (gcc 15.2, pahole 1.30). The kernel tree lives at
   `/work/linux` (podman volume `kbuild`); the project is mounted at `/host`.
3. Check out Valve commit `9a8c8ea46950`, apply the patch:
   `git -C /work/linux am < /host/build/handoff/kernel/0001-PCI-qcom-wake.patch`
   (or `patch -p1`).
4. Config: Valve `gabe_defconfig`, with `LOCALVERSION_AUTO` off and `LOCALVERSION="-wake"`
   so the release string stays `7.2.0-wake+` across rebuilds.
5. Build: `make -j12 ARCH=arm64 Image dtbs modules`.
6. Package `Image`, `dtbs/`, and `modules/` for release `7.2.0-wake+` into a single
   tarball `kernel-7.2.0-wake+.tar` laid out as `boot/Image-<rel>`, `boot/dtbs/<rel>/`,
   `usr/lib/modules/<rel>/`.

Pinned facts recorded alongside the build: `COMMIT`, `KERNELRELEASE` (`7.2.0-wake+`),
`PATCH_APPLIED` (the applied commit + diffstat).

Hard rule: never deploy the `Image` alone. `CONFIG_DEBUG_INFO_BTF_MODULES=y` makes every
module fail `BTF: -22` against a mismatched Image; `pci_pwrctrl_pwrseq` then never loads and
Wi-Fi never comes up. Always deploy the full tarball (Image + dtbs + modules together).

## Deploy (on the Frame, as root)

`deploy-slot.sh <tarball> <new-release> <stock-release>` installs beside Valve's kernel in
the **booted** slot and repoints the three symlinks U-Boot follows (`/boot/Image`,
`/boot/dtbqcom`, `/boot/maindtb.dtb`). It refuses to run unless booted from slot A, the
running kernel is the stock/experimental one, and slot B is the stock 0.4.5 image — slot B
is never touched. It also installs `kernel-canary.service`.

```
sh deploy-slot.sh kernel-7.2.0-wake+.tar 7.2.0-wake+ 7.2.0-g9a8c8ea46950
# reboot; confirm Wi-Fi is up, then:
touch /home/steamos/kernel-ok
```

Boot canary (`kernel-canary.sh`, run by the installed service): if `/home/steamos/kernel-ok`
is not touched within 10 minutes of boot while the experimental kernel is running, it
repoints the symlinks back to Valve's kernel and reboots — so a bad kernel never requires
touching the headset. Touch `kernel-ok` after every boot you confirm.

## Roll back

```
sh rollback.sh 7.2.0-g9a8c8ea46950
```

Repoints the three symlinks to Valve's kernel and disables the canary. The experimental
files are left in the slot for the next round.
