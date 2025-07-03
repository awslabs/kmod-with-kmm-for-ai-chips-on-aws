#!/bin/bash
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

# Build the module
echo "Building kernel module..."
make -C /lib/modules/${KERNEL_VERSION}/build M=$(pwd) modules

# Copy to output location
cp neuron.ko /output/