#!/bin/bash
set -euo pipefail

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

# Configuration
NEURON_DRIVER_VERSION="$1"  # Pass as first argument
OCP_VERSION="$2"           # Pass as second argument

# Check if required arguments are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 DRIVER_VERSION OCP_VERSION"
    echo "Build and push kernel module container images for AWS Neuron"
    echo ""
    echo "Arguments:"
    echo "  DRIVER_VERSION    Neuron driver version (e.g., v2.16.7.0)"
    echo "  OCP_VERSION      OpenShift version (e.g., 4.14)"
    exit 1
fi

# Check if required environment variables are set
if [ -z "${ECR_REPOSITORY:-}" ]; then
    echo "Please set ECR_REPOSITORY environment variable"
    exit 1
fi

# AWS credentials handling
# If AWS_PROFILE is set, use it
if [ -n "${AWS_PROFILE:-}" ]; then
    echo "Using AWS profile: ${AWS_PROFILE}"
    validate_aws_credentials
# If running in GitHub Actions, assume credentials are handled via OIDC
elif is_github_actions; then
    echo "Running in GitHub Actions, using OIDC credentials"
    validate_aws_credentials
# Otherwise, check for explicit environment variables
elif [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "Using AWS credentials from environment variables"
    validate_aws_credentials
# Finally, try default profile
else
    echo "Using default AWS profile"
    validate_aws_credentials
fi

# Get AWS account ID and region
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager)
fi

if [ -z "${AWS_REGION:-}" ]; then
    AWS_REGION=$(aws configure get region)
    if [ -z "${AWS_REGION}" ]; then
        echo "Please set AWS_REGION environment variable or configure it in your AWS profile"
        exit 1
    fi
fi

# ECR registry URL
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Authenticate with ECR
echo "Logging into ECR..."
aws ecr get-login-password --region "${AWS_REGION}" --no-cli-pager | \
    podman login --username AWS --password-stdin "${ECR_REGISTRY}"

# Check if repository exists (suppress output)
if ! aws ecr describe-repositories --repository-names "${ECR_REPOSITORY}" --no-cli-pager >/dev/null 2>&1; then
    echo "Error: ECR repository ${ECR_REPOSITORY} does not exist in ${AWS_REGION}"
    echo "Please create the repository before running this script"
    exit 1
fi

# Function to build and push image
build_and_push_image() {
    local kernel_version="$1"
    local dtk_image="$2"
    local tag="$3"

    echo "Building image for kernel version: ${kernel_version}"
    echo "Using DTK image: ${dtk_image}"

    # Create temporary file for image ID
    local temp_id_file=$(mktemp)

    # Build the image
    podman build \
        --build-arg NEURON_DRIVER_VERSION="${NEURON_DRIVER_VERSION}" \
        --build-arg DTK_IMAGE="${dtk_image}" \
        --build-arg OCP_VERSION="${OCP_VERSION}" \
        --iidfile "${temp_id_file}" \
        -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${tag}" \
        -f Containerfile .

    # Get the image ID and kernel version from label
    local image_id=$(cat "${temp_id_file}")
    local built_kernel_version=$(podman inspect "${image_id}" --format '{{ index .Labels "kernel-version" }}')
    
    # Additional tag with kernel version
    local kernel_tag="${tag}-${built_kernel_version}"
    podman tag "${image_id}" "${ECR_REGISTRY}/${ECR_REPOSITORY}:${kernel_tag}"

    echo "Pushing images to ECR..."
    if ! podman push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${tag}" >/dev/null 2>&1; then
        echo "Error: Failed to push image to ECR"
        podman rmi "${image_id}" >/dev/null 2>&1 || true
        rm "${temp_id_file}"
        exit 1
    fi

    if ! podman push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${kernel_tag}" >/dev/null 2>&1; then
        echo "Error: Failed to push kernel-tagged image to ECR"
        podman rmi "${image_id}" >/dev/null 2>&1 || true
        rm "${temp_id_file}"
        exit 1
    fi

    # Clean up
    podman rmi "${image_id}" >/dev/null 2>&1 || true
    rm "${temp_id_file}"
}

# Read and process driver-toolkit.json
while IFS= read -r kernel_version; do
    # Extract OCP version from kernel version
    ocp_version=$(echo "$kernel_version" | sed -E 's/.*el([0-9]+)_.*/\1/')
    
    # Construct DTK image URL
    dtk_image="${ECR_REGISTRY}/driver-toolkit:${kernel_version}"
    
    # Create tag using driver version and OCP version
    tag="${NEURON_DRIVER_VERSION}-ocp${OCP_VERSION}"
    
    build_and_push_image "$kernel_version" "$dtk_image" "$tag"
done < <(jq -r '.KERNEL_VERSION' driver-toolkit.json)

echo "All images built and pushed successfully!"
