# Driver Toolkit

## driver-toolkit.sh

This script is designed to gather and catalog OpenShift driver toolkit information across 
different OpenShift versions (specifically versions 4.16 through 4.19). Here's what it does:

1. First, it checks for required dependencies (curl, jq, and the OpenShift CLI 'oc')

2. The script then:

- Queries the Quay.io repository for OpenShift release tags
- For each version found, it extracts the driver-toolkit image information
- Creates a JSON record containing version, architecture, and driver toolkit image details
- Stores all this information in a structured format

3. Finally, it generates a sorted JSON file called `driver-toolkit.json` 
   that contains all the collected information

To use the script:

```bash
# Make it executable
chmod +x driver-toolkit.sh

# Run it
./driver-toolkit.sh
```

The script requires:

- OpenShift CLI (oc) to be installed and configured
- jq (JSON processor)
- curl

The output will be a file named `driver-toolkit.json` containing a sorted list of 
driver toolkit images corresponding to different OpenShift versions, which can be 
useful for managing driver compatibility across OpenShift clusters.

This is particularly useful for administrators or developers working with OpenShift 
who need to track or manage driver toolkit images across different versions of the platform.

## dtk-sync-to-ecr.sh

Syncs Driver Toolkit images from Quay.io to a private AWS ECR repository.

### Prerequisites

- AWS CLI configured
- Podman installed
- jq installed
- Appropriate ECR permissions

### Usage

Configuration options:

```bash
# Use default repository name (neuron-operator/driver-toolkit)
./dtk-sync-to-ecr.sh

# Or specify a custom repository name
export DTK_ECR_REPOSITORY_NAME="your-dtk-repository-name"
./dtk-sync-to-ecr.sh
```

### Authentication Methods

The script supports multiple authentication methods:

1. Named AWS Profile

```bash
export AWS_PROFILE="your-profile-name"
# DTK_ECR_REPOSITORY_NAME is optional, defaults to neuron-operator/driver-toolkit
./dtk-sync-to-ecr.sh
```

2. Environment Variables


```bash
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
# Optional: Override region from AWS config
export AWS_REGION="your-region"
# Optional: Override default repository name
export DTK_ECR_REPOSITORY_NAME="your-dtk-repository-name"
./dtk-sync-to-ecr.sh
```

3. Default AWS Profile

```bash
# Uses credentials and region from ~/.aws/config
# Uses default repository name (neuron-operator/driver-toolkit)
./dtk-sync-to-ecr.sh
```

The script will automatically detect GitHub Actions OIDC authentication when running in workflows.