# Scripts

## export-csv-kmod-images-ecr.sh

Exports a CSV catalog of kernel module images from your ECR repository.

### Usage

```bash
./export-csv-kmod-images-ecr.sh
```

### Environment Variables

- `ECR_REPOSITORY`: ECR repository name (default: "neuron-operator/kmod")
- `AWS_REGION`: AWS region (default: "us-east-2")

### Output

Creates `kmod_images_ecr.csv` with columns:
- `base_tag`: OCP version tag (e.g., "neuron-driver2.16.7.0-ocp4.16")
- `full_tag`: Kernel-specific tag (e.g., "neuron-driver2.16.7.0-ocp4.16-kernel5.14.0-...")
- `pull_url`: Complete image URL for pulling

### Example

```bash
# Use default repository
./export-csv-kmod-images-ecr.sh

# Use custom repository
ECR_REPOSITORY=my-kmod-repo ./export-csv-kmod-images-ecr.sh
```

Useful for inventory management and selecting appropriate images for your OpenShift environment.