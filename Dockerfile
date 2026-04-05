FROM ubuntu:25.10

ARG BASE_IMAGE=ubuntu:25.10
ARG PYTHON_VERSION=3.13
ARG ROCM_VERSION=7.2.1
ARG AMDGPU_VERSION=7.2.1.70201

# Pin the uv version for reproducibility
ARG UV_VERSION=0.11.3

LABEL org.opencontainers.image.ref.name=rocm/pytorch:rocm7.2.1_ubuntu25.10_py3.13_mineru

ENV DEBIAN_FRONTEND=noninteractive

# Set timezone non-interactively
RUN echo "tzdata tzdata/Areas select Etc" | debconf-set-selections \
    && echo "tzdata tzdata/Zones/Etc select UTC" | debconf-set-selections

# Install base system packages
RUN apt update \
    && apt install -y wget software-properties-common curl rsync dialog git \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/opt/rocm/lib

# Install Python
RUN apt update \
    && apt install -y \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-dev \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# Install uv with checksum verification
RUN set -e \
    && ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64)  UV_PLATFORM="x86_64-unknown-linux-gnu" ;; \
        aarch64) UV_PLATFORM="aarch64-unknown-linux-gnu" ;; \
        *)       echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac \
    && UV_TARBALL="uv-${UV_PLATFORM}.tar.gz" \
    && UV_BASE_URL="https://releases.astral.sh/github/uv/releases/download/${UV_VERSION}" \
    && curl --proto '=https' --tlsv1.2 -fsSL -o "/tmp/${UV_TARBALL}" "${UV_BASE_URL}/${UV_TARBALL}" \
    && curl --proto '=https' --tlsv1.2 -fsSL -o "/tmp/${UV_TARBALL}.sha256" "${UV_BASE_URL}/${UV_TARBALL}.sha256" \
    && cd /tmp \
    && sha256sum -c "${UV_TARBALL}.sha256" \
    && tar -xzf "${UV_TARBALL}" -C /usr/local/bin --strip-components=1 \
    && rm -f "/tmp/${UV_TARBALL}" "/tmp/${UV_TARBALL}.sha256" \
    && uv --version

ENV PATH=/usr/local/bin:$PATH

# Create virtual environment and install base Python packages
RUN uv venv --python python${PYTHON_VERSION} /opt/venv \
    && uv pip install --python /opt/venv/bin/python hypothesis scipy ninja setuptools

ENV PATH=/opt/venv/bin:/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV VIRTUAL_ENV=/opt/venv

# Install ROCm via amdgpu-install
RUN cd /tmp \
    && if [ "$PYTHON_VERSION" = "3.12" ] || [ "$PYTHON_VERSION" = "3.13" ] || [ "$PYTHON_VERSION" = "3.14" ]; then \
        DISTRO=noble; \
    elif [ "$PYTHON_VERSION" = "3.11" ] || [ "$PYTHON_VERSION" = "3.10" ] || [ "$PYTHON_VERSION" = "3.9" ] || [ "$PYTHON_VERSION" = "3.8" ]; then \
        DISTRO=jammy; \
    else \
        echo "Unsupported PYTHON_VERSION: $PYTHON_VERSION" && exit 1; \
    fi \
    && wget "https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${DISTRO}/amdgpu-install_${AMDGPU_VERSION}-1_all.deb" \
    && apt update \
    && apt install -y ./*.deb \
    && amdgpu-install --usecase=rocm -y \
    && rm -f ./*.deb \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# ── System dependencies for MinerU (OpenCV, image libs) ──────────────────────
RUN apt update \
    && apt install -y \
        libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# ── Install ROCm-specific wheels + MinerU via pyproject.toml ──────────────────
#
# The pyproject.toml declares:
#   - torch/torchvision/torchaudio/triton/apex pinned to ROCm 7.2.1 versions
#   - [tool.uv.sources] routes those packages to the Radeon flat index
#   - [[tool.uv.index]] with explicit=true prevents PyPI from serving them
#   - MinerU==3.0.8 and all its dependencies
#
# This gives uv a single coherent resolution: ROCm wheels from Radeon,
# everything else from PyPI, no CUDA/nvidia packages.
COPY pyproject.toml /opt/mineru/pyproject.toml
RUN cd /opt/mineru \
    && uv pip install --no-cache -r pyproject.toml

# ── Record ROCm package versions for verification ────────────────────────────
RUN set -e \
    && echo "# Auto-generated: ROCm-compiled packages" > /opt/rocm-packages.txt \
    && for pkg in torch torchvision torchaudio triton apex; do \
        ver=$(uv pip show "$pkg" 2>/dev/null \
              | grep '^Version:' | awk '{print $2}'); \
        echo "${pkg}==${ver}" >> /opt/rocm-packages.txt; \
    done \
    && cat /opt/rocm-packages.txt

# ── Verify no nvidia/CUDA packages snuck in ──────────────────────────────────
RUN set -e \
    && if uv pip list 2>/dev/null | grep -qiE '^nvidia'; then \
        echo "FAIL: nvidia packages detected — ROCm wheel routing failed:"; \
        uv pip list 2>/dev/null | grep -iE '^nvidia'; \
        exit 1; \
    fi \
    && echo "=== No nvidia packages — ROCm install clean ==="

# Create symlink for convenience
RUN ln -sf /usr/bin/python3 /usr/bin/python

# ── Diagnostic script ────────────────────────────────────────────────────────
COPY diagnose.py /opt/mineru/diagnose.py

# ── Non-root user for running the service ────────────────────────────────────
# render + video groups are required for ROCm GPU access.
# The GIDs here (109, 44) are common defaults; if your host differs, override
# at run-time with:  docker run --group-add $(getent group render | cut -d: -f3) ...
ARG MINERU_UID=1000
ARG MINERU_GID=1000
RUN groupadd -g ${MINERU_GID} mineru 2>/dev/null \
    || groupmod -n mineru $(getent group ${MINERU_GID} | cut -d: -f1) 2>/dev/null \
    || true \
    && useradd -m -u ${MINERU_UID} -g ${MINERU_GID} -G render,video -s /bin/bash mineru 2>/dev/null \
    || usermod -l mineru -d /home/mineru -m $(getent passwd ${MINERU_UID} | cut -d: -f1) 2>/dev/null \
    || true \
    && id mineru

# Pre-create directories the user will need, with correct ownership
RUN mkdir -p /home/mineru/.cache /home/mineru/output \
    && chown -R mineru:mineru /home/mineru

# ── Model & workspace volumes ────────────────────────────────────────────────
# MinerU models are NOT baked into the image.  Mount a persistent volume to
# avoid re-downloading on every container start.
#
# First run (download models):
#   docker run --rm \
#     --device=/dev/kfd --device=/dev/dri \
#     -v mineru-models:/home/mineru/.cache \
#     your-image:latest \
#     mineru-models-download
#
# Run the API server:
#   docker run -d \
#     --device=/dev/kfd --device=/dev/dri \
#     -v mineru-models:/home/mineru/.cache \
#     -v /path/to/pdfs:/home/mineru/workspace \
#     -p 8000:8000 \
#     your-image:latest
#
# The API output directory defaults to ./output inside the container,
# configurable via MINERU_API_OUTPUT_DIR.
ENV MINERU_API_OUTPUT_DIR=/home/mineru/output

USER mineru
WORKDIR /home/mineru

ENV MINERU_PORT=8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -q -O /dev/null http://localhost:${MINERU_PORT}/health || exit 1

ENTRYPOINT ["mineru-api"]
CMD ["--host", "0.0.0.0", "--port", "8000"]