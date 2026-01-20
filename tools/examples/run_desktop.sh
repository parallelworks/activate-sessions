#!/bin/bash
# Example: Run desktop workflow locally
#
# Note: The desktop workflow requires VNC server which may not be available locally.
# This example runs in dry-run mode by default.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNNER="${REPO_ROOT}/tools/workflow_runner.py"

echo "=============================================="
echo "Desktop Workflow - Local Test Runner"
echo "=============================================="

# Ensure we have PyYAML
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "Installing PyYAML..."
    pip install pyyaml
fi

# Dry-run by default since VNC requires actual desktop environment
echo ""
echo "Running in dry-run mode (VNC requires desktop environment)"
echo "----------------------------------------------"
python3 "${RUNNER}" "${REPO_ROOT}/workflows/desktop/workflow.yaml" \
    --dry-run \
    -i "desktop.environment=xfce" \
    -i "resource.ip=localhost" \
    -v

echo ""
echo "=============================================="
echo "To run fully (requires VNC), remove --dry-run flag"
echo "=============================================="
