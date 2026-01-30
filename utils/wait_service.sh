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

# Don't use set -e when sourced - it can cause issues with the parent shell
# set -e

# Configuration
TIMEOUT=${WAIT_TIMEOUT:-5}
RETRY_INTERVAL=${WAIT_RETRY_INTERVAL:-3}
MAX_SERVICE_ATTEMPTS=${MAX_SERVICE_ATTEMPTS:-100}

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
echo "JOB_DIR: ${JOB_DIR}"
echo "OUTPUTS: ${OUTPUTS:-<not set>}"
echo "TIMEOUT: ${TIMEOUT}"
echo "RETRY_INTERVAL: ${RETRY_INTERVAL}"
echo "MAX_SERVICE_ATTEMPTS: ${MAX_SERVICE_ATTEMPTS}"
echo "=========================================="

# Helper function for logging
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [wait_service] $*"
}

log "Checking job directory contents..."
ls -la "${JOB_DIR}/" 2>&1 || echo "Warning: Could not list job directory"

# 1. Wait for job to start
log "Phase 1: Waiting for job to start..."
attempt=1
while [ ! -f "${JOB_STARTED_FILE}" ]; do
  if [ -f "${JOB_ENDED_FILE}" ]; then
    log "ERROR: Job ended before it started"
    return 1
  fi
  log "[Attempt ${attempt}] Waiting for ${JOB_STARTED_FILE}..."
  sleep "${RETRY_INTERVAL}"
  ((attempt++))
done
log "Job started detected!"

# Allow NFS cache to sync (files are written before job.started but may not be visible yet)
log "Waiting for NFS cache sync..."
sleep 2
# Force NFS cache refresh by listing directory
ls -la "${JOB_DIR}/" >/dev/null 2>&1 || true

# Helper function to wait for a file with cache busting
wait_for_file() {
  local file_path="$1"
  local file_name="$2"
  local max_attempts=10

  log "Reading ${file_name} from ${file_path}..."
  for i in $(seq 1 ${max_attempts}); do
    # Force filesystem cache refresh before each check
    ls -la "${JOB_DIR}/" >/dev/null 2>&1 || true
    stat "${file_path}" >/dev/null 2>&1 || true

    if [ -f "${file_path}" ] && [ -s "${file_path}" ]; then
      log "${file_name} file found!"
      return 0
    fi
    log "Waiting for ${file_name} file (attempt $i/${max_attempts})..."
    sleep 2
  done

  log "ERROR: ${file_name} file not found after ${max_attempts} attempts"
  ls -la "${JOB_DIR}/" >&2
  return 1
}

# 2. Get hostname
log "Phase 2: Getting hostname..."
if ! wait_for_file "${HOSTNAME_FILE}" "HOSTNAME"; then
  log "ERROR: Failed to get HOSTNAME"
  return 1
fi
SERVICE_HOSTNAME=$(cat "${HOSTNAME_FILE}")
log "HOSTNAME=${SERVICE_HOSTNAME}"
echo "HOSTNAME=${SERVICE_HOSTNAME}"
if [ -n "${OUTPUTS:-}" ]; then
  log "Writing HOSTNAME to OUTPUTS file: ${OUTPUTS}"
  echo "HOSTNAME=${SERVICE_HOSTNAME}" >> "${OUTPUTS}"
else
  log "WARNING: OUTPUTS not set, cannot write HOSTNAME"
fi

# 3. Get session port
log "Phase 3: Getting session port..."
if ! wait_for_file "${SESSION_PORT_FILE}" "SESSION_PORT"; then
  log "ERROR: Failed to get SESSION_PORT"
  return 1
fi
SESSION_PORT=$(cat "${SESSION_PORT_FILE}")
log "SESSION_PORT=${SESSION_PORT}"
echo "SESSION_PORT=${SESSION_PORT}"
if [ -n "${OUTPUTS:-}" ]; then
  log "Writing SESSION_PORT to OUTPUTS file: ${OUTPUTS}"
  echo "SESSION_PORT=${SESSION_PORT}" >> "${OUTPUTS}"
else
  log "WARNING: OUTPUTS not set, cannot write SESSION_PORT"
fi

# 4. Wait for service to respond
log "Phase 4: Waiting for service to respond on ${SERVICE_HOSTNAME}:${SESSION_PORT}..."
attempt=1
while [ ${attempt} -le ${MAX_SERVICE_ATTEMPTS} ]; do
  log "[Attempt ${attempt}/${MAX_SERVICE_ATTEMPTS}] Checking http://${SERVICE_HOSTNAME}:${SESSION_PORT}..."

  if curl --silent --connect-timeout "${TIMEOUT}" --max-time "${TIMEOUT}" "http://${SERVICE_HOSTNAME}:${SESSION_PORT}" -o /dev/null 2>&1; then
    log "SUCCESS: Service is responding!"
    log "=========================================="
    log "wait_service.sh completed successfully"
    log "=========================================="

    # Verify outputs were written
    if [ -n "${OUTPUTS:-}" ] && [ -f "${OUTPUTS}" ]; then
      log "OUTPUTS file contents:"
      cat "${OUTPUTS}" 2>&1 | while read line; do log "  $line"; done
    fi

    log "Returning 0 (success) to caller..."
    return 0
  fi

  if [ -f "${JOB_ENDED_FILE}" ]; then
    log "ERROR: Job ended before service was ready"
    return 1
  fi

  log "Service not responding. Retrying in ${RETRY_INTERVAL} seconds..."
  sleep "${RETRY_INTERVAL}"
  ((attempt++))
done

log "ERROR: Service did not respond after ${MAX_SERVICE_ATTEMPTS} attempts"
return 1
