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
# Pull nginx container via sparse checkout + Git LFS
# =============================================================================
if [ ! -f "${CONTAINER_DIR}/nginx.sif" ]; then
    echo "Fetching nginx container via sparse checkout..."

    # Pull to tmp location first
    TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
    mkdir -p "${TMP_CONTAINER_DIR}"

    cd "${TMP_CONTAINER_DIR}"
    git init
    git remote add origin https://github.com/parallelworks/singularity-containers.git
    git config core.sparseCheckout true
    echo "nginx/*" > .git/info/sparse-checkout
    git lfs install
    git pull origin main

    # Join SIF parts if split, otherwise just copy
    mkdir -p "${CONTAINER_DIR}"

    # Check if there are split parts (nginx.sif.00, nginx.sif.01, etc.)
    if compgen -G "nginx/nginx-unprivileged.sif.*" > /dev/null 2>&1; then
        echo "Joining SIF parts..."
        cat nginx/nginx-unprivileged.sif.* > "${CONTAINER_DIR}/nginx.sif"
    elif [ -f "nginx/nginx-unprivileged.sif" ]; then
        echo "Copying nginx container..."
        cp nginx/nginx-unprivileged.sif "${CONTAINER_DIR}/nginx.sif"
    else
        echo "WARNING: nginx container not found after pull" >&2
    fi

    cd - >/dev/null
    rm -rf "${TMP_CONTAINER_DIR}"

    echo "nginx container cached at ${CONTAINER_DIR}/nginx.sif"
else
    echo "nginx container already present at ${CONTAINER_DIR}/nginx.sif"
fi

# Ensure we're back in the workflow directory
cd "${PW_PARENT_JOB_DIR}/workflows/desktop" 2>/dev/null || true

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

# Write password and coordination files to job directory (not workflow directory)
# start.sh and wait_service.sh expect these in $PW_PARENT_JOB_DIR
echo "${password}" > "${PW_PARENT_JOB_DIR}/VNC_PASSWORD"
chmod 600 "${PW_PARENT_JOB_DIR}/VNC_PASSWORD"

# =============================================================================
# Write setup complete marker to job directory
# =============================================================================
touch "${PW_PARENT_JOB_DIR}/SETUP_COMPLETE"

echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "Shared resources prepared:"
echo "  - noVNC: ${NOVNC_INSTALL_DIR}"
echo "  - nginx container: ${CONTAINER_DIR}/nginx.sif"
echo "  - Git LFS: $(git lfs version)"
echo "=========================================="
