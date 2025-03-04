## Kmod with KMM for AI Chips on AWS

This repository contains Scripts and Dockerfiles to build 
[Kernel Module Management (KMM) operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/specialized_hardware_and_driver_enablement/kernel-module-management-operator) 
compatible container images with the Kmod for AI Chips on AWS.

It leverages the 
[Driver Toolkit](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/specialized_hardware_and_driver_enablement/driver-toolkit#about-driver-toolkit_driver-toolkit) 
and sources of the 
[AWS Neuron Driver](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/release-notes/runtime/aws-neuronx-dkms/index.html).

## Project Structure

```
project_root/
├── build-kmod-kmm.sh           # Main build script
├── container/                  # Container-related files
│   ├── Containerfile           # Container definition
│   └── build-module.sh         # Script used inside the container
└── driver-toolkit/             # Driver toolkit resources
    ├── driver-toolkit.json     # DTK image references
    ├── driver-toolkit.sh       # DTK utility script
    ├── dtk-sync-to-ecr.sh      # Script to sync DTK images to ECR
    └── README.md               # DTK documentation
```

For more information about the Driver Toolkit utilities, see [driver-toolkit/README.md](driver-toolkit/README.md) which provides details on:
- `driver-toolkit.sh`: A script that gathers and catalogs OpenShift driver toolkit information across different versions
- `dtk-sync-to-ecr.sh`: A utility to sync Driver Toolkit images from Quay.io to a private AWS ECR repository

## Functionality

This project builds kernel modules for AWS Neuron drivers compatible with OpenShift Container Platform (OCP) using the Driver Toolkit (DTK). The build process:

1. Clones the AWS Neuron driver repository
2. Uses DTK containers to build kernel modules for specific OCP versions
3. Packages the built modules into KMM-compatible container images
4. Pushes the images to Amazon ECR

## Usage of build-kmod-kmm.sh

The `build-kmod-kmm.sh` script automates the process of building and pushing kernel module container images for AWS Neuron drivers.

### Prerequisites

- AWS CLI configured with appropriate permissions
- Podman installed
- jq installed
- An existing ECR repository

### Environment Variables

- `ECR_REPOSITORY_NAME`: (Required) Name of the ECR repository to push images to
- `AWS_REGION`: AWS region for ECR (will use default from AWS CLI config if not specified)
- `AWS_ACCOUNT_ID`: AWS account ID (will be auto-detected if not specified)
- `AWS_PROFILE`: AWS profile to use (optional)

### Command Line Arguments

```
Usage: ./build-kmod-kmm.sh DRIVER_VERSION [OCP_VERSION]

Build and push kernel module container images for AWS Neuron

Arguments:
  DRIVER_VERSION    Neuron driver version (e.g., 2.16.7.0)
  OCP_VERSION       Optional: OpenShift version (e.g., 4.16 or 4.16.2)
```

### Examples

Build for a specific driver version across all OCP versions:
```bash
export ECR_REPOSITORY_NAME=my-ecr-repo
./build-kmod-kmm.sh 2.16.7.0
```

Build for a specific driver version and OCP version:
```bash
export ECR_REPOSITORY_NAME=my-ecr-repo
./build-kmod-kmm.sh 2.16.7.0 4.16.2
```

Build for a specific driver version and OCP minor version (all patch versions):
```bash
export ECR_REPOSITORY_NAME=my-ecr-repo
./build-kmod-kmm.sh 2.16.7.0 4.16
```

### Image Tags

The script creates two tags for each built image:

1. Base tag: `neuron-driver${DRIVER_VERSION}-ocp${OCP_VERSION}`
2. Full tag: `neuron-driver${DRIVER_VERSION}-ocp${OCP_VERSION}-kernel${KERNEL_VERSION}`

This allows you to reference images either by OCP version or by the specific kernel version.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.
