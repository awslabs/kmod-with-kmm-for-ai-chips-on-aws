# Driver Toolkit

## GitHub Actions Integration

The Driver Toolkit utilities are fully integrated with GitHub Actions for automated operations:

### Automated DTK Updates (`update-driver-toolkit.yml`)
- **Schedule**: Runs nightly at 2 AM UTC
- **Function**: Scans for new OpenShift releases and updates `driver-toolkit.json`
- **Smart Updates**: Only creates/updates PRs when actual changes are detected
- **Dependencies**: Automatically installs OpenShift CLI and required tools
- **Output**: Uses `OUTPUT_FILE=driver-toolkit.json.new` for staging updates

### Build Integration (`build-kmod-kmm-images.yml`)
- **Trigger**: Uses updated `driver-toolkit.json` to determine available OCP versions
- **Authentication**: Requires `QUAY_USERNAME` and `QUAY_PASSWORD` secrets
- **Matrix Builds**: Processes multiple driver versions and OCP combinations

## Authentication for Quay.io Repository

The Driver Toolkit images are hosted in a private Quay.io repository that is only accessible to Red Hat OpenShift customers. To access these images, you'll need to:

1. Obtain a pull secret from the Red Hat OpenShift Console:
   - Visit https://cloud.redhat.com/openshift/install/pull-secret
   - Log in with your Red Hat account
   - Download the pull secret file

2. Configure your container tool (podman/docker) to use the pull secret:
   ```bash
   # For podman
   mkdir -p ~/.config/containers/
   cp /path/to/pull-secret.json ~/.config/containers/auth.json
   
   # For docker
   mkdir -p ~/.docker
   cp /path/to/pull-secret.json ~/.docker/config.json
   ```

3. Alternatively, you can use the pull secret via environment variables:
   ```bash
   # Standard Podman environment variable
   export REGISTRY_AUTH_FILE=/path/to/pull-secret.json
   
   # Custom environment variable used by dtk-sync-to-ecr.sh script
   export QUAY_AUTH_FILE=/path/to/pull-secret.json
   ```
   
   Note: The `dtk-sync-to-ecr.sh` script specifically requires the `QUAY_AUTH_FILE`
   environment variable to be set, pointing to your Quay.io authentication file.

Without this authentication, you will not be able to access the Driver Toolkit images from Quay.io.

## driver-toolkit.sh

This script gathers and catalogs OpenShift Driver Toolkit information across OpenShift versions 4.16-4.19, with enhanced GitHub Actions integration.

### Functionality

1. **Dependency Checking**: Validates required tools (curl, jq, OpenShift CLI)
2. **Release Scanning**: Queries Quay.io for OpenShift release tags with pagination
3. **DTK Extraction**: Uses `oc adm release info` to extract driver-toolkit images
4. **JSON Generation**: Creates structured records with version, architecture, and DTK image details
5. **Smart Output**: Generates sorted `driver-toolkit.json` with version-based ordering

### Environment Detection

**GitHub Actions Mode** (detected via `CI=true`):
- Uses `OUTPUT_FILE` environment variable for custom output paths
- Optimized for automated workflows
- Enhanced error handling for CI environments

**Local Development Mode**:
- Standard output to `driver-toolkit.json`
- Interactive progress display
- Detailed error messages with installation instructions

### Usage

**Local Development:**
```bash
chmod +x driver-toolkit.sh
./driver-toolkit.sh
```

**GitHub Actions:**
```bash
# Automatically configured in workflow
env:
  CI: true
  OUTPUT_FILE: driver-toolkit.json.new
run: ./driver-toolkit.sh
```

### Requirements

- OpenShift CLI (oc) - automatically installed in GitHub Actions
- jq (JSON processor)
- curl
- Network access to Quay.io and OpenShift release APIs

### Output Format

Generates `driver-toolkit.json` with entries like:
```json
[
  {
    "version": "4.16.0",
    "arch": "x86_64",
    "dtk": "quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:..."
  }
]
```

This data drives both automated builds and manual development workflows.

## dtk-sync-to-ecr.sh

Syncs Driver Toolkit images from Quay.io to a private AWS ECR repository for local development environments.

**Note**: This utility is primarily for local/development use. GitHub Actions workflows use DTK images directly from Quay.io.

### Prerequisites

- AWS CLI configured with ECR permissions
- Podman installed
- jq installed
- Quay.io authentication (see Authentication section above)

### Usage

```bash
# Use default repository (neuron-operator/driver-toolkit)
./dtk-sync-to-ecr.sh

# Custom repository name
export DTK_ECR_REPOSITORY_NAME="your-dtk-repository-name"
./dtk-sync-to-ecr.sh
```

### Authentication Methods

**AWS Authentication:**
1. **Named Profile**: `export AWS_PROFILE="profile-name"`
2. **Environment Variables**: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
3. **Default Profile**: Uses `~/.aws/config`
4. **GitHub Actions**: Automatic OIDC detection

**Quay.io Authentication** (required):
- Set `QUAY_AUTH_FILE` pointing to your Red Hat pull secret
- Or configure `~/.config/containers/auth.json`

### Integration with Build Workflow

When using local ECR repositories:
1. Run `dtk-sync-to-ecr.sh` to populate your ECR with DTK images
2. Use `build-kmod-kmm.sh` with ECR repository names
3. Images are pulled from your private ECR instead of Quay.io

This provides air-gapped or controlled access to DTK images for enterprise environments.