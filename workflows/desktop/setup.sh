#!/bin/bash
# setup.sh - Desktop Setup Script (runs on controller node)
#
# This script runs on the controller/login node in STEP 1 of the session_runner job.
# It runs BEFORE start.sh is submitted to the compute node.
#
# Use it to:
# - Download noVNC from GitHub (compute nodes often lack internet) [native mode]
# - Install Git LFS if needed
# - Pull nginx container via Git LFS [native mode]
# - Pull KasmVNC container via Git LFS [KasmVNC container mode]
# - Generate VNC password and build connection slug [native mode]
#
# Coordinate files written here:
#   - SETUP_COMPLETE - Signals that setup completed successfully
#   - VNC_MODE - Which VNC mode is being used (native or kasmvnc_container)
#   - VNC_PASSWORD - Generated password for start.sh to use [native mode]
#   - KASMVNC_CONTAINER_PATH - Path to KasmVNC container [KasmVNC container mode]

set -e

[[ "${DEBUG:-}" == "true" ]] && set -x

echo "=========================================="
echo "Desktop Setup (Controller Node)"
echo "=========================================="

# =============================================================================
# Configuration
# =============================================================================
# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"

# Source inputs from job directory (not current directory)
if [ -f "${JOB_DIR}/inputs.sh" ]; then
  echo "Sourcing inputs from ${JOB_DIR}/inputs.sh"
  source "${JOB_DIR}/inputs.sh"
else
  echo "WARNING: inputs.sh not found in ${JOB_DIR}"
fi

NOVNC_VERSION="v1.6.0"
SERVICE_PARENT_INSTALL_DIR="${HOME}/pw/software"
CONTAINER_DIR="${HOME}/pw/singularity"

# =============================================================================
# Helper: Install Git LFS with fallback to direct binary download
# =============================================================================
install_git_lfs() {
    if git lfs version >/dev/null 2>&1; then
        echo "Git LFS already available: $(git lfs version)"
        return 0
    fi

    echo "Git LFS not found, installing..."

    # Try bootstrap from singularity-containers repo
    git clone --depth 1 https://github.com/parallelworks/singularity-containers.git \
        ~/singularity-containers-tmp 2>/dev/null || true
    if [ -d ~/singularity-containers-tmp ]; then
        bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs 2>/dev/null || true
        rm -rf ~/singularity-containers-tmp
    fi

    # Check if bootstrap worked
    if git lfs version >/dev/null 2>&1; then
        echo "Git LFS installed via bootstrap: $(git lfs version)"
        return 0
    fi

    # Fallback: download git-lfs binary directly
    echo "Bootstrap did not install git-lfs, downloading binary directly..."
    local lfs_version="3.5.1"
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    local lfs_url="https://github.com/git-lfs/git-lfs/releases/download/v${lfs_version}/git-lfs-linux-${arch}-v${lfs_version}.tar.gz"
    local lfs_dir="${HOME}/.local/bin"
    mkdir -p "${lfs_dir}"

    if curl -sL "${lfs_url}" | tar xz -C /tmp/ 2>/dev/null; then
        cp "/tmp/git-lfs-${lfs_version}/git-lfs" "${lfs_dir}/"
        chmod +x "${lfs_dir}/git-lfs"
        export PATH="${lfs_dir}:${PATH}"
        rm -rf "/tmp/git-lfs-${lfs_version}"

        if git lfs version >/dev/null 2>&1; then
            echo "Git LFS installed directly: $(git lfs version)"
            return 0
        fi
    fi

    echo "WARNING: Failed to install Git LFS" >&2
    return 1
}

# Read VNC mode from inputs (default to native for backward compatibility)
vnc_mode="${desktop_vnc_mode:-native}"
echo "VNC Mode: ${vnc_mode}"

# Write VNC mode marker for start.sh
echo "${vnc_mode}" > "${JOB_DIR}/VNC_MODE"

# Write session name for start.sh (passed from workflow via environment)
echo "${PW_SESSION_NAME}" > "${JOB_DIR}/SESSION_NAME"

# =============================================================================
# KasmVNC Container Mode
# =============================================================================
if [[ "${vnc_mode}" == "kasmvnc_container" ]]; then
    echo "KasmVNC Container mode: skipping noVNC and nginx downloads"

    # Determine container runtime (default to singularity for backward compatibility)
    container_runtime="${KASM_CONTAINER_RUNTIME:-singularity}"
    echo "Container runtime: ${container_runtime}"
    echo "${container_runtime}" > "${JOB_DIR}/KASMVNC_CONTAINER_RUNTIME"

    # Handle Enroot runtime
    if [[ "${container_runtime}" == "enroot" ]]; then
        enroot_dir="${KASM_ENROOT_DIR:-/mnt/data/containers}"
        enroot_path="${enroot_dir}/kasmvnc-${desktop_kasmvnc_os:-rocky9}.sqsh"
        echo "Using Enroot container: ${enroot_path}"
        echo "${enroot_path}" > "${JOB_DIR}/KASMVNC_ENROOT_PATH"

    # Handle Singularity runtime (git_lfs source)
    elif [[ "${desktop_kasmvnc_container_source:-path}" == "git_lfs" ]]; then
        install_git_lfs

        # Derive git path and SIF name from OS choice
        git_path="kasmvnc-${desktop_kasmvnc_os:-rocky9}"
        sif_name="${git_path}.sif"

        # Pull KasmVNC container via sparse checkout + Git LFS
        KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/${sif_name}"
        if [ ! -f "${KASMVNC_CONTAINER_SIF}" ] || [ ! -s "${KASMVNC_CONTAINER_SIF}" ]; then
            echo "Fetching KasmVNC container via sparse checkout..."

            # Remove empty/corrupt file if it exists
            rm -f "${KASMVNC_CONTAINER_SIF}" 2>/dev/null || true

            # Pull to tmp location first
            TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
            mkdir -p "${TMP_CONTAINER_DIR}"

            cd "${TMP_CONTAINER_DIR}"
            git init
            git_repo="${desktop_kasmvnc_git_repo:-https://github.com/parallelworks/singularity-containers.git}"
            git_branch="${desktop_kasmvnc_git_branch:-main}"
            git remote add origin "${git_repo}"
            git config core.sparseCheckout true
            echo "${git_path}/*" > .git/info/sparse-checkout
            git lfs install
            git pull origin "${git_branch}"
            # Explicitly fetch LFS files
            git lfs pull --include="${git_path}/*"

            # Join SIF parts if split, otherwise just copy
            mkdir -p "${CONTAINER_DIR}"

            # Check if there are split parts (e.g., kasmvnc-rocky9.sif.00, .01, etc.)
            if compgen -G "${git_path}/${sif_name}.*" > /dev/null 2>&1; then
                echo "Joining SIF parts..."
                cat ${git_path}/${sif_name}.* > "${KASMVNC_CONTAINER_SIF}"
            elif [ -f "${git_path}/${sif_name}" ]; then
                echo "Copying KasmVNC container..."
                cp "${git_path}/${sif_name}" "${KASMVNC_CONTAINER_SIF}"
            else
                echo "WARNING: KasmVNC container not found after pull" >&2
            fi

            cd - >/dev/null
            rm -rf "${TMP_CONTAINER_DIR}"

            echo "KasmVNC container cached at ${KASMVNC_CONTAINER_SIF}"
        else
            echo "KasmVNC container already present at ${KASMVNC_CONTAINER_SIF}"
        fi

        echo "${KASMVNC_CONTAINER_SIF}" > "${JOB_DIR}/KASMVNC_CONTAINER_PATH"

    elif [[ "${desktop_kasmvnc_container_source:-path}" == "bucket" ]]; then
        # Pull from PW bucket (KASM_BUCKET_URI includes full path)
        bucket_uri="${KASM_BUCKET_URI}"
        if [ -z "${bucket_uri}" ]; then
            echo "ERROR: kasmvnc_bucket not provided" >&2
            exit 1
        fi

        # Derive cache filename from OS choice (avoids overwriting when switching OS)
        bucket_sif_name="kasmvnc-${desktop_kasmvnc_os:-rocky9}.sif"
        KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/${bucket_sif_name}"
        mkdir -p "${CONTAINER_DIR}"

        if [ ! -f "${KASMVNC_CONTAINER_SIF}" ] || [ ! -s "${KASMVNC_CONTAINER_SIF}" ]; then
            echo "Pulling KasmVNC container from bucket: ${bucket_uri}"
            rm -f "${KASMVNC_CONTAINER_SIF}" 2>/dev/null || true
            pw bucket cp "${bucket_uri}" "${KASMVNC_CONTAINER_SIF}"
            echo "KasmVNC container cached at ${KASMVNC_CONTAINER_SIF}"
        else
            echo "KasmVNC container already present at ${KASMVNC_CONTAINER_SIF}"
        fi

        echo "${KASMVNC_CONTAINER_SIF}" > "${JOB_DIR}/KASMVNC_CONTAINER_PATH"

    else
        # User-provided path
        container_path="${desktop_kasmvnc_container_path}"
        if [ -z "${container_path}" ]; then
            echo "ERROR: kasmvnc_container_path not provided" >&2
            exit 1
        fi
        echo "Using user-provided container path: ${container_path}"
        echo "${container_path}" > "${JOB_DIR}/KASMVNC_CONTAINER_PATH"
    fi

    # Write GPU setting for start.sh
    echo "${desktop_kasmvnc_enable_gpu:-true}" > "${JOB_DIR}/KASMVNC_CONTAINER_ENABLE_GPU"

    # Write mount paths for start.sh (optional, newline-delimited)
    if [ -n "${CONTAINER_MOUNT_PATHS:-}" ]; then
        echo "${CONTAINER_MOUNT_PATHS}" > "${JOB_DIR}/CONTAINER_MOUNT_PATHS"
        echo "Mount paths:"
        echo "${CONTAINER_MOUNT_PATHS}" | while IFS= read -r p; do
            [ -n "$p" ] && echo "  - $p" || true
        done
    fi

    # Build basepath for slug (KasmVNC container mode doesn't need password in slug)
    if [ -z "${PW_PLATFORM_HOST}" ]; then
        PW_PLATFORM_HOST="activate.parallel.works"
    fi
    basepath="/me/session/${PW_USER}/${PW_SESSION_NAME}"
    slug="vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&host=${PW_PLATFORM_HOST}${basepath}/&dt=0"
    echo "slug=${slug}"  | tee -a $OUTPUTS

# =============================================================================
# KasmProxy Mode (native VNC + containerized proxy)
# =============================================================================
elif [[ "${vnc_mode}" == "kasmproxy" ]]; then
    echo "KasmProxy mode: native VNC + containerized proxy"

    # Determine container runtime (default to enroot for backward compatibility)
    kasmproxy_runtime="${KASMPROXY_RUNTIME:-enroot}"

    echo "${kasmproxy_runtime}" > "${JOB_DIR}/KASMPROXY_RUNTIME"
    echo "KasmProxy runtime: ${kasmproxy_runtime}"

    if [[ "${kasmproxy_runtime}" == "singularity" ]]; then
        kasmproxy_source="${KASMPROXY_SINGULARITY_SOURCE:-git_lfs}"
        echo "KasmProxy Singularity source: ${kasmproxy_source}"

        if [[ "${kasmproxy_source}" == "git_lfs" ]]; then
            # Pull from Git LFS
            KASMPROXY_SIF="${CONTAINER_DIR}/kasmproxy.sif"

            install_git_lfs

            # Pull kasmproxy container if not present or empty
            if [ ! -f "${KASMPROXY_SIF}" ] || [ ! -s "${KASMPROXY_SIF}" ]; then
                echo "Fetching KasmProxy container via sparse checkout..."

                rm -f "${KASMPROXY_SIF}" 2>/dev/null || true

                TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
                mkdir -p "${TMP_CONTAINER_DIR}"

                cd "${TMP_CONTAINER_DIR}"
                git init
                git_repo="${KASMPROXY_GIT_REPO:-https://github.com/parallelworks/singularity-containers.git}"
                git_path="${KASMPROXY_GIT_PATH:-kasmproxy}"
                git remote add origin "${git_repo}"
                git config core.sparseCheckout true
                echo "${git_path}/*" > .git/info/sparse-checkout
                git lfs install
                git pull origin main
                git lfs pull --include="${git_path}/*"

                mkdir -p "${CONTAINER_DIR}"

                # Check if there are split parts
                if compgen -G "${git_path}/kasmproxy.sif.*" > /dev/null 2>&1; then
                    echo "Joining SIF parts..."
                    cat ${git_path}/kasmproxy.sif.* > "${CONTAINER_DIR}/kasmproxy.sif"
                elif [ -f "${git_path}/kasmproxy.sif" ]; then
                    echo "Copying KasmProxy container..."
                    cp "${git_path}/kasmproxy.sif" "${CONTAINER_DIR}/kasmproxy.sif"
                else
                    echo "WARNING: KasmProxy container not found after pull" >&2
                fi

                cd - >/dev/null
                rm -rf "${TMP_CONTAINER_DIR}"

                echo "KasmProxy container cached at ${KASMPROXY_SIF}"
            else
                echo "KasmProxy container already present at ${KASMPROXY_SIF}"
            fi

            kasmproxy_path="${KASMPROXY_SIF}"
        else
            # User-provided path
            kasmproxy_path="${KASMPROXY_SINGULARITY_PATH}"
            # Expand ~ to home directory
            kasmproxy_path="${kasmproxy_path/#\~/$HOME}"
            if [ -z "${kasmproxy_path}" ]; then
                echo "ERROR: kasmproxy_singularity_path not provided" >&2
                exit 1
            fi
        fi

        echo "${kasmproxy_path}" > "${JOB_DIR}/KASMPROXY_SINGULARITY_PATH"
        echo "KasmProxy Singularity container: ${kasmproxy_path}"
    else
        kasmproxy_path="${KASMPROXY_ENROOT_PATH:-/mnt/data/containers/kasmproxy.sqsh}"
        echo "${kasmproxy_path}" > "${JOB_DIR}/KASMPROXY_ENROOT_PATH"
        echo "KasmProxy Enroot container: ${kasmproxy_path}"
    fi

    # Build slug (same as container mode - no password needed)
    if [ -z "${PW_PLATFORM_HOST}" ]; then
        PW_PLATFORM_HOST="activate.parallel.works"
    fi
    basepath="/me/session/${PW_USER}/${PW_SESSION_NAME}"
    slug="vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&host=${PW_PLATFORM_HOST}${basepath}/&dt=0"
    echo "slug=${slug}" | tee -a $OUTPUTS

# =============================================================================
# Native VNC Mode (existing behavior)
# =============================================================================
else
    # Download noVNC from GitHub releases
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

    install_git_lfs

    # Pull nginx container via sparse checkout + Git LFS
    if [ ! -f "${CONTAINER_DIR}/nginx.sif" ] || [ ! -s "${CONTAINER_DIR}/nginx.sif" ]; then
        echo "Fetching nginx container via sparse checkout..."

        rm -f "${CONTAINER_DIR}/nginx.sif" 2>/dev/null || true

        TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
        mkdir -p "${TMP_CONTAINER_DIR}"

        cd "${TMP_CONTAINER_DIR}"
        git init
        git remote add origin https://github.com/parallelworks/singularity-containers.git
        git config core.sparseCheckout true
        echo "nginx/*" > .git/info/sparse-checkout
        git lfs install
        git pull origin main
        git lfs pull --include="nginx/*"

        mkdir -p "${CONTAINER_DIR}"

        if compgen -G "nginx/nginx.sif.*" > /dev/null 2>&1; then
            echo "Joining SIF parts..."
            cat nginx/nginx.sif.* > "${CONTAINER_DIR}/nginx.sif"
        elif [ -f "nginx/nginx.sif" ]; then
            echo "Copying nginx container..."
            cp nginx/nginx.sif "${CONTAINER_DIR}/nginx.sif"
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
    cd "${JOB_DIR}/workflows/desktop" 2>/dev/null || true

    # Generate VNC password and slug
    password=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
    echo "Generated VNC password"
    echo "password=${password}" | tee -a $OUTPUTS

    # Build basepath
    basepath="/me/session/${PW_USER}/${PW_SESSION_NAME}"

    # Build slug with embedded password (for autoconnect)
    if [ -z "${PW_PLATFORM_HOST}" ]; then
        PW_PLATFORM_HOST="activate.parallel.works"
    fi

    slug="vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&password=${password}&host=${PW_PLATFORM_HOST}${basepath}/&dt=0"
    echo "slug=${slug}" | tee -a $OUTPUTS

    # Write password to job directory
    echo "${password}" > "${JOB_DIR}/VNC_PASSWORD"
    chmod 600 "${JOB_DIR}/VNC_PASSWORD"
fi

# =============================================================================
# Write startup command if provided
# =============================================================================
if [ -n "${STARTUP_COMMAND:-}" ]; then
    echo "${STARTUP_COMMAND}" > "${JOB_DIR}/STARTUP_COMMAND"
    echo "Startup command: ${STARTUP_COMMAND}"
fi

# =============================================================================
# Write setup complete marker to job directory
# =============================================================================
touch "${JOB_DIR}/SETUP_COMPLETE"

echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "VNC Mode: ${vnc_mode}"
if [[ "${vnc_mode}" == "kasmvnc_container" ]]; then
    echo "Container runtime: ${container_runtime:-singularity}"
    if [[ "${container_runtime:-singularity}" == "enroot" ]]; then
        echo "Enroot container: $(cat ${JOB_DIR}/KASMVNC_ENROOT_PATH 2>/dev/null || echo 'not set')"
    else
        echo "Singularity container: $(cat ${JOB_DIR}/KASMVNC_CONTAINER_PATH 2>/dev/null || echo 'not set')"
    fi
elif [[ "${vnc_mode}" == "kasmproxy" ]]; then
    echo "KasmProxy container: $(cat ${JOB_DIR}/KASMPROXY_CONTAINER_PATH 2>/dev/null || echo 'not set')"
    echo "KasmVNC port: $(cat ${JOB_DIR}/KASMPROXY_KASM_PORT 2>/dev/null || echo '8443')"
else
    echo "Shared resources prepared:"
    echo "  - noVNC: ${NOVNC_INSTALL_DIR}"
    echo "  - nginx container: ${CONTAINER_DIR}/nginx.sif"
fi
echo "=========================================="
