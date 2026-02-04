#!/bin/bash
# wait_service.sh - Wait for session service to be ready
# Usage: bash utils/wait_service.sh
#
# Requires: PW_PARENT_JOB_DIR to be set
# Outputs to $OUTPUTS:
#   - HOSTNAME: Target hostname where service is running
#   - SESSION_PORT: Port number of the service

echo "=== Wait for Service ==="
echo "PW_PARENT_JOB_DIR: ${PW_PARENT_JOB_DIR}"
JOB_DIR="${PW_PARENT_JOB_DIR%/}"
echo "Looking for markers in: ${JOB_DIR}"

# Wait for job to start
echo "Waiting for job.started..."
while [ ! -f "${JOB_DIR}/job.started" ] && [ ! -f "${JOB_DIR}/job.ended" ]; do
  sleep 3
done

# Check if job ended before starting
if [ -f "${JOB_DIR}/job.ended" ] && [ ! -f "${JOB_DIR}/job.started" ]; then
  echo "ERROR: Job ended before starting"
  false
else
  echo "Job started! Waiting for connection info..."

  # Wait for SESSION_PORT file to exist (start.sh writes this after allocating port)
  echo "Waiting for SESSION_PORT file..."
  while [ ! -f "${JOB_DIR}/SESSION_PORT" ] && [ ! -f "${JOB_DIR}/job.ended" ]; do
    sleep 2
  done

  if [ -f "${JOB_DIR}/job.ended" ] && [ ! -f "${JOB_DIR}/SESSION_PORT" ]; then
    echo "ERROR: Job ended before writing SESSION_PORT"
    false
    exit 1
  fi

  SERVICE_HOSTNAME=$(cat "${JOB_DIR}/HOSTNAME")
  SERVICE_PORT=$(cat "${JOB_DIR}/SESSION_PORT")
  echo "HOSTNAME=${SERVICE_HOSTNAME}, SESSION_PORT=${SERVICE_PORT}"

  # Wait for service to respond (up to ~10 minutes)
  echo "Waiting for service..."
  SERVICE_READY=false
  for i in $(seq 1 200); do
    if curl -s --connect-timeout 5 --max-time 5 "http://${SERVICE_HOSTNAME}:${SERVICE_PORT}" -o /dev/null 2>&1; then
      SERVICE_READY=true
      break
    fi
    if [ -f "${JOB_DIR}/job.ended" ]; then
      echo "ERROR: Job ended"
      break
    fi
    sleep 3
  done

  if [ "$SERVICE_READY" = "true" ]; then
    echo "Service is ready!"
    echo "HOSTNAME=${SERVICE_HOSTNAME}" >> $OUTPUTS
    echo "SESSION_PORT=${SERVICE_PORT}" >> $OUTPUTS
  else
    echo "ERROR: Service timeout"
    false
  fi
fi
