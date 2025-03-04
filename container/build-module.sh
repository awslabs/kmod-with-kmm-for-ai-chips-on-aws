#!/bin/bash
set -euo pipefail

DRIVER_VERSION=$1
KERNEL_VERSION=$2

cd /aws-neuron-driver

# Patching logic - only for versions lower than 2.18.12.0
if [ $(echo -e "${DRIVER_VERSION}\n2.18.12.0" | sort -V | head -n 1) = "${DRIVER_VERSION}" ] && \
   [ "${DRIVER_VERSION}" != "2.18.12.0" ]; then
    echo "Version ${DRIVER_VERSION} is lower than 2.18.12.0, applying patches..."
    echo "Patching neuron_cdev.c..."
    sed -i "s/KERNEL_VERSION(6, 4, 0)/KERNEL_VERSION(5, 14, 0)/g" neuron_cdev.c
fi

# Build the module
echo "Building kernel module..."
make -C /lib/modules/${KERNEL_VERSION}/build M=$(pwd) modules

# Copy to output location
cp neuron.ko /output/