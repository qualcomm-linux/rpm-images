#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Kiwi post-install configuration script.
# Runs inside the image chroot after all packages are installed.
# Equivalent to mkosi's Hostname=, RootPassword=, Timezone=, Locale= settings.

set -euo pipefail

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "centos" > /etc/hostname

# ── Timezone ──────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

# ── Locale ────────────────────────────────────────────────────────────────────
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ── Default user ──────────────────────────────────────────────────────────────
useradd --create-home --shell /bin/bash --user-group \
    --groups wheel,audio,video,render,users qcom
echo "qcom:qcom" | chpasswd

# Force password change on first login
chage --lastday 0 qcom

mkdir -p /etc/sudoers.d
echo "qcom ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-qcom
chmod 440 /etc/sudoers.d/90-qcom

# ── Services ──────────────────────────────────────────────────────────────────
systemctl enable sshd.service        || true
systemctl enable NetworkManager.service || true
