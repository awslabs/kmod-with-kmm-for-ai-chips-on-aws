## Kmod with KMM for AI Chips on AWS

This repository provides **automated GitHub Actions workflows** and scripts to build 
[Kernel Module Management (KMM) operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/specialized_hardware_and_driver_enablement/kernel-module-management-operator) 
compatible container images with the Kmod for AI Chips on AWS.

It leverages the 
[Driver Toolkit](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/specialized_hardware_and_driver_enablement/driver-toolkit#about-driver-toolkit_driver-toolkit) 
and sources of the 
[AWS Neuron Driver](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/release-notes/runtime/aws-neuronx-dkms/index.html).

**Primary Use Case**: Automated builds via GitHub Actions with nightly Driver Toolkit updates and on-demand image builds published to GitHub Container Registry (GHCR).

## Project Structure

```
project_root/
├── .github/workflows/          # GitHub Actions automation
│   ├── build-kmod-kmm-images.yml    # Automated image builds
│   └── update-driver-toolkit.yml    # Nightly DTK updates
├── build-matrix.json           # Build configuration matrix
├── build-kmod-kmm.sh           # Main build script
├── container/                  # Container-related files
│   ├── Containerfile           # Container definition
│   └── build-module.sh         # Script used inside the container
├── driver-toolkit/             # Driver toolkit resources
│   ├── driver-toolkit.json     # DTK image references
│   ├── driver-toolkit.sh       # DTK utility script
│   ├── dtk-sync-to-ecr.sh      # Script to sync DTK images to ECR
│   └── README.md               # DTK documentation
└── scripts/                    # Additional utility scripts
    └── export-csv-kmod-images-ecr.sh
```

For more information about the Driver Toolkit utilities, see [driver-toolkit/README.md](driver-toolkit/README.md) which provides details on:
- `driver-toolkit.sh`: A script that gathers and catalogs OpenShift driver toolkit information across different versions
- `dtk-sync-to-ecr.sh`: A utility to sync Driver Toolkit images from Quay.io to a private AWS ECR repository

## GitHub Actions Automation (Primary Use Case)

### Automated Driver Toolkit Updates
- **Workflow**: `.github/workflows/update-driver-toolkit.yml`
- **Schedule**: Nightly at 2 AM UTC
- **Function**: Automatically scans for new OpenShift releases and updates `driver-toolkit/driver-toolkit.json`
- **Output**: Creates or updates pull requests with latest DTK mappings
- **Requirements**: No secrets needed (read-only operations)

### Automated Image Builds and Releases
- **Workflow**: `.github/workflows/build-kmod-kmm-images.yml`
- **Triggers**: 
  - Push to main branch (when `build-matrix.json` or `driver-toolkit.json` changes)
  - Manual workflow dispatch
- **Configuration**: Uses `build-matrix.json` to define driver versions and OCP targets
- **Required Secrets**:
  - `QUAY_USERNAME` and `QUAY_PASSWORD`: For accessing private DTK images on Quay.io
  - `GITHUB_TOKEN`: Automatically provided for GHCR publishing and release management

### Complete Build and Release Workflow
1. **Downloads** AWS Neuron driver source from RPM packages
2. **Builds** kernel modules using DTK containers for each OCP version
3. **Creates** container images with dual tagging:
   - Kernel-specific: `{DRIVER_VERSION}-{KERNEL_VERSION}`
   - OCP-specific: `{DRIVER_VERSION}-ocp{OCP_VERSION}`
4. **Publishes** images to GitHub Container Registry (GHCR)
5. **Manages** GitHub releases with complete image catalogs and usage instructions
6. **Updates** existing releases when new OCP versions are added

### Container Images
- **Registry**: `ghcr.io/awslabs/kmod-with-kmm-for-ai-chips-on-aws/neuron-driver`
- **Public Access**: No authentication required for pulling images
- **Automated Releases**: Each driver version gets a GitHub release with usage documentation

## Prerequisites

### For GitHub Actions (Automated)
- Repository secrets configured:
  - `QUAY_USERNAME`: Red Hat registry username
  - `QUAY_PASSWORD`: Red Hat registry password
- Valid `build-matrix.json` configuration

### For Local Development
- AWS CLI with ECR permissions
- Podman installed
- Red Hat OpenShift pull secret (for DTK access)
- jq and standard build tools

## Configuration

### build-matrix.json
Defines which driver versions and OCP versions to build:
```json
[
  {
    "driver": "2.22.2.0",
    "ocp_versions": ["4.16", "4.17", "4.18", "4.19"]
  }
]
```

### driver-toolkit/driver-toolkit.json
Auto-generated mapping of OCP versions to DTK images. Updated nightly via GitHub Actions.

## Manual Usage (Development/Local Environments)

The project maintains full backward compatibility for local development and custom ECR deployments.

### Manual Script Usage (build-kmod-kmm.sh)

The `build-kmod-kmm.sh` script supports both GitHub Actions automation and local development. It automatically detects the environment and adapts its behavior.

#### Prerequisites for Local Development

- AWS CLI configured with appropriate permissions (for ECR)
- Podman installed
- jq installed
- An existing ECR repository
- Quay.io authentication (for DTK images)

#### Environment Variables

**Local/ECR Mode:**
- `DTK_ECR_REPOSITORY_NAME`: ECR repository for DTK images (default: "neuron-operator/driver-toolkit")
- `KMOD_ECR_REPOSITORY_NAME`: ECR repository for built modules (default: "neuron-operator/kmod")
- `AWS_REGION`: AWS region for ECR
- `AWS_ACCOUNT_ID`: AWS account ID (auto-detected if not specified)
- `AWS_PROFILE`: AWS profile to use
- `FORCE_BUILD`: Set to "true" to force rebuilding existing images

**GitHub Actions Mode (automatically detected):**
- `QUAY_USERNAME` and `QUAY_PASSWORD`: For DTK image access
- `GITHUB_TOKEN`: For GHCR publishing and release management

#### Command Line Arguments

```
Usage: ./build-kmod-kmm.sh DRIVER_VERSION [OCP_VERSION]

Arguments:
  DRIVER_VERSION    Neuron driver version (e.g., 2.16.7.0)
  OCP_VERSION       Optional: OpenShift version (e.g., 4.16 or 4.16.2)
```

#### Examples

**Local Development (ECR):**
```bash
# Build for all OCP versions, push to ECR
./build-kmod-kmm.sh 2.16.7.0

# Build for specific OCP version
./build-kmod-kmm.sh 2.16.7.0 4.16.2

# Use custom ECR repositories
export KMOD_ECR_REPOSITORY_NAME=my-kmod-repo
./build-kmod-kmm.sh 2.16.7.0

# Force rebuild existing images
FORCE_BUILD=true ./build-kmod-kmm.sh 2.16.7.0
```

**GitHub Actions (GHCR):**
```bash
# Automatically detected environment
# Publishes to ghcr.io/awslabs/kmod-with-kmm-for-ai-chips-on-aws/neuron-driver
# Creates/updates GitHub releases
./build-kmod-kmm.sh 2.16.7.0
```

#### Image Tags

**Local/ECR Mode:**
- Base tag: `neuron-driver${DRIVER_VERSION}-ocp${OCP_VERSION}`
- Full tag: `neuron-driver${DRIVER_VERSION}-ocp${OCP_VERSION}-kernel${KERNEL_VERSION}`

**GitHub Actions/GHCR Mode:**
- Kernel-specific: `${DRIVER_VERSION}-${KERNEL_VERSION}`
- OCP-specific: `${DRIVER_VERSION}-ocp${OCP_VERSION}`

## Troubleshooting

### Common Issues

**GitHub Actions Build Failures:**
- Verify `QUAY_USERNAME` and `QUAY_PASSWORD` secrets are configured
- Check that `build-matrix.json` contains valid driver versions
- Ensure DTK images are available for specified OCP versions

**Local Build Issues:**
- Confirm AWS credentials and ECR repository access
- Verify Quay.io authentication for DTK image access
- Check that specified driver version exists in Neuron repositories

**Image Compatibility:**
- Use kernel-specific tags for exact kernel matches
- Use OCP-specific tags for broader compatibility within OCP versions

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.
