#!/bin/bash
# setup.sh - Desktop Setup Script (runs on controller node)
#
# This script runs on the controller/login node in STEP 1 of the session_runner job.
# It runs BEFORE start.sh is submitted to the compute node.
#
# Use it to:
# - Download noVNC from GitHub (compute nodes often lack internet)
# - Install Git LFS if needed
# - Pull nginx container via Git LFS
# - Generate VNC password and build connection slug
#
# Coordinate files written here:
#   - SETUP_COMPLETE - Signals that setup completed successfully
#   - VNC_PASSWORD - Generated password for start.sh to use

set -e

[[ "${DEBUG:-}" == "true" ]] && set -x

echo "=========================================="
echo "Desktop Setup (Controller Node)"
echo "=========================================="

# Source inputs if available
if [ -f inputs.sh ]; then
  source inputs.sh
fi

# =============================================================================
# Configuration
# =============================================================================
NOVNC_VERSION="v1.6.0"
SERVICE_PARENT_INSTALL_DIR="${HOME}/pw/software"
CONTAINER_DIR="${HOME}/pw/singularity"

# =============================================================================
# Download noVNC from GitHub releases
# =============================================================================
NOVNC_INSTALL_DIR="${SERVICE_PARENT_INSTALL_DIR}/noVNC-${NOVNC_VERSION}"
if [ ! -d "${NOVNC_INSTALL_DIR}" ]; then
    echo "Downloading noVNC ${NOVNC_VERSION}..."
    mkdir -p "${SERVICE_PARENT_INSTALL_DIR}"
    curl -L "https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_VERSION}.tar.gz" | \
        tar -xz -C "${SERVICE_PARENT_INSTALL_DIR}"
    echo "noVNC installed to: ${NOVNC_INSTALL_DIR}"
else
    echo "noVNC already installed at: ${NOVNC_INSTALL_DIR}"
fi

# =============================================================================
# Ensure Git LFS is available
# =============================================================================
if ! git lfs version >/dev/null 2>&1; then
    echo "Git LFS not found, installing..."
    # Clone singularity-containers repo (shallow, LFS pointers only)
    git clone --depth 1 https://github.com/parallelworks/singularity-containers.git \
        ~/singularity-containers-tmp || true

    if [ -d ~/singularity-containers-tmp ]; then
        bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs
        rm -rf ~/singularity-containers-tmp
        echo "Git LFS installed successfully"
    else
        echo "WARNING: Failed to install Git LFS" >&2
    fi
else
    echo "Git LFS already available: $(git lfs version)"
fi

# =============================================================================
# Pull nginx container via Git LFS
# =============================================================================
# Initialize singularity-containers repo if not already present
if [ ! -d "${CONTAINER_DIR}/.git" ]; then
    echo "Cloning singularity-containers repo..."
    GIT_LFS_SKIP_SMUDGE=1 git clone \
        https://github.com/parallelworks/singularity-containers.git "${CONTAINER_DIR}"
    cd "${CONTAINER_DIR}"
    git lfs install
    echo "Singularity containers repo initialized"
else
    echo "Singularity containers repo already exists"
fi

cd "${CONTAINER_DIR}"

# Pull nginx container (needed for KasmVNC)
if [ ! -f "nginx/nginx-unprivileged.sif" ]; then
    echo "Pulling nginx container via Git LFS..."
    git lfs pull --include="nginx/*"
else
    echo "nginx container already present"
fi

# Note: vncserver container is downloaded in start.sh only if needed (fallback)

# =============================================================================
# Generate VNC password and slug
# =============================================================================
password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
echo "Generated VNC password"
echo "password=${password}" | tee -a $OUTPUTS

# Build basepath
basepath="/me/session/${PW_USER}/${PW_SESSION_NAME:-session}"

# Build slug with embedded password (for autoconnect)
if [ -z "${PW_PLATFORM_HOST}" ]; then
    PW_PLATFORM_HOST="activate.parallel.works"
fi

slug="vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&password=${password}&host=${PW_PLATFORM_HOST}${basepath}/&dt=0"
echo "slug=${slug}" | tee -a $OUTPUTS

# Write password to file for start.sh to use
echo "${password}" > VNC_PASSWORD
chmod 600 VNC_PASSWORD

# =============================================================================
# Write setup complete marker
# =============================================================================
touch SETUP_COMPLETE

echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "Shared resources prepared:"
echo "  - noVNC: ${NOVNC_INSTALL_DIR}"
echo "  - nginx container: ${CONTAINER_DIR}/nginx/nginx-unprivileged.sif"
echo "  - Git LFS: $(git lfs version)"
echo "=========================================="
