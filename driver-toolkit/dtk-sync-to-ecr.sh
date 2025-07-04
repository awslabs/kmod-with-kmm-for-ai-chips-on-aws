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

# Add this check near the top with other environment variable checks
if [ -z "${QUAY_AUTH_FILE:-}" ]; then
    echo "Please set QUAY_AUTH_FILE environment variable pointing to your Quay.io authentication file"
    exit 1
fi

# Verify the auth file exists
if [ ! -f "${QUAY_AUTH_FILE}" ]; then
    echo "Error: Auth file ${QUAY_AUTH_FILE} does not exist"
    exit 1
fi

# Check if required environment variables are set
if [ -z "${DTK_ECR_REPOSITORY_NAME:-}" ]; then
    # Use default repository name if not set
    DTK_ECR_REPOSITORY_NAME="neuron-operator/driver-toolkit"
    echo "Using default repository name: ${DTK_ECR_REPOSITORY_NAME}"
fi

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
aws ecr get-login-password --region "${AWS_REGION}" --no-cli-pager | podman login --username AWS --password-stdin "${ECR_REGISTRY}"

# Check if repository exists (suppress output)
if ! aws ecr describe-repositories --repository-names "${DTK_ECR_REPOSITORY_NAME}" --no-cli-pager >/dev/null 2>&1; then
    echo "Error: ECR repository ${DTK_ECR_REPOSITORY_NAME} does not exist in ${AWS_REGION}"
    echo "Please create the repository before running this script"
    exit 1
fi

# Output to which ECR repository and region we going to upload the dtk images
echo "Syncing to ECR repository ${DTK_ECR_REPOSITORY_NAME} in region ${AWS_REGION}"

# Read and process the JSON file
jq -c '.[]' driver-toolkit.json | while read -r item; do
    dtk_image=$(echo "${item}" | jq -r '.dtk')
    version=$(echo "${item}" | jq -r '.version')
    
    # Extract SHA from the image
    sha=$(echo "${dtk_image}" | cut -d@ -f2)
    
    # Check if image with this SHA already exists in ECR
    if ! aws ecr describe-images \
        --repository-name "${DTK_ECR_REPOSITORY_NAME}" \
        --image-ids imageTag="${version}" \
        --no-cli-pager >/dev/null 2>&1; then
        
        echo "Pulling image ${dtk_image} ..."
        if ! podman pull --authfile "${QUAY_AUTH_FILE}" --platform linux/amd64 "${dtk_image}" >/dev/null 2>&1; then
            echo "Error: Failed to pull image ${dtk_image}"
            exit 1
        fi
        
        # Get the image ID of the pulled image for later cleanup
        PULLED_IMAGE_ID=$(podman inspect --format '{{.Id}}' "${dtk_image}" 2>/dev/null || podman images --format "{{.ID}}" --filter "reference=${dtk_image}")
        
        # Tag the image for ECR
        ecr_tag="${ECR_REGISTRY}/${DTK_ECR_REPOSITORY_NAME}:${version}"
        podman tag "${dtk_image}" "${ecr_tag}" >/dev/null 2>&1
        
        # Get the image ID of the tagged image for later cleanup
        TAGGED_IMAGE_ID=$(podman inspect --format '{{.Id}}' "${ecr_tag}" 2>/dev/null || podman images --format "{{.ID}}" --filter "reference=${ecr_tag}")
        
        echo "Pushing image to ECR with tag ${version}..."
        if ! podman push "${ecr_tag}" >/dev/null 2>&1; then
            echo "Error: Failed to push image to ECR"
            podman rmi "${dtk_image}" "${ecr_tag}" >/dev/null 2>&1 || true
            exit 1
        fi

        # Get the new SHA from ECR
        ecr_sha=$(aws ecr describe-images \
            --repository-name "${DTK_ECR_REPOSITORY_NAME}" \
            --image-ids imageTag="${version}" \
            --query 'imageDetails[0].imageDigest' \
            --output text \
            --no-cli-pager)
        
        echo "Successfully synced ${dtk_image} to ECR"
        echo "Original Quay.io SHA: ${sha}"
        echo "New ECR SHA: ${ecr_sha}"
        
        # Cleanup both the original and tagged images
        echo "Cleaning up local images..."
        # First remove by tags
        podman rmi "${dtk_image}" "${ecr_tag}" >/dev/null 2>&1 || true
        
        # Then remove by image IDs to ensure complete removal
        if [ -n "${PULLED_IMAGE_ID}" ]; then
            podman rmi "${PULLED_IMAGE_ID}" >/dev/null 2>&1 || true
        fi
        
        if [ -n "${TAGGED_IMAGE_ID}" ] && [ "${PULLED_IMAGE_ID}" != "${TAGGED_IMAGE_ID}" ]; then
            podman rmi "${TAGGED_IMAGE_ID}" >/dev/null 2>&1 || true
        fi
        
    else
        echo "Image for version ${version} already exists in ECR, skipping..."
    fi

done

# Clean up any dangling images (those with <none> as repository and tag)
echo "Cleaning up dangling images..."
DANGLING_IMAGES=$(podman images -f "dangling=true" -q)
if [ -n "${DANGLING_IMAGES}" ]; then
    podman rmi "${DANGLING_IMAGES}" >/dev/null 2>&1 || true
else
    echo "No dangling images found"
fi

echo "Sync completed"
