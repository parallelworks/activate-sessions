#!/bin/bash
# wait_service.sh - Wait for session service to be ready
# Usage: source utils/wait_service.sh
#
# Requires: PW_PARENT_JOB_DIR to be set
# Outputs to $OUTPUTS:
#   - HOSTNAME: Target hostname where service is running
#   - SESSION_PORT: Port number of the service
#
# Returns: 0 on success, 1 on failure

set -e

# Configuration
TIMEOUT=${WAIT_TIMEOUT:-5}
RETRY_INTERVAL=${WAIT_RETRY_INTERVAL:-3}

# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"

JOB_STARTED_FILE="${JOB_DIR}/job.started"
HOSTNAME_FILE="${JOB_DIR}/HOSTNAME"
SESSION_PORT_FILE="${JOB_DIR}/SESSION_PORT"
JOB_ENDED_FILE="${JOB_DIR}/job.ended"

echo "=========================================="
echo "wait_service.sh starting"
echo "=========================================="
echo "PW_PARENT_JOB_DIR: ${PW_PARENT_JOB_DIR}"
echo "TIMEOUT: ${TIMEOUT}"
echo "RETRY_INTERVAL: ${RETRY_INTERVAL}"
echo "=========================================="

# 1. Wait for job to start
echo "Waiting for job to start..."
attempt=1
while [ ! -f "${JOB_STARTED_FILE}" ]; do
  if [ -f "${JOB_ENDED_FILE}" ]; then
    echo "$(date) ERROR: Job ended before it started" >&2
    exit 1
  fi
  echo "$(date) [Attempt ${attempt}] Waiting for ${JOB_STARTED_FILE}..."
  sleep "${RETRY_INTERVAL}"
  ((attempt++))
done
echo "$(date) Job started detected"

# Allow NFS cache to sync (files are written before job.started but may not be visible yet)
sleep 2
# Force NFS cache refresh by listing directory
ls -la "${JOB_DIR}/" >/dev/null 2>&1 || true

# Helper function to wait for a file with cache busting
wait_for_file() {
  local file_path="$1"
  local file_name="$2"
  local max_attempts=10

  echo "Reading ${file_name} from ${file_path}..."
  for i in $(seq 1 ${max_attempts}); do
    # Force filesystem cache refresh before each check
    ls -la "${JOB_DIR}/" >/dev/null 2>&1 || true
    stat "${file_path}" >/dev/null 2>&1 || true

    if [ -f "${file_path}" ] && [ -s "${file_path}" ]; then
      return 0
    fi
    echo "$(date) Waiting for ${file_name} file (attempt $i/${max_attempts})..."
    sleep 2
  done

  echo "$(date) ERROR: ${file_name} file not found" >&2
  ls -la "${JOB_DIR}/" >&2
  return 1
}

# 2. Get hostname
if ! wait_for_file "${HOSTNAME_FILE}" "HOSTNAME"; then
  exit 1
fi
HOSTNAME=$(cat "${HOSTNAME_FILE}")
echo "HOSTNAME=${HOSTNAME}" | tee -a $OUTPUTS

# 3. Get session port
if ! wait_for_file "${SESSION_PORT_FILE}" "SESSION_PORT"; then
  exit 1
fi
SESSION_PORT=$(cat "${SESSION_PORT_FILE}")
echo "SESSION_PORT=${SESSION_PORT}" | tee -a $OUTPUTS

# 4. Wait for service to respond
echo "Waiting for service to respond on ${HOSTNAME}:${SESSION_PORT}..."
attempt=1
while true; do
  echo "$(date) [Attempt ${attempt}] Checking http://${HOSTNAME}:${SESSION_PORT}..."

  if curl --silent --connect-timeout "${TIMEOUT}" "http://${HOSTNAME}:${SESSION_PORT}" >/dev/null 2>&1; then
    echo "$(date) SUCCESS: Service is responding!"
    exit 0
  fi

  if [ -f "${JOB_ENDED_FILE}" ]; then
    echo "$(date) ERROR: Job ended before service was ready" >&2
    exit 1
  fi

  echo "$(date) Service not responding. Retrying in ${RETRY_INTERVAL} seconds..."
  sleep "${RETRY_INTERVAL}"
  ((attempt++))
done
