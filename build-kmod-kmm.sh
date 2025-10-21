#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo "Script starting..."

# Function to check if a command exists
check_command() {
    echo "Checking for command: $1"
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 is not installed"
        case "$1" in
            aws)
                echo "To install AWS CLI:"
                echo "  For RHEL/CentOS: sudo yum install awscli"
                echo "  For Ubuntu/Debian: sudo apt-get install awscli"
                echo "  For macOS: brew install awscli"
                echo "  Or visit: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
                ;;
            jq)
                echo "To install jq:"
                echo "  For RHEL/CentOS: sudo yum install jq"
                echo "  For Ubuntu/Debian: sudo apt-get install jq"
                echo "  For macOS: brew install jq"
                ;;
            podman)
                echo "To install podman:"
                echo "  For RHEL/CentOS: sudo yum install podman"
                echo "  For Ubuntu/Debian: sudo apt-get install podman"
                echo "  For macOS: brew install podman"
                ;;
            rpm2cpio)
                echo "To install rpm2cpio:"
                echo "  For RHEL/CentOS: sudo yum install rpm"
                echo "  For Ubuntu/Debian: sudo apt-get install rpm2cpio"
                echo "  For macOS: brew install rpm2cpio"
                ;;
            cpio)
                echo "To install cpio:"
                echo "  For RHEL/CentOS: sudo yum install cpio"
                echo "  For Ubuntu/Debian: sudo apt-get install cpio"
                echo "  For macOS: brew install cpio"
                ;;
        esac
        exit 1
    fi
}

echo "Setting up error handling..."
set -euo pipefail

# Function to check if running in GitHub Actions
is_github_actions() {
    [ -n "${GITHUB_ACTIONS:-}" ]
}

# Check for required commands (skip in GitHub Actions where tools are pre-installed)
if ! is_github_actions; then
    echo "Checking required commands..."
    for cmd in aws jq podman rpm2cpio cpio; do
        check_command "$cmd"
    done
else
    echo "Running in GitHub Actions, skipping tool checks (tools pre-installed)"
fi

# Function to validate AWS credentials are available
validate_aws_credentials() {
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "Error: Unable to validate AWS credentials"
        exit 1
    fi
}

# Function to check if a version matches the filter
version_matches() {
    local version="$1"
    local filter="$2"
    
    # If filter is a complete version (x.y.z), exact match is required
    if [[ $filter =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        [[ "$version" == "$filter" ]]
    # If filter is a minor version (x.y), match the prefix
    elif [[ $filter =~ ^[0-9]+\.[0-9]+$ ]]; then
        [[ "$version" =~ ^$filter\.[0-9]+$ ]]
    else
        echo "Invalid version filter format: $filter"
        return 1
    fi
}

# Function to manage GitHub release for a Neuron driver version
manage_github_release() {
    local driver_version="$1"
    local release_name="neuron-driver-${driver_version}"
    
    echo "Managing GitHub release: ${release_name}"
    
    # Change to repository root for GitHub CLI operations
    cd "${GITHUB_WORKSPACE}"
    
    # Create release notes with kernel-only format
    local release_notes
    release_notes="Container images for AWS Neuron driver version ${driver_version} compatible with various OpenShift releases and kernel versions.

## Usage

These images are designed to be used with the Kernel Module Manager (KMM) operator on OpenShift.
Use kernel-specific tags that match your cluster's kernel version:

## Available Images

### Kernel-Specific Tags (recommended)
"
    
    # Read kernel mappings from the build process
    if [ -f "${TEMP_DIR}/kernel_mappings.txt" ]; then
        while IFS='|' read -r kernel_version ocp_versions; do
            release_notes+="- \`public.ecr.aws/q5p6u7h8/neuron-openshift/neuron-kernel-module:${driver_version}-${kernel_version}\` (compatible with OCP: ${ocp_versions})
"
        done < "${TEMP_DIR}/kernel_mappings.txt"
    else
        echo "Warning: kernel_mappings.txt not found, release notes may be incomplete" >&2
    fi
    
    # Check if release needs updating
    if gh release view "$release_name" >/dev/null 2>&1; then
        # Get current release notes
        current_notes=$(gh release view "$release_name" --json body --jq .body 2>/dev/null || echo "")
        
        # Compare with new notes (normalize line endings)
        if [ "$(echo -e "$release_notes" | tr -d '\r')" = "$(echo "$current_notes" | tr -d '\r')" ]; then
            echo "Release ${release_name} is already up-to-date, skipping update"
            return 0
        fi
        
        echo "Updating existing release: ${release_name}"
        echo -e "$release_notes" | gh release edit "$release_name" --notes-file -
    else
        echo "Creating new release: ${release_name}"
        echo -e "$release_notes" | gh release create "$release_name" --title "Neuron Driver ${driver_version}" --notes-file -
    fi
    
    echo "GitHub release ${release_name} updated successfully"
    
    # Download and attach GPL source archives
    echo "Downloading GPL source archives..."
    
    # Download BusyBox source with fallback URLs
    busybox_downloaded=false
    cd "${GITHUB_WORKSPACE}"
    for url in "https://github.com/mirror/busybox/archive/refs/tags/1_36_1.tar.gz" "https://git.busybox.net/busybox/snapshot/busybox-1.36.1.tar.bz2"; do
        echo "Trying to download BusyBox from: $url"
        if curl -L --connect-timeout 30 --max-time 300 "$url" -o "busybox-1.36.1.tar.gz"; then
            busybox_downloaded=true
            break
        else
            echo "Failed to download from $url, trying next..."
        fi
    done
    
    if [ "$busybox_downloaded" = "false" ]; then
        echo "Warning: Failed to download BusyBox source from all URLs"
    fi
    
    # Create tarball of modified Neuron driver source (with patches applied)
    neuron_downloaded=false
    echo "Creating tarball of modified Neuron driver source..."
    if [ -d "${TEMP_DIR}/usr/src/aws-neuronx-${driver_version}" ]; then
        cd "${TEMP_DIR}/usr/src"
        tar -czf "${GITHUB_WORKSPACE}/aws-neuronx-dkms-${driver_version}-modified-source.tar.gz" "aws-neuronx-${driver_version}"
        cd "${GITHUB_WORKSPACE}"
        neuron_downloaded=true
        echo "Created modified source tarball with applied patches"
    else
        echo "Warning: Modified Neuron driver source not found in build artifacts"
    fi
    
    # Upload available source archives
    echo "Uploading source archives to release..."
    upload_files=""
    if [ "$busybox_downloaded" = "true" ]; then
        upload_files="$upload_files busybox-1.36.1.tar.gz"
    fi
    if [ "$neuron_downloaded" = "true" ]; then
        upload_files="$upload_files aws-neuronx-dkms-${driver_version}-modified-source.tar.gz"
    fi
    
    if [ -n "$upload_files" ]; then
        # shellcheck disable=SC2086
        gh release upload "${release_name}" ${upload_files} || echo "Warning: Failed to upload some source archives"
    else
        echo "Warning: No source archives to upload"
    fi
    
    # Clean up downloaded files
    rm -f "busybox-1.36.1.tar.gz" "aws-neuronx-dkms-${driver_version}-modified-source.tar.gz"
}

# Function to extract kernel version from DTK image
extract_kernel_version_from_dtk() {
    local dtk_image="$1"
    
    # Validate input
    if [ -z "${dtk_image}" ]; then
        echo "Error: DTK image parameter is required" >&2
        return 1
    fi
    
    echo "Extracting kernel version from DTK image: ${dtk_image}" >&2
    
    # Pull image with error handling (only if not already present)
    if ! podman image exists "${dtk_image}" 2>/dev/null; then
        echo "Pulling DTK image: ${dtk_image}" >&2
        if ! podman pull "${dtk_image}" >/dev/null 2>&1; then
            echo "Error: Failed to pull DTK image: ${dtk_image}" >&2
            return 1
        fi
    else
        echo "DTK image already present: ${dtk_image}" >&2
    fi
    
    # Create unique temp file (avoid race conditions)
    local temp_json
    temp_json=$(mktemp "${TEMP_DIR}/dtk-release-XXXXXX.json") || {
        echo "Error: Failed to create temporary file" >&2
        return 1
    }
    
    # Create temporary container with error handling
    local temp_container
    if ! temp_container=$(podman create "${dtk_image}" 2>/dev/null); then
        echo "Error: Failed to create temporary container from DTK image" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    # Copy file with comprehensive error handling
    local copy_success=false
    if podman cp "${temp_container}:/etc/driver-toolkit-release.json" "${temp_json}" >/dev/null 2>&1; then
        copy_success=true
    fi
    
    # Always clean up container immediately
    podman rm "${temp_container}" >/dev/null 2>&1 || true
    
    # Check if copy was successful
    if [ "${copy_success}" != "true" ]; then
        echo "Error: Could not copy driver-toolkit-release.json from DTK image" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    # Validate temp file exists and is readable
    if [ ! -f "${temp_json}" ] || [ ! -r "${temp_json}" ]; then
        echo "Error: Temporary JSON file is not accessible" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    # Parse JSON with error handling
    local kernel_version
    if ! kernel_version=$(jq -r '.KERNEL_VERSION // empty' "${temp_json}" 2>/dev/null); then
        echo "Error: Failed to parse JSON file or jq not available" >&2
        rm -f "${temp_json}"
        return 1
    fi
    
    # Clean up temp file
    rm -f "${temp_json}"
    
    # Validate kernel version format (basic sanity check)
    if [ -n "${kernel_version}" ] && [ "${kernel_version}" != "null" ] && [ "${kernel_version}" != "empty" ]; then
        # Basic format validation: should contain version numbers and dots
        if [[ "${kernel_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "Successfully extracted kernel version: ${kernel_version}" >&2
            echo "${kernel_version}"
            return 0
        else
            echo "Error: Invalid kernel version format: ${kernel_version}" >&2
            return 1
        fi
    else
        echo "Error: Could not extract valid kernel version from DTK image" >&2
        return 1
    fi
}

# Function to download and extract Neuron driver source from RPM
download_neuron_driver_source() {
    local version="$1"
    local temp_dir="$2"
    
    echo "Downloading Neuron driver source for version ${version}..."
    
    # Download RPM package
    local rpm_url="https://yum.repos.neuron.amazonaws.com/aws-neuronx-dkms-${version}.noarch.rpm"
    echo "Downloading from: ${rpm_url}"
    
    if ! wget -q "${rpm_url}" -O "${temp_dir}/aws-neuronx-dkms.rpm"; then
        echo "Error: Failed to download Neuron driver RPM for version ${version}"
        return 1
    fi
    
    # Extract RPM contents
    echo "Extracting RPM contents..."
    cd "${temp_dir}"
    
    if ! rpm2cpio aws-neuronx-dkms.rpm | cpio -idmv >/dev/null 2>&1; then
        echo "Error: Failed to extract RPM contents"
        return 1
    fi
    
    # Check if extraction was successful
    if [ -d "usr/src/aws-neuronx-${version}" ]; then
        echo "Successfully extracted Neuron driver source to usr/src/aws-neuronx-${version}"
        return 0
    else
        echo "Error: Expected directory usr/src/aws-neuronx-${version} not found after extraction"
        return 1
    fi
}

# Function to build kernel module for a specific OCP version
build_kernel_module_for_version() {
    local version="$1"
    local dtk_image="$2"
    
    echo "Processing OCP version: ${version}"
    
    # Get the image ID of the DTK image for later cleanup - using a more reliable method
    DTK_IMAGE_ID=$(podman inspect --format '{{.Id}}' "${dtk_image}" 2>/dev/null || podman images --format "{{.ID}}" --filter "reference=${dtk_image}")
    echo "DTK Image ID: ${DTK_IMAGE_ID}"
    
    # Extract kernel version from DTK container
    if ! KERNEL_VERSION=$(extract_kernel_version_from_dtk "${dtk_image}"); then
        echo "Error: Failed to extract kernel version from DTK image"
        return 1
    fi
    
    echo "Detected kernel version: ${KERNEL_VERSION}"
    
    # Build kernel module
    echo "Building kernel module for kernel ${KERNEL_VERSION}..."
    podman run --rm \
        -v "${TEMP_DIR}/usr/src/aws-neuronx-${NEURON_DRIVER_VERSION}:/aws-neuron-driver:Z" \
        -v "${TEMP_DIR}/build-module.sh:/build-module.sh:Z" \
        -v "${OUTPUT_DIR}:/output:Z" \
        "${dtk_image}" \
        /build-module.sh "${NEURON_DRIVER_VERSION}" "${KERNEL_VERSION}"
    
    # Check if build was successful
    if [ ! -f "${OUTPUT_DIR}/neuron.ko" ]; then
        echo "Error: Failed to build neuron.ko"
        return 1
    fi
    
    # Return success - kernel version and DTK_IMAGE_ID are set as global variables
    return 0
}

# Configuration
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 DRIVER_VERSION [OCP_VERSION]"
    echo "Build and push kernel module container images for AWS Neuron"
    echo ""
    echo "Arguments:"
    echo "  DRIVER_VERSION    Neuron driver version (e.g., v2.16.7.0)"
    echo "  OCP_VERSION      Optional: OpenShift version (e.g., 4.16 or 4.16.2)"
    echo ""
    echo "Environment variables:"
    echo "  FORCE_BUILD       Set to 'true' to force rebuilding images even if they already exist"
    exit 1
fi

NEURON_DRIVER_VERSION="$1"
OCP_VERSION="${2:-}"  # Optional parameter

# Check if FORCE_BUILD is set to force rebuilding images even if they exist
FORCE_BUILD="${FORCE_BUILD:-false}"
if [ "${FORCE_BUILD}" = "true" ]; then
    echo "FORCE_BUILD is set to true, will rebuild images even if they already exist"
fi

# AWS/ECR setup (skip in GitHub Actions)
if ! is_github_actions; then
    echo "Setting up AWS/ECR environment for local development..."
    
    # Check if required environment variables are set
    if [ -z "${KMOD_ECR_REPOSITORY_NAME:-}" ]; then
        # Use default repository name if not set
        KMOD_ECR_REPOSITORY_NAME="neuron-operator/kmod"
        echo "Using default repository name: ${KMOD_ECR_REPOSITORY_NAME}"
    fi
    
    # Set DTK repository name with default value
    if [ -z "${DTK_ECR_REPOSITORY_NAME:-}" ]; then
        DTK_ECR_REPOSITORY_NAME="neuron-operator/driver-toolkit"
        echo "DTK_ECR_REPOSITORY_NAME not set, using default: ${DTK_ECR_REPOSITORY_NAME}"
    fi
    
    if [ -z "${AWS_REGION:-}" ]; then
        AWS_REGION=$(aws configure get region || echo "")
        if [ -z "${AWS_REGION}" ]; then
            echo "Error: AWS_REGION is not set and couldn't be retrieved from AWS configuration"
            echo "Please either:"
            echo "  - Set AWS_REGION environment variable"
            echo "  - Configure a default region with 'aws configure'"
            echo "  - Or specify a region in your AWS profile"
            exit 1
        fi
    fi
    echo "Using AWS Region: ${AWS_REGION}"
    
    # AWS credentials handling
    # If AWS_PROFILE is set, use it
    if [ -n "${AWS_PROFILE:-}" ]; then
        echo "Using AWS profile: ${AWS_PROFILE}"
        validate_aws_credentials
    # Otherwise, check for explicit environment variables
    elif [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "Using AWS credentials from environment variables"
        if ! validate_aws_credentials; then
            echo "Failed to validate AWS credentials. Please check your AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
            exit 1
        fi
        echo "AWS credentials validated successfully"
    # Finally, try default profile
    else
        echo "Using default AWS profile"
        if ! validate_aws_credentials; then
            echo "Failed to validate AWS credentials. Please configure AWS CLI or provide credentials"
            exit 1
        fi
        echo "AWS credentials validated successfully"
    fi
    
    # Get AWS account ID and region
    if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager)
    fi
    
    # ECR registry URL
    ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    
    # Authenticate with ECR
    echo "Logging into ECR..."
    aws ecr get-login-password --region "${AWS_REGION}" --no-cli-pager | \
        podman login --username AWS --password-stdin "${ECR_REGISTRY}"
    
    # Check if repository exists (suppress output)
    if ! aws ecr describe-repositories --repository-names "${KMOD_ECR_REPOSITORY_NAME}" --no-cli-pager >/dev/null 2>&1; then
        echo "Error: ECR repository ${KMOD_ECR_REPOSITORY_NAME} does not exist in ${AWS_REGION}"
        echo "Please create the repository before running this script"
        exit 1
    fi
else
    echo "Running in GitHub Actions, skipping AWS/ECR setup"
    
    # Authenticate with Quay.io for DTK images (required in GitHub Actions)
    if [ -n "${QUAY_USERNAME:-}" ] && [ -n "${QUAY_PASSWORD:-}" ]; then
        echo "Logging into Quay.io..."
        set +x
        echo "${QUAY_PASSWORD}" | podman login quay.io -u "${QUAY_USERNAME}" --password-stdin
        set -x
    else
        echo "Error: QUAY_USERNAME and QUAY_PASSWORD environment variables are required in GitHub Actions"
        echo "These credentials are needed to pull DTK images from quay.io"
        exit 1
    fi
    
    # Authenticate with ECR Public for pushing images (required in GitHub Actions)
    # Note: ECR Public only operates in us-east-1 region
    echo "Logging into ECR Public..."
    if ! aws ecr-public get-login-password --region us-east-1 --no-cli-pager | \
        podman login --username AWS --password-stdin public.ecr.aws; then
        echo "Error: Failed to authenticate with ECR Public"
        exit 1
    fi
fi

# Store the original script directory before changing directories
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Download and extract Neuron driver source from RPM
echo "Downloading AWS Neuron driver source..."
TEMP_DIR=$(mktemp -d)

if ! download_neuron_driver_source "${NEURON_DRIVER_VERSION}" "${TEMP_DIR}"; then
    echo "Failed to download Neuron driver source"
    rm -rf "${TEMP_DIR}"
    exit 1
fi

# Create output directory for all builds
OUTPUT_DIR="${TEMP_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

# Copy build script to temp directory
cp "${SCRIPT_DIR}/container/build-module.sh" "${TEMP_DIR}/"
chmod +x "${TEMP_DIR}/build-module.sh"



# Get OCP versions to build for this driver from build-matrix.json
echo "Getting OCP versions for driver ${NEURON_DRIVER_VERSION} from build-matrix.json..."
OCP_VERSIONS_TO_BUILD=$(jq -r --arg driver "${NEURON_DRIVER_VERSION}" '.[] | select(.driver == $driver) | .ocp_versions[]' "${SCRIPT_DIR}/build-matrix.json")

if [ -z "${OCP_VERSIONS_TO_BUILD}" ]; then
    echo "No OCP versions found for driver ${NEURON_DRIVER_VERSION} in build-matrix.json"
    exit 1
fi

echo "OCP versions to build: $(echo "${OCP_VERSIONS_TO_BUILD}" | tr '\n' ' ')"

# Collect unique kernel versions and track OCP mappings
echo "Collecting kernel versions from OCP versions..."
declare -A KERNEL_TO_OCPS  # Maps kernel version to list of OCP versions

# First pass: collect all kernel versions and their OCP mappings
for ocp_major in ${OCP_VERSIONS_TO_BUILD}; do
    echo "Scanning OCP major version: ${ocp_major}"
    
    while IFS= read -r entry; do
        version=$(echo "$entry" | jq -r '.version')
        
        # Check if this OCP version matches the major version pattern
        if ! [[ "$version" =~ ^${ocp_major}\.[0-9]+$ ]]; then
            continue
        fi
        
        # Skip if OCP_VERSION is set and version doesn't match the filter
        if [ -n "${OCP_VERSION}" ] && ! version_matches "$version" "$OCP_VERSION"; then
            continue
        fi
        
        # Get DTK image and extract kernel version
        dtk_image=$(echo "$entry" | jq -r '.dtk')
        
        if KERNEL_VERSION=$(extract_kernel_version_from_dtk "${dtk_image}"); then
            echo "OCP ${version} uses kernel ${KERNEL_VERSION}"
            
            # Add to kernel-to-OCP mapping
            if [ -n "${KERNEL_TO_OCPS[${KERNEL_VERSION}]:-}" ]; then
                KERNEL_TO_OCPS[${KERNEL_VERSION}]="${KERNEL_TO_OCPS[${KERNEL_VERSION}]}, ${version}"
            else
                KERNEL_TO_OCPS[${KERNEL_VERSION}]="${version}"
            fi
        else
            echo "Warning: Could not extract kernel version for OCP ${version}, skipping"
        fi
    done < <(jq -c '.[]' "${SCRIPT_DIR}/driver-toolkit/driver-toolkit.json")
done

# Second pass: build unique kernel images
echo "Building unique kernel images..."
for KERNEL_VERSION in "${!KERNEL_TO_OCPS[@]}"; do
    echo "Processing kernel version: ${KERNEL_VERSION}"
    echo "Compatible OCP versions: ${KERNEL_TO_OCPS[${KERNEL_VERSION}]}"
    
    # Define kernel-only tag
    KERNEL_TAG="${NEURON_DRIVER_VERSION}-${KERNEL_VERSION}"
    
    if is_github_actions; then
        ECR_IMAGE_BASE="public.ecr.aws/q5p6u7h8/neuron-openshift/neuron-kernel-module"
    else
        ECR_IMAGE_BASE="${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}"
    fi
    
    # Check if kernel image already exists
    if [ "${FORCE_BUILD}" != "true" ] && podman pull "${ECR_IMAGE_BASE}:${KERNEL_TAG}" >/dev/null 2>&1; then
        echo "Kernel image already exists: ${KERNEL_TAG}, skipping build..."
        podman rmi "${ECR_IMAGE_BASE}:${KERNEL_TAG}" >/dev/null 2>&1 || true
        
        # Store for release notes
        if is_github_actions; then
            echo "${KERNEL_VERSION}|${KERNEL_TO_OCPS[${KERNEL_VERSION}]}" >> "${TEMP_DIR}/kernel_mappings.txt"
        fi
        continue
    fi
    
    # Find any OCP version that uses this kernel for building
    SAMPLE_OCP=$(echo "${KERNEL_TO_OCPS[${KERNEL_VERSION}]}" | cut -d',' -f1 | xargs)
    
    # Get DTK image for this kernel version
    dtk_image=$(jq -r --arg version "${SAMPLE_OCP}" '.[] | select(.version == $version) | .dtk' "${SCRIPT_DIR}/driver-toolkit/driver-toolkit.json")
    
    if [ -z "${dtk_image}" ] || [ "${dtk_image}" = "null" ]; then
        echo "Error: Could not find DTK image for OCP ${SAMPLE_OCP}"
        continue
    fi
    
    if is_github_actions; then
        echo "GitHub Actions: Building kernel image ${KERNEL_TAG}"
        
        # Build kernel module for this kernel version
        set +e
        build_kernel_module_for_version "${SAMPLE_OCP}" "${dtk_image}"
        build_result=$?
        set -e
        
        if [ $build_result -ne 0 ]; then
            echo "Build failed for kernel ${KERNEL_VERSION}, exiting..."
            exit $build_result
        fi
        
        # Store kernel mapping for release notes
        echo "${KERNEL_VERSION}|${KERNEL_TO_OCPS[${KERNEL_VERSION}]}" >> "${TEMP_DIR}/kernel_mappings.txt"
        
        # Build final image with kernel-only tag
        echo "Building final image with tag: ${KERNEL_TAG}"
        podman build \
            --platform=linux/amd64 \
            --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
            --label "org.opencontainers.image.version=${NEURON_DRIVER_VERSION}" \
            --label "org.opencontainers.image.source=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws" \
            --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --label "neuron-driver-version=${NEURON_DRIVER_VERSION}" \
            --label "kernel-version=${KERNEL_VERSION}" \
            --label "busybox.version=1.36.1" \
            --label "busybox.source=https://github.com/mirror/busybox/archive/refs/tags/1_36_1.tar.gz" \
            --label "busybox.source.backup=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws/releases/download/neuron-driver-${NEURON_DRIVER_VERSION}/busybox-1.36.1.tar.gz" \
            --label "busybox.license=GPL-2.0" \
            --label "busybox.copyright=BusyBox is copyrighted by many authors between 1998-2015" \
            --label "neuron-driver.source=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws/releases/download/neuron-driver-${NEURON_DRIVER_VERSION}/aws-neuronx-dkms-${NEURON_DRIVER_VERSION}-modified-source.tar.gz" \
            --label "neuron-driver.license=GPL-2.0" \
            --label "neuron-driver.copyright=Copyright Amazon.com, Inc. or its affiliates" \
            -f "${SCRIPT_DIR}/container/Containerfile" \
            -t "${ECR_IMAGE_BASE}:${KERNEL_TAG}" \
            --iidfile "${TEMP_DIR}/image.id" \
            "${OUTPUT_DIR}"
        
        # Push kernel image to ECR Public
        echo "Pushing kernel image to ECR Public..."
        podman push "${ECR_IMAGE_BASE}:${KERNEL_TAG}"
        
        # Clean up the built image
        echo "Cleaning up built image..."
        IMAGE_ID=$(cat "${TEMP_DIR}/image.id")
        podman rmi "${ECR_IMAGE_BASE}:${KERNEL_TAG}" || true
        podman rmi "${IMAGE_ID}" || true
        
        echo "Build completed successfully for kernel ${KERNEL_VERSION}"
        
    else
        echo "Local/Dev: Building kernel image ${KERNEL_TAG}"
        
        # Get DTK image from ECR (use first OCP version that has this kernel)
        dtk_image="${ECR_REGISTRY}/${DTK_ECR_REPOSITORY_NAME}:${SAMPLE_OCP}"
        
        # Build kernel module for this kernel version
        set +e
        build_kernel_module_for_version "${SAMPLE_OCP}" "${dtk_image}"
        build_result=$?
        set -e
        
        if [ $build_result -ne 0 ]; then
            echo "Build failed for kernel ${KERNEL_VERSION}, exiting..."
            exit $build_result
        fi
        
        # Build final image with kernel-only tag
        echo "Building final image with tag: ${KERNEL_TAG}"
        podman build \
            --platform=linux/amd64 \
            --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
            --label "org.opencontainers.image.version=${NEURON_DRIVER_VERSION}" \
            --label "org.opencontainers.image.source=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws" \
            --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --label "neuron-driver-version=${NEURON_DRIVER_VERSION}" \
            --label "kernel-version=${KERNEL_VERSION}" \
            --label "busybox.version=1.36.1" \
            --label "busybox.source=https://github.com/mirror/busybox/archive/refs/tags/1_36_1.tar.gz" \
            --label "busybox.source.backup=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws/releases/download/neuron-driver-${NEURON_DRIVER_VERSION}/busybox-1.36.1.tar.gz" \
            --label "busybox.license=GPL-2.0" \
            --label "busybox.copyright=BusyBox is copyrighted by many authors between 1998-2015" \
            --label "neuron-driver.source=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws/releases/download/neuron-driver-${NEURON_DRIVER_VERSION}/aws-neuronx-dkms-${NEURON_DRIVER_VERSION}-modified-source.tar.gz" \
            --label "neuron-driver.license=GPL-2.0" \
            --label "neuron-driver.copyright=Copyright Amazon.com, Inc. or its affiliates" \
            -f "${SCRIPT_DIR}/container/Containerfile" \
            -t "${ECR_IMAGE_BASE}:${KERNEL_TAG}" \
            --iidfile "${TEMP_DIR}/image.id" \
            "${OUTPUT_DIR}"
        
        # Push kernel image to private ECR
        echo "Pushing kernel image to ECR..."
        podman push "${ECR_IMAGE_BASE}:${KERNEL_TAG}"
        
        # Clean up container images
        echo "Cleaning up container images..."
        IMAGE_ID=$(cat "${TEMP_DIR}/image.id")
        podman rmi "${ECR_IMAGE_BASE}:${KERNEL_TAG}" || true
        podman rmi "${IMAGE_ID}" || true
    fi
    
    # Clean up DTK image
    echo "Cleaning up DTK image..."
    podman rmi "${dtk_image}" || true
    
    # Clean the output directory for the next build
    rm -f "${OUTPUT_DIR}/neuron.ko"
done

# Update GitHub release after all builds complete (GitHub Actions only)
if is_github_actions; then
    echo "Updating GitHub release for Neuron driver version ${NEURON_DRIVER_VERSION}..."
    manage_github_release "${NEURON_DRIVER_VERSION}"
fi

# Final cleanup
echo "Cleaning up temporary directory..."
rm -rf "${TEMP_DIR}"

# Clean up any dangling images (those with <none> as repository and tag)
echo "Cleaning up dangling images..."
cd "${GITHUB_WORKSPACE}" || cd /tmp
DANGLING_IMAGES=$(podman images -f "dangling=true" -q)
if [ -n "${DANGLING_IMAGES}" ]; then
    podman rmi "${DANGLING_IMAGES}" || true
else
    echo "No dangling images found"
fi

echo "All images built and pushed successfully!"