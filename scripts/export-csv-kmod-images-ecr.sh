#!/bin/bash

# Default values
DEFAULT_REPOSITORY="neuron-operator/kmod"
DEFAULT_REGION="us-east-2"

# Use environment variables if set, otherwise use defaults
REPOSITORY="${ECR_REPOSITORY:-$DEFAULT_REPOSITORY}"
REGION="${AWS_REGION:-$DEFAULT_REGION}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Using Repository: ${REPOSITORY}"
echo "Using Region: ${REGION}"
echo "Fetching image details from ECR..."

echo "base_tag,full_tag,pull_url" > kmod_images_ecr.csv

# Single API call with JQ processing and sorting
aws ecr describe-images \
    --repository-name ${REPOSITORY} \
    --region ${REGION} \
    --output json | \
jq -r '
    .imageDetails[] |
    select(.imageTags != null) |
    .imageTags |
    select(length > 1) |
    . as $tags |
    ($tags[] | select(contains("kernel") | not)) as $base |
    ($tags[] | select(contains("kernel"))) as $full |
    if $base and $full then
        [$base, $full, "\($base)"] | @csv
    else
        empty
    end
' | sort -V | while read -r line; do
    base_tag=$(echo $line | cut -d',' -f3 | tr -d '"')
    echo "${line%,*},\"${REGISTRY}/${REPOSITORY}:${base_tag}\"" >> kmod_images_ecr.csv
    echo "Added: $(echo $line | cut -d',' -f1)"
done

echo "Done! Results written to kmod_images_ecr.csv"
echo "Found $(( $(wc -l < kmod_images_ecr.csv) - 1 )) image pairs"
