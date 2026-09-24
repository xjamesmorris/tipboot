FROM registry.fedoraproject.org/fedora:44

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="Tipboot toolchain" \
      org.opencontainers.image.description="Fedora 44 toolchain for building and smoke-testing Tipboot kernels" \
      org.opencontainers.image.source="https://github.com/xjamesmorris/tipboot" \
      org.opencontainers.image.url="https://github.com/xjamesmorris/tipboot" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

ENV HOME=/home/tipboot \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TIPBOOT_VERSION="${VERSION}" \
    TIPBOOT_REVISION="${REVISION}"

# Fedora package versions intentionally track the Fedora 44 repositories.
# hadolint ignore=DL3041
RUN dnf -y --setopt=install_weak_deps=False install \
        ShellCheck \
        bash \
        bats \
        bc \
        binutils \
        bison \
        bzip2 \
        ca-certificates \
        clang \
        coreutils \
        cpio \
        curl \
        diffutils \
        dtc \
        dwarves \
        elfutils-libelf-devel \
        file \
        findutils \
        flex \
        gawk \
        gcc \
        gcc-c++ \
        git-core \
        grep \
        gzip \
        jq \
        kmod \
        lld \
        llvm \
        lz4 \
        make \
        ncurses-devel \
        openssl \
        openssl-devel \
        patch \
        perl \
        pkgconf-pkg-config \
        python3 \
        qemu-img \
        qemu-system-aarch64-core \
        rsync \
        sed \
        shadow-utils \
        tar \
        unzip \
        util-linux \
        which \
        xz \
        zstd \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/libdnf5

RUN groupadd --gid 1000 tipboot \
    && useradd \
        --uid 1000 \
        --gid tipboot \
        --create-home \
        --shell /bin/bash \
        tipboot \
    && install -d -o tipboot -g tipboot /workspace

COPY --chmod=0755 scripts/ /usr/local/libexec/tipboot/
COPY smoke-init/ /usr/local/libexec/smoke-init/

RUN ln -s /usr/local/libexec/tipboot/version /usr/local/bin/tipboot-version

USER 1000:1000
WORKDIR /workspace

CMD ["/bin/bash"]
