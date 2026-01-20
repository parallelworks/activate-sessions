#!/bin/bash
# start.sh - Hello World Service Startup Script (runs on compute node)
#
# This script runs on the compute node in STEP 2 of the session_runner job.
# It is submitted via marketplace/job_runner/v4.0 (SLURM/PBS) or runs directly
# on the controller if no scheduler is configured.
#
# It uses resources prepared by setup.sh which runs in STEP 1 on the controller.
#
# Environment variables:
#   hello_message - Custom greeting message (default: "Hello World from ACTIVATE!")
#   service_port   - Port to use (default: auto-allocate)
#
# Creates coordination files:
#   - HOSTNAME     - Target hostname
#   - SESSION_PORT - Allocated port
#   - job.started  - Signals job has started

set -e

[[ "${DEBUG:-}" == "true" ]] && set -x

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"

echo "=========================================="
echo "Hello World Service Starting (Compute Node)"
echo "=========================================="
echo "Script directory: ${SCRIPT_DIR}"
echo "Job directory: ${JOB_DIR}"
echo "Working directory: $(pwd)"

# Ensure we're working from the job directory for coordination files
cd "${JOB_DIR}"

# Source inputs if available
if [ -f inputs.sh ]; then
  source inputs.sh
fi

# Verify setup completed successfully (optional sanity check)
# SETUP_COMPLETE is created by setup.sh in the job directory
if [ -f "${JOB_DIR}/SETUP_COMPLETE" ]; then
  echo "Setup phase completed successfully"
else
  echo "Warning: SETUP_COMPLETE marker not found in ${JOB_DIR}"
fi

# =============================================================================
# Port Allocation
# =============================================================================
if [ -z "${service_port}" ] || [ "${service_port}" == "undefined" ]; then
  # Try to find an available port using Python
  service_port=$(~/pw/pw agent open-port)
fi

if [ -z "${service_port}" ]; then
  echo "$(date) ERROR: Failed to allocate service port" >&2
  exit 1
fi

echo "Service port: ${service_port}"

# =============================================================================
# Write coordination files
# =============================================================================
hostname > HOSTNAME
echo "${service_port}" > SESSION_PORT
touch job.started

echo "Hostname: $(hostname)"
echo "Coordination files written:"
echo "  - HOSTNAME: $(cat HOSTNAME)"
echo "  - SESSION_PORT: $(cat SESSION_PORT)"

# =============================================================================
# Get the greeting message
# =============================================================================
MESSAGE="${hello_message:-Hello World from ACTIVATE!}"

echo "Message: ${MESSAGE}"

# =============================================================================
# Create HTML page
# =============================================================================
cat > index.html <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Hello World</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }
        .container {
            text-align: center;
            color: white;
            padding: 2rem;
            background: rgba(255,255,255,0.1);
            border-radius: 1rem;
            box-shadow: 0 8px 32px rgba(0,0,0,0.3);
        }
        h1 { font-size: 3rem; margin: 0 0 1rem 0; }
        p { font-size: 1.2rem; margin: 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>MESSAGE_PLACEHOLDER</h1>
        <p>Running on HOSTNAME_PLACEHOLDER at DATE_PLACEHOLDER</p>
    </div>
</body>
</html>
HTMLEOF

# Replace placeholders
sed -i "s/MESSAGE_PLACEHOLDER/${MESSAGE}/" index.html
sed -i "s/HOSTNAME_PLACEHOLDER/$(hostname)/" index.html
sed -i "s/DATE_PLACEHOLDER/$(date)/" index.html

# =============================================================================
# Find Python executable
# =============================================================================
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

echo "Using Python: ${PYTHON_CMD}"

# =============================================================================
# Start the HTTP server
# =============================================================================
mkdir -p logs

echo "Starting HTTP server on port ${service_port}..."

nohup ${PYTHON_CMD} -m http.server ${service_port} > logs/server.log 2>&1 &
SERVER_PID=$!

echo "Server PID: ${SERVER_PID}"
echo "${SERVER_PID}" > server.pid

# Wait a moment for the server to start
sleep 2

# =============================================================================
# Verify server is running
# =============================================================================
if kill -0 ${SERVER_PID} 2>/dev/null; then
  echo "=========================================="
  echo "Hello World Service is RUNNING!"
  echo "=========================================="
  echo "PID: ${SERVER_PID}"
  echo "Port: ${service_port}"
  echo "Logs: $(pwd)/logs/server.log"
  echo "=========================================="

  # Keep the script alive while the server runs
  while kill -0 ${SERVER_PID} 2>/dev/null; do
    sleep 5
  done
else
  echo "ERROR: Server failed to start" >&2
  cat logs/server.log >&2
  exit 1
fi
