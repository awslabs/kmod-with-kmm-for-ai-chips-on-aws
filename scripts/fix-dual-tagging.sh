#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Script to fix existing single-tagged images by adding missing kernel-specific tags

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Check for required commands
for cmd in aws jq podman; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd is not installed"
        exit 1
    fi
done

# Function to extract kernel version from DTK image
extract_kernel_version_from_dtk() {
    local dtk_image="$1"
    
    echo "Extracting kernel version from DTK image: ${dtk_image}" >&2
    
    # Pull image if not present
    if ! podman image exists "${dtk_image}" 2>/dev/null; then
        echo "Pulling DTK image: ${dtk_image}" >&2
        if ! podman pull "${dtk_image}" >/dev/null 2>&1; then
            echo "Error: Failed to pull DTK image: ${dtk_image}" >&2
            return 1
        fi
    fi
    
    # Create temp file
    local temp_json
    temp_json=$(mktemp) || return 1
    
    # Create temporary container
    local temp_container
    if ! temp_container=$(podman create "${dtk_image}" 2>/dev/null); then
        echo "Error: Failed to create temporary container" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    # Copy file
    local copy_success=false
    if podman cp "${temp_container}:/etc/driver-toolkit-release.json" "${temp_json}" >/dev/null 2>&1; then
        copy_success=true
    fi
    
    # Clean up container
    podman rm "${temp_container}" >/dev/null 2>&1 || true
    
    if [ "${copy_success}" != "true" ]; then
        echo "Error: Could not copy driver-toolkit-release.json" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    # Parse JSON
    local kernel_version
    if ! kernel_version=$(jq -r '.KERNEL_VERSION // empty' "${temp_json}" 2>/dev/null); then
        echo "Error: Failed to parse JSON" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    rm -f "${temp_json}"
    
    if [ -n "${kernel_version}" ] && [[ "${kernel_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "${kernel_version}"
        return 0
    else
        echo "Error: Invalid kernel version: ${kernel_version}" >&2
        return 1
    fi
}

# Authenticate with ECR Public
echo "Authenticating with ECR Public..."
if ! aws ecr-public get-login-password --region us-east-1 --no-cli-pager | \
    podman login --username AWS --password-stdin public.ecr.aws; then
    echo "Error: Failed to authenticate with ECR Public"
    exit 1
fi

# Authenticate with Quay.io (for DTK images)
if [ -n "${QUAY_USERNAME:-}" ] && [ -n "${QUAY_PASSWORD:-}" ]; then
    echo "Authenticating with Quay.io..."
    echo "${QUAY_PASSWORD}" | podman login quay.io -u "${QUAY_USERNAME}" --password-stdin
else
    echo "Warning: QUAY_USERNAME and QUAY_PASSWORD not set, DTK access may fail"
fi

ECR_IMAGE_BASE="public.ecr.aws/q5p6u7h8/neuron-openshift/neuron-kernel-module"

# Process each driver version in build-matrix.json
while IFS= read -r driver_entry; do
    driver_version=$(echo "$driver_entry" | jq -r '.driver')
    echo "Processing driver version: ${driver_version}"
    
    # Get OCP versions for this driver
    ocp_versions=$(echo "$driver_entry" | jq -r '.ocp_versions[]')
    
    for ocp_major in $ocp_versions; do
        echo "  Processing OCP major version: ${ocp_major}"
        
        # Find all specific OCP versions that match this major version
        while IFS= read -r dtk_entry; do
            ocp_version=$(echo "$dtk_entry" | jq -r '.version')
            
            # Check if this OCP version matches the major version pattern
            if [[ "$ocp_version" =~ ^${ocp_major}\.[0-9]+$ ]]; then
                echo "    Checking OCP version: ${ocp_version}"
                
                dtk_image=$(echo "$dtk_entry" | jq -r '.dtk')
                ocp_tag="${driver_version}-ocp${ocp_version}"
                
                # Check if OCP tag exists
                if podman pull "${ECR_IMAGE_BASE}:${ocp_tag}" >/dev/null 2>&1; then
                    echo "      Found OCP tag: ${ocp_tag}"
                    
                    # Extract kernel version
                    if KERNEL_VERSION=$(extract_kernel_version_from_dtk "${dtk_image}"); then
                        kernel_tag="${driver_version}-${KERNEL_VERSION}"
                        echo "      Expected kernel tag: ${kernel_tag}"
                        
                        # Check if kernel tag exists
                        if ! podman pull "${ECR_IMAGE_BASE}:${kernel_tag}" >/dev/null 2>&1; then
                            echo "      Missing kernel tag! Creating it..."
                            
                            # Tag the OCP image with kernel tag
                            podman tag "${ECR_IMAGE_BASE}:${ocp_tag}" "${ECR_IMAGE_BASE}:${kernel_tag}"
                            
                            # Push the kernel tag
                            if podman push "${ECR_IMAGE_BASE}:${kernel_tag}"; then
                                echo "      ✓ Successfully created kernel tag: ${kernel_tag}"
                            else
                                echo "      ✗ Failed to push kernel tag: ${kernel_tag}"
                            fi
                            
                            # Clean up local tag
                            podman rmi "${ECR_IMAGE_BASE}:${kernel_tag}" >/dev/null 2>&1 || true
                        else
                            echo "      ✓ Kernel tag already exists: ${kernel_tag}"
                            podman rmi "${ECR_IMAGE_BASE}:${kernel_tag}" >/dev/null 2>&1 || true
                        fi
                    else
                        echo "      ✗ Failed to extract kernel version for OCP ${ocp_version}"
                    fi
                    
                    # Clean up OCP image
                    podman rmi "${ECR_IMAGE_BASE}:${ocp_tag}" >/dev/null 2>&1 || true
                else
                    echo "      No OCP tag found: ${ocp_tag}"
                fi
            fi
        done < <(jq -c '.[]' "${PROJECT_ROOT}/driver-toolkit/driver-toolkit.json")
    done
done < <(jq -c '.[]' "${PROJECT_ROOT}/build-matrix.json")

echo "Dual tagging fix completed!"