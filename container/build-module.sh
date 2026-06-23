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

# Patch for RHEL 9.6+ (kernel 5.14.0-570+)
# Issue: neuron_mmap.h selects mm_get_unmapped_area() for RHEL >= 9.5, but on RHEL 9.6+
#        that function does not exist (verified via /proc/kallsyms on 5.14.0-570.el9_6:
#        no mm_get_unmapped_area symbol). The pre-9.5 fallback (mm->get_unmapped_area)
#        also fails because the get_unmapped_area field was removed from mm_struct.
# Fix: For RHEL 9.6+, call the global get_unmapped_area() instead. It exists, is
#      EXPORT_SYMBOL'd (verified: __ksymtab_get_unmapped_area present), is declared in
#      linux/mm.h, and its signature (file, addr, len, pgoff, flags) matches the macro args.
RHEL_MINOR=$(echo "${KERNEL_VERSION}" | sed -n 's/.*el[0-9][_\.]\([0-9]*\).*/\1/p')
if [ "${RHEL_MINOR:-0}" -ge 6 ] 2>/dev/null; then
    echo "RHEL 9.${RHEL_MINOR} detected, patching neuron_mmap.h to use global get_unmapped_area()..."
    sed -i 's/mm_get_unmapped_area(current->mm, filep, addr, len, pgoff, flags)/get_unmapped_area(filep, addr, len, pgoff, flags)/g' neuron_mmap.h
fi

# Build the module
echo "Building kernel module..."
make -C /lib/modules/"${KERNEL_VERSION}"/build M="$(pwd)" modules

# Copy to output location
cp neuron.ko /output/