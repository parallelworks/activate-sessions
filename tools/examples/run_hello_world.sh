#!/bin/bash
# Example: Run hello-world workflow locally
#
# This demonstrates running the hello-world workflow in different modes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNNER="${REPO_ROOT}/tools/workflow_runner.py"

echo "=============================================="
echo "Hello World Workflow - Local Test Runner"
echo "=============================================="

# Ensure we have PyYAML
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "Installing PyYAML..."
    pip install pyyaml
fi

# Example 1: Dry-run (show what would execute)
echo ""
echo "Example 1: Dry-run mode"
echo "----------------------------------------------"
python3 "${RUNNER}" "${REPO_ROOT}/workflows/hello-world/workflow.yaml" --dry-run

# Example 2: Full execution with custom message
echo ""
echo "Example 2: Full execution with custom inputs"
echo "----------------------------------------------"
python3 "${RUNNER}" "${REPO_ROOT}/workflows/hello-world/workflow.yaml" \
    -i "hello.message=Hello from Local Testing!" \
    -i "resource.ip=localhost" \
    --keep-work-dir \
    -v

echo ""
echo "=============================================="
echo "Done! Check the work directory for outputs."
echo "=============================================="
