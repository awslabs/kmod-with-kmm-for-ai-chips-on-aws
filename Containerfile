ARG NEURON_DRIVER_VERSION
ARG DTK_IMAGE
ARG OCP_VERSION

FROM fedora as source

# Clone specific version of neuron driver
RUN dnf install -y git
RUN git clone https://github.com/wombelix/aws-neuron-driver.git /tmp/aws-neuron-driver
WORKDIR /tmp/aws-neuron-driver
ARG NEURON_DRIVER_VERSION
RUN git checkout ${NEURON_DRIVER_VERSION}

# DTK image
FROM ${DTK_IMAGE} as build

# Redeclare the ARG to use it in this stage
ARG NEURON_DRIVER_VERSION

# Install jq for JSON parsing
RUN dnf install -y jq

# Extract kernel version from driver-toolkit-release.json
RUN jq -r '.KERNEL_VERSION' /etc/driver-toolkit-release.json > /kernel_version.ver

# Copy only the src directory from the source stage
COPY --from=source /tmp/aws-neuron-driver/src /aws-neuron-driver
WORKDIR /aws-neuron-driver

# Split the version check into its own layer
RUN echo "Checking version ${NEURON_DRIVER_VERSION} against 2.18.12.0" && \
    if [ $(echo "${NEURON_DRIVER_VERSION} 2.18.12.0" | tr " " "\n" | sort -V | head -n 1) != "2.18.12.0" ]; then \
        echo "Version requires patching"; \
    else \
        echo "Version does not require patching"; \
    fi

# Split the Makefile patching into its own layer
RUN if [ $(echo "${NEURON_DRIVER_VERSION} 2.18.12.0" | tr " " "\n" | sort -V | head -n 1) != "2.18.12.0" ]; then \
        echo "Patching Makefile..." && \
        sed -i "s/\$(shell uname -r)/$(cat /kernel_version.ver)/g" Makefile && \
        cat Makefile; \
    fi

# Split the neuron_cdev.c patching into its own layer
RUN if [ $(echo "${NEURON_DRIVER_VERSION} 2.18.12.0" | tr " " "\n" | sort -V | head -n 1) != "2.18.12.0" ]; then \
        echo "Patching neuron_cdev.c..." && \
        sed -i "s/KERNEL_VERSION(6, 4, 0)/KERNEL_VERSION(5, 14, 0)/g" neuron_cdev.c && \
        cat neuron_cdev.c; \
    fi

# Make command in its own layer
RUN echo "Building kernel module..." && \
    echo "Kernel version: $(cat /kernel_version.ver)" && \
    cd /aws-neuron-driver && \
    make -C /lib/modules/$(cat /kernel_version.ver)/build M=$(pwd) modules

# Final image
FROM alpine

COPY --from=build /kernel_version.ver /kernel_version.ver
RUN mkdir -p /opt/lib/modules/$(cat /kernel_version.ver)/kernel/drivers/neuron
COPY --from=build /aws-neuron-driver/neuron.ko /opt/lib/modules/$(cat /kernel_version.ver)/kernel/drivers/neuron/neuron.ko
RUN depmod -b /opt

# Add kernel version label to final image
ARG KERNEL_VERSION=$(cat /kernel_version.env)
ARG OCP_VERSION
LABEL kernel-version=$KERNEL_VERSION \
      ocp-version=$OCP_VERSION
