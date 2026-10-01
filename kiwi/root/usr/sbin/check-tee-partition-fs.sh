#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
set -e

DEV=/dev/disk/by-partlabel/persist
[ -b "$DEV" ] || exit 0

export PATH=/sbin:/usr/sbin

for tool in blkid e2fsck mkfs.ext4; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool: required filesystem tool not found"
        exit 1
    fi
done

# Check if ext4 filesystem exists
if [ "$(blkid -o value -s TYPE "$DEV" 2>/dev/null)" != "ext4" ]; then
    echo "$DEV: no valid ext4 filesystem found, creating ext4"
    mkfs.ext4 -F "$DEV"
    exit 0
fi

# Run a read-only fsck check to detect corruptions
if e2fsck -n "$DEV" >/dev/null 2>&1; then
    err=0
else
    err=$?
fi
if [ "$err" -ge 4 ]; then
    echo "$DEV: filesystem corrupted (e2fsck error=$err), recreating"
    mkfs.ext4 -F "$DEV"
    exit 0
else
    echo "$DEV: filesystem is OK"
fi
