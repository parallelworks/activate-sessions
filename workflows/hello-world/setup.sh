#!/bin/bash
# setup.sh - Hello World Setup Script (runs on controller node)
#
# This script runs on the controller/login node in STEP 1 of the session_runner job.
# It runs BEFORE start.sh is submitted to the compute node.
#
# Use it to:
# - Download dependencies that require internet access
# - Set up shared resources accessible by compute nodes
# - Perform one-time initialization tasks
#
# The compute node will inherit the environment via shared filesystem (e.g., HOME).
#
# Coordinate files written here:
#   - SETUP_COMPLETE - Signals that setup completed successfully

# =============================================================================
# EARLY LOGGING - Capture everything before any failures
# =============================================================================
EARLY_LOG="${HOME}/hello-world-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${EARLY_LOG}") 2>&1

echo "=========================================="
echo "SETUP.SH LAUNCHED: $(date)"
echo "Early log location: ${EARLY_LOG}"
echo "=========================================="

# Log critical environment info immediately
echo ""
echo "[DEBUG] === ENVIRONMENT SNAPSHOT ==="
echo "[DEBUG] Date: $(date)"
echo "[DEBUG] Hostname: $(hostname)"
echo "[DEBUG] User: $(whoami)"
echo "[DEBUG] PWD: $(pwd)"
echo "[DEBUG] HOME: ${HOME}"
echo "[DEBUG] PW_PARENT_JOB_DIR: ${PW_PARENT_JOB_DIR:-UNSET}"
echo "[DEBUG] PW_SESSION_NAME: ${PW_SESSION_NAME:-UNSET}"
echo ""

# Log all environment variables for debugging
echo "[DEBUG] === ALL ENVIRONMENT VARIABLES ==="
env | sort
echo "[DEBUG] === END ENVIRONMENT VARIABLES ==="
echo ""

# Error handler to capture failures
error_handler() {
    local exit_code=$?
    local line_number=$1
    echo ""
    echo "[ERROR] =========================================="
    echo "[ERROR] SETUP SCRIPT FAILED!"
    echo "[ERROR] Exit code: ${exit_code}"
    echo "[ERROR] Failed at line: ${line_number}"
    echo "[ERROR] Command: ${BASH_COMMAND}"
    echo "[ERROR] Log file: ${EARLY_LOG}"
    echo "[ERROR] =========================================="
    exit ${exit_code}
}
trap 'error_handler ${LINENO}' ERR

set -e

[[ "${DEBUG:-}" == "true" ]] && set -x

echo "=========================================="
echo "Hello World Setup (Controller Node)"
echo "=========================================="

# Normalize job directory path (remove trailing slash if present)
echo "[DEBUG] Checking PW_PARENT_JOB_DIR..."
if [ -z "${PW_PARENT_JOB_DIR}" ]; then
    echo "[ERROR] PW_PARENT_JOB_DIR is not set!"
    exit 1
fi
JOB_DIR="${PW_PARENT_JOB_DIR%/}"
echo "[DEBUG] JOB_DIR set to: ${JOB_DIR}"
echo "Job directory: ${JOB_DIR}"
echo "Working directory: $(pwd)"

# Verify JOB_DIR exists or can be created
echo "[DEBUG] Checking if JOB_DIR exists..."
if [ ! -d "${JOB_DIR}" ]; then
    echo "[WARN] JOB_DIR does not exist, attempting to create: ${JOB_DIR}"
    mkdir -p "${JOB_DIR}" || {
        echo "[ERROR] Failed to create JOB_DIR: ${JOB_DIR}"
        exit 1
    }
fi
echo "[DEBUG] JOB_DIR exists: ${JOB_DIR}"
echo "[DEBUG] JOB_DIR contents:"
ls -la "${JOB_DIR}" 2>&1 || echo "[DEBUG] Could not list JOB_DIR"

# Source inputs if available
if [ -f inputs.sh ]; then
  source inputs.sh
elif [ -f "${JOB_DIR}/inputs.sh" ]; then
  source "${JOB_DIR}/inputs.sh"
fi

# =============================================================================
# SETUP PHASE - Runs on controller node
# =============================================================================
# This is where you would:
# - Download software from GitHub (compute nodes often lack internet)
# - Pull containers via Git LFS
# - Install shared dependencies
#
# For this simple example, we just verify Python is available.
# A real workflow might download noVNC, containers, etc.
# =============================================================================

# Verify Python is available (for the HTTP server)
PYTHON_CMD=""
for cmd in python3 python; do
  if command -v $cmd &> /dev/null; then
    PYTHON_CMD=$cmd
    break
  fi
done

if [ -z "${PYTHON_CMD}" ]; then
  echo "ERROR: Python not found" >&2
  exit 1
fi

echo "Python found: ${PYTHON_CMD}"

# Example: Create a shared logs directory that will be used by start.sh
# This demonstrates creating a shared resource on the controller
mkdir -p logs

# =============================================================================
# Write setup complete marker to job directory
# =============================================================================
# start.sh and wait_service.sh expect coordination files in $PW_PARENT_JOB_DIR
echo "[DEBUG] Writing SETUP_COMPLETE marker to ${JOB_DIR}/SETUP_COMPLETE"
touch "${JOB_DIR}/SETUP_COMPLETE" || {
    echo "[ERROR] Failed to create SETUP_COMPLETE marker"
    exit 1
}

# Copy the setup log to the job directory for easier access
echo "[DEBUG] Copying setup log to job directory..."
cp "${EARLY_LOG}" "${JOB_DIR}/setup.log" 2>/dev/null || true

echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "Shared resources prepared:"
echo "  - Python: ${PYTHON_CMD}"
echo "  - Logs directory: $(pwd)/logs"
echo "  - SETUP_COMPLETE: ${JOB_DIR}/SETUP_COMPLETE"
echo "  - Setup log: ${EARLY_LOG}"
echo "=========================================="
echo ""
echo "[DEBUG] Final JOB_DIR contents:"
ls -la "${JOB_DIR}" 2>&1
