#!/bin/bash

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
        esac
        exit 1
    fi
}

echo "Setting up error handling..."
set -euo pipefail

# Check for required commands (skip in GitHub Actions where tools are pre-installed)
if ! is_github_actions; then
    echo "Checking required commands..."
    for cmd in aws jq podman; do
        check_command "$cmd"
    done
else
    echo "Running in GitHub Actions, skipping tool checks (tools pre-installed)"
fi

# Function to check if running in GitHub Actions
is_github_actions() {
    [ -n "${GITHUB_ACTIONS:-}" ]
}

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

# Function to check if an image with a specific tag exists in ECR
image_exists_in_ecr() {
    local repository="$1"
    local tag="$2"
    
    aws ecr describe-images \
        --repository-name "${repository}" \
        --image-ids imageTag="${tag}" \
        --no-cli-pager >/dev/null 2>&1
    return $?
}

# Function to check if an image with a specific tag exists in GHCR
image_exists_in_ghcr() {
    local image_name="$1"
    local tag="$2"
    
    podman manifest inspect "ghcr.io/awslabs/kmod-with-kmm-for-ai-chips-on-aws/${image_name}:${tag}" >/dev/null 2>&1
    return $?
}

# Function to build kernel module for a specific OCP version
build_kernel_module_for_version() {
    local version="$1"
    local dtk_image="$2"
    
    echo "Processing OCP version: ${version}"
    
    # Pull the DTK image
    echo "Pulling DTK image: ${dtk_image}"
    podman pull ${dtk_image} >/dev/null
    
    # Get the image ID of the DTK image for later cleanup - using a more reliable method
    DTK_IMAGE_ID=$(podman inspect --format '{{.Id}}' ${dtk_image} 2>/dev/null || podman images --format "{{.ID}}" --filter "reference=${dtk_image}")
    echo "DTK Image ID: ${DTK_IMAGE_ID}"
    
    # Extract kernel version from DTK container
    echo "Extracting kernel version from DTK image..."
    KERNEL_VERSION=$(podman run --rm ${dtk_image} bash -c "awk -F'\"' '/\"KERNEL_VERSION\":/{print \$4}' /etc/driver-toolkit-release.json")
    
    if [ -z "${KERNEL_VERSION}" ]; then
        echo "Error: Failed to extract kernel version from DTK image"
        return 1
    fi
    
    echo "Detected kernel version: ${KERNEL_VERSION}"
    
    # Build kernel module
    echo "Building kernel module for kernel ${KERNEL_VERSION}..."
    podman run --rm \
        -v "${TEMP_DIR}/aws-neuron-driver/src:/aws-neuron-driver:Z" \
        -v "${TEMP_DIR}/build-module.sh:/build-module.sh:Z" \
        -v "${OUTPUT_DIR}:/output:Z" \
        ${dtk_image} \
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
    
    # Authenticate with GHCR for pushing images (required in GitHub Actions)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "Logging into GHCR..."
        set +x
        echo "${GITHUB_TOKEN}" | podman login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin
        set -x
    else
        echo "Error: GITHUB_TOKEN environment variable is required in GitHub Actions"
        echo "This token is needed to push images to ghcr.io"
        exit 1
    fi
fi

# Store the original script directory before changing directories
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Clone repo once outside the loop
echo "Cloning AWS Neuron driver repository..."
TEMP_DIR=$(mktemp -d)
git clone https://github.com/wombelix/aws-neuron-driver.git "${TEMP_DIR}/aws-neuron-driver"
cd "${TEMP_DIR}/aws-neuron-driver"
# Suppress detached HEAD advice
git config --global advice.detachedHead false
git checkout --quiet ${NEURON_DRIVER_VERSION}
cd ${SCRIPT_DIR}

# Create output directory for all builds
OUTPUT_DIR="${TEMP_DIR}/output"
mkdir -p "${OUTPUT_DIR}"

# Copy build script to temp directory
cp "${SCRIPT_DIR}/container/build-module.sh" "${TEMP_DIR}/"
chmod +x "${TEMP_DIR}/build-module.sh"

# Process driver-toolkit.json with environment-specific logic
echo "Processing driver-toolkit.json..."
while IFS= read -r entry; do
    version=$(echo "$entry" | jq -r '.version')
    
    # Skip if OCP_VERSION is set and version doesn't match the filter
    if [ -n "${OCP_VERSION}" ] && ! version_matches "$version" "$OCP_VERSION"; then
        continue
    fi
    
    if is_github_actions; then
        echo "GitHub Actions: Processing OCP version $version"
        
        # Get DTK image from Quay.io (from JSON entry)
        dtk_image=$(echo "$entry" | jq -r '.dtk')
        
        # Build kernel module for this version
        if ! build_kernel_module_for_version "$version" "$dtk_image"; then
            echo "Build failed for OCP version $version, continuing with next version..."
            continue
        fi
        
        # Create GHCR tag with driver and kernel version
        GHCR_TAG="${NEURON_DRIVER_VERSION}-${KERNEL_VERSION}"
        GHCR_IMAGE="ghcr.io/awslabs/kmod-with-kmm-for-ai-chips-on-aws/neuron-driver:${GHCR_TAG}"
        
        # Check if image already exists in GHCR
        if [ "${FORCE_BUILD}" != "true" ] && image_exists_in_ghcr "neuron-driver" "${GHCR_TAG}"; then
            echo "Image with tag ${GHCR_TAG} already exists in GHCR, skipping build..."
            continue
        fi
        
        # Build final image with GHCR tag and labels
        echo "Building final image with tag: ${GHCR_TAG}"
        podman build \
            --platform=linux/amd64 \
            --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
            --build-arg OCP_VERSION="${version}" \
            --label "org.opencontainers.image.version=${NEURON_DRIVER_VERSION}" \
            --label "org.opencontainers.image.source=https://github.com/awslabs/kmod-with-kmm-for-ai-chips-on-aws" \
            --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --label "neuron-driver-version=${NEURON_DRIVER_VERSION}" \
            --label "kernel-version=${KERNEL_VERSION}" \
            --label "openshift-version=${version}" \
            -f "${SCRIPT_DIR}/container/Containerfile" \
            -t "${GHCR_IMAGE}" \
            --iidfile "${TEMP_DIR}/image.id" \
            "${OUTPUT_DIR}"
        
        # Push image to GHCR
        echo "Pushing image to GHCR..."
        podman push "${GHCR_IMAGE}"
        
        # Clean up the built image
        echo "Cleaning up built image..."
        IMAGE_ID=$(cat "${TEMP_DIR}/image.id")
        podman rmi "${GHCR_IMAGE}" || true
        podman rmi "${IMAGE_ID}" || true
        
        echo "Build completed successfully for OCP version $version"
        
    else
        echo "Local/Dev: Processing OCP version $version"
        
        # Create base tag for this version
        BASE_TAG="neuron-driver${NEURON_DRIVER_VERSION}-ocp${version}"
        
        # Check if image with this tag already exists in ECR
        if [ "${FORCE_BUILD}" != "true" ] && image_exists_in_ecr "${KMOD_ECR_REPOSITORY_NAME}" "${BASE_TAG}"; then
            echo "Image with tag ${BASE_TAG} already exists in ECR, skipping build..."
            continue
        fi
        
        # Get DTK image from ECR
        dtk_image="${ECR_REGISTRY}/${DTK_ECR_REPOSITORY_NAME}:${version}"
        
        # Build kernel module for this version
        if ! build_kernel_module_for_version "$version" "$dtk_image"; then
            echo "Build failed for OCP version $version, continuing with next version..."
            continue
        fi
        
        # Create full tag with kernel version information
        FULL_TAG="${BASE_TAG}-kernel${KERNEL_VERSION}"
        
        # Build final image
        echo "Building final image with tag: ${FULL_TAG}"
        podman build \
            --platform=linux/amd64 \
            --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
            --build-arg OCP_VERSION="${version}" \
            -f "${SCRIPT_DIR}/container/Containerfile" \
            -t "${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}:${FULL_TAG}" \
            --iidfile "${TEMP_DIR}/image.id" \
            "${OUTPUT_DIR}"
        
        # Add the base tag as well
        IMAGE_ID=$(cat "${TEMP_DIR}/image.id")
        podman tag "${IMAGE_ID}" "${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}:${BASE_TAG}"
        
        # Push images
        echo "Pushing images to ECR..."
        podman push "${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}:${FULL_TAG}"
        podman push "${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}:${BASE_TAG}"
        
        # Clean up this version's container images
        echo "Cleaning up container images..."
        # First remove the tags
        podman rmi "${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}:${FULL_TAG}" || true
        podman rmi "${ECR_REGISTRY}/${KMOD_ECR_REPOSITORY_NAME}:${BASE_TAG}" || true
        # Then remove the image by ID to ensure complete removal
        podman rmi "${IMAGE_ID}" || true
    fi
    
    # Common cleanup for both environments
    echo "Cleaning up DTK image..."
    podman rmi "${dtk_image}" || true
    if [ -n "${DTK_IMAGE_ID}" ]; then
        podman rmi "${DTK_IMAGE_ID}" || true
    fi
    
    # Clean the output directory for the next build
    rm -f "${OUTPUT_DIR}/neuron.ko"
    
done < <(jq -c '.[]' "${SCRIPT_DIR}/driver-toolkit/driver-toolkit.json")

# Final cleanup
echo "Cleaning up temporary directory..."
rm -rf "${TEMP_DIR}"

# Clean up any dangling images (those with <none> as repository and tag)
echo "Cleaning up dangling images..."
DANGLING_IMAGES=$(podman images -f "dangling=true" -q)
if [ -n "${DANGLING_IMAGES}" ]; then
    podman rmi ${DANGLING_IMAGES} || true
else
    echo "No dangling images found"
fi

echo "All images built and pushed successfully!"