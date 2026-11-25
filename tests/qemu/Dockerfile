FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils genisoimage openssh-client curl ca-certificates jq openssl bash zstd iproute2 procps && rm -rf /var/lib/apt/lists/*
