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

# Configuration
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 DRIVER_VERSION [OCP_VERSION]"
    echo "Build and push kernel module container images for AWS Neuron"
    echo ""
    echo "Arguments:"
    echo "  DRIVER_VERSION    Neuron driver version (e.g., v2.16.7.0)"
    echo "  OCP_VERSION      Optional: OpenShift version (e.g., 4.16 or 4.16.2)"
    exit 1
fi

NEURON_DRIVER_VERSION="$1"
OCP_VERSION="${2:-}"  # Optional parameter

# Check if required environment variables are set
if [ -z "${ECR_REPOSITORY_NAME:-}" ]; then
    echo "Please set ECR_REPOSITORY_NAME environment variable"
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
if ! aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_NAME}" --no-cli-pager >/dev/null 2>&1; then
    echo "Error: ECR repository ${ECR_REPOSITORY_NAME} does not exist in ${AWS_REGION}"
    echo "Please create the repository before running this script"
    exit 1
fi

# Function to build and push image
build_and_push_image() {
    local ocp_version="$1"
    
    # Construct the DTK image URL from ECR using the same logic as in dtk-sync-to-ecr.sh
    local dtk_ecr_image="${ECR_REGISTRY}/${ECR_REPOSITORY_NAME}:${ocp_version}"
    
    echo "Building image for OCP version: ${ocp_version}"
    echo "Using DTK image from ECR: ${dtk_ecr_image}"

    # Create temporary file for image ID
    local temp_id_file=$(mktemp)

    # Build the image with explicit amd64 platform
    podman build \
        --platform=linux/amd64 \
        --build-arg NEURON_DRIVER_VERSION="${NEURON_DRIVER_VERSION}" \
        --build-arg DTK_IMAGE="${dtk_ecr_image}" \
        --build-arg OCP_VERSION="${ocp_version}" \
        --iidfile "${temp_id_file}" \
        -f Containerfile .

    # Get the image ID and kernel version from label
    local image_id=$(cat "${temp_id_file}")
    local built_kernel_version=$(podman inspect "${image_id}" --format '{{ index .Labels "kernel-version" }}')
    
    # Create the single, complete tag with the final format
    local tag="neuron-driver${NEURON_DRIVER_VERSION}-ocp${ocp_version}-kernel${built_kernel_version}"
    
    # Tag the image
    podman tag "${image_id}" "${ECR_REGISTRY}/${ECR_REPOSITORY}:${tag}"

    echo "Pushing image to ECR..."
    if ! podman push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${tag}" >/dev/null 2>&1; then
        echo "Error: Failed to push image to ECR"
        podman rmi "${image_id}" >/dev/null 2>&1 || true
        rm "${temp_id_file}"
        exit 1
    fi

    # Clean up
    podman rmi "${image_id}" >/dev/null 2>&1 || true
    rm "${temp_id_file}"
}

# Process driver-toolkit.json
echo "Processing driver-toolkit.json..."
while IFS= read -r entry; do
    version=$(echo "$entry" | jq -r '.version')
    
    # Skip if OCP_VERSION is set and version doesn't match the filter
    if [ -n "${OCP_VERSION}" ] && ! version_matches "$version" "$OCP_VERSION"; then
        continue
    fi
    
    build_and_push_image "$version"
done < <(jq -c '.[]' driver-toolkit/driver-toolkit.json)

echo "All images built and pushed successfully!"