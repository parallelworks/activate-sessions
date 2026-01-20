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

set -e

[[ "${DEBUG:-}" == "true" ]] && set -x

echo "=========================================="
echo "Hello World Setup (Controller Node)"
echo "=========================================="

# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"
echo "Job directory: ${JOB_DIR}"
echo "Working directory: $(pwd)"

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
touch "${JOB_DIR}/SETUP_COMPLETE"

echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "Shared resources prepared:"
echo "  - Python: ${PYTHON_CMD}"
echo "  - Logs directory: $(pwd)/logs"
echo "  - SETUP_COMPLETE: ${JOB_DIR}/SETUP_COMPLETE"
echo "=========================================="
