#!/bin/bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Kiwi post-install configuration script.
# Runs inside the image chroot after all packages are installed.
# Equivalent to mkosi's Hostname=, RootPassword=, Timezone=, Locale= settings.

set -euo pipefail

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "centos" > /etc/hostname

# ── Root password ─────────────────────────────────────────────────────────────
echo "root:qcom" | chpasswd

# ── Timezone ──────────────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

# ── Locale ────────────────────────────────────────────────────────────────────
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ── Services ──────────────────────────────────────────────────────────────────
systemctl enable sshd.service        || true
systemctl enable NetworkManager.service || true
