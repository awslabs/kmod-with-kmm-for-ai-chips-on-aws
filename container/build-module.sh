#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DRIVER_VERSION=$1
KERNEL_VERSION=$2

cd /aws-neuron-driver

# Function to perform semantic version comparison
# Returns true if first version is less than second version
# This is more reliable than simple string comparison for version numbers
version_lt() {
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1"
}

# Patch for versions before 2.18.12.0
# Issue: These older versions incorrectly use kernel version 6.4.0 as detection point
#        for const vs non-const function signatures, which breaks RHEL kernel builds
# Fix: Adjust the kernel version check to 5.14.0 to properly handle RHEL kernels
if version_lt "${DRIVER_VERSION}" "2.18.12.0"; then
    echo "Version ${DRIVER_VERSION} is lower than 2.18.12.0, applying legacy kernel version patch..."
    echo "Patching neuron_cdev.c to fix const function signature detection..."
    sed -i "s/KERNEL_VERSION(6, 4, 0)/KERNEL_VERSION(5, 14, 0)/g" neuron_cdev.c
fi

# Patch for versions 2.22.2.0 and above
# Issue: Driver incorrectly handles const vs non-const function signatures for RHEL 9.4
#        by only enabling const signatures for RHEL 9.5+
# Fix: Adjust the RHEL version check to include RHEL 9.4, which also requires const signatures
#      for class show functions (affects node_id and server_id sysfs attributes)
if ! version_lt "${DRIVER_VERSION}" "2.22.2.0"; then
    echo "Version ${DRIVER_VERSION} is 2.22.2.0 or higher, applying RHEL 9.4 compatibility patch..."
    echo "Patching neuron_cdev.c to correctly handle const function signatures in RHEL 9.4..."
    sed -i 's/RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9, 5)/RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9, 4)/g' neuron_cdev.c
fi

# Patch for RHEL 9.6+ (kernel 5.14.0-570+) -- neuron 2.28+ only
# Issue: 2.28.0.0 added a custom .get_unmapped_area fop (ncdev_get_unmapped_area ->
#        nmmap_get_unmapped_area) for an EFA P2P 2MB-page optimization. Its helper macro
#        resolves to a *get_unmapped_area kernel routine that is NOT module-linkable on
#        RHEL 9.6+:
#          - mm_get_unmapped_area() does not exist (verified via /proc/kallsyms on el9_6).
#          - get_unmapped_area() is an inline calling the un-exported __get_unmapped_area()
#            (verified: modpost "undefined!" on el9_8 / 5.14.0-687).
#          - the pre-9.5 fallback mm->get_unmapped_area was removed from mm_struct.
# Fix: Disable the custom fop on RHEL 9.6+ so the kernel uses its own internal VA
#      placement (identical to pre-2.28 behavior); mmap still works. The EFA 2MB
#      optimization is sacrificed, which is moot since EFA P2P is not available on RHEL.
#        1) neutralize the helper macro so the now-unused nmmap_get_unmapped_area no longer
#           references any un-exported symbol (fixes modpost link error);
#        2) set the fop to NULL so kernel default placement is used (correctness);
#        3) mark the now-unused static fop function __maybe_unused (avoids -Werror).
# Safe for older drivers (2.26.5.0, 2.27.4.0): they contain none of these lines, so every
# sed below is a guaranteed no-op.
RHEL_MINOR=$(echo "${KERNEL_VERSION}" | sed -n 's/.*el[0-9][_\.]\([0-9]*\).*/\1/p')
if [ "${RHEL_MINOR:-0}" -ge 6 ] 2>/dev/null; then
    echo "RHEL 9.${RHEL_MINOR} detected, disabling custom .get_unmapped_area fop (neuron 2.28+)..."
    # 1) neutralize helper macro (both RHEL >=9.5 and pre-9.5 branches) -> no kernel symbol ref
    sed -i 's/mm_get_unmapped_area(current->mm, filep, addr, len, pgoff, flags)/(addr)/g' neuron_mmap.h
    sed -i 's/current->mm->get_unmapped_area(filep, addr, len, pgoff, flags)/(addr)/g' neuron_mmap.h
    # 2) do not register the custom fop -> kernel uses default VA placement
    sed -i 's/\.get_unmapped_area = ncdev_get_unmapped_area,/.get_unmapped_area = NULL,/' neuron_cdev.c
    # 3) the fop function is now unused; prevent -Werror=unused-function
    sed -i 's/static unsigned long ncdev_get_unmapped_area(/static unsigned long __maybe_unused ncdev_get_unmapped_area(/' neuron_cdev.c
fi

# Build the module
echo "Building kernel module..."
make -C /lib/modules/"${KERNEL_VERSION}"/build M="$(pwd)" modules

# Copy to output location
cp neuron.ko /output/