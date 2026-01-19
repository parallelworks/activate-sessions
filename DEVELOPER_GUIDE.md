# Developer Guide

This guide shows you how to create interactive session workflows for the Parallel Works ACTIVATE platform.

## Creating a New Workflow

The easiest way to create a workflow is to copy the `hello-world` example and modify it.

### Step 1: Copy the Template

```bash
cp -r workflows/hello-world workflows/my-service
cd workflows/my-service
```

### Step 2: Write Your Service Script (`start.sh`)

Your service script runs on the compute node. It needs to:

1. **Find an available port**
   ```bash
   SESSION_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
   ```

2. **Write coordination files**
   ```bash
   hostname > HOSTNAME
   echo $SESSION_PORT > SESSION_PORT
   touch job.started
   ```

3. **Start your service** in the background with logging
   ```bash
   exec python -m http.server $SESSION_PORT > run.${PW_JOB_ID}.out 2>&1
   ```

See the full [hello-world/start.sh](../workflows/hello-world/start.sh) example.

### Step 3: Edit the Workflow (`workflow.yaml`)

Key sections to modify:

| Section | Purpose |
|---------|---------|
| `permissions` | Access controls (use `"*"` for open) |
| `sessions` | Define the session name (e.g., `session`) |
| `preprocessing` | Checkout your scripts from git |
| `session_runner` | Submit job via `marketplace/job_runner/v4.0` |
| `wait_for_service` | Wait for your service to respond |
| `update_session` | Configure session proxy |
| `complete` | Display connection info |
| `on.execute.inputs` | Define your input form |

#### Input Form Configuration

Add user inputs under `on.execute.inputs`:

```yaml
"on":
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Service host
        autoselect: true

      my_service:
        type: group
        label: My Service Settings
        items:
          message:
            type: string
            label: Greeting Message
            default: "Hello World"
```

See the [form configuration docs](https://parallelworks.com/docs/workflows/creating-workflows#form-configuration) for all field types.

### Step 4: Access User Inputs

In your `start.sh` script, access inputs via environment variables:

```bash
# From workflow inputs
echo "${PW_INPUT_MY_SERVICE_MESSAGE}"

# From platform
echo "Job dir: ${PW_PARENT_JOB_DIR}"
echo "Job ID: ${PW_JOB_ID}"
```

### Step 5: Transfer Optional Files

If you need to transfer files from the user workspace, add a preprocessing step:

```yaml
- name: Transfer inputs
  run: |
    REMOTE_JOB_DIR="./pw/jobs/${PW_WORKFLOW_NAME}/${PW_JOB_NUMBER}/"
    if [ -f inputs.sh ]; then
      scp inputs.sh ${{ inputs.resource.ip }}:${REMOTE_JOB_DIR}
    fi
```

## Workflow Jobs Explained

### preprocessing
Checks out your service scripts from git to the remote host.

```yaml
- uses: parallelworks/checkout
  with:
    repo: https://github.com/your-org/your-repo.git
    branch: main
    sparse_checkout:
      - workflows/my-service
```

### session_runner
Submits your job using `marketplace/job_runner/v4.0`. Supports:
- **Controller mode** - Runs directly on the login node
- **SLURM** - Submits via `sbatch`
- **PBS** - Submits via `qsub`

```yaml
- uses: marketplace/job_runner/v4.0
  with:
    resource: ${{ inputs.resource }}
    rundir: "${PW_PARENT_JOB_DIR}"
    scheduler: ${{ inputs.resource.schedulerType != '' }}
    use_existing_script: true
    script_path: "${PW_PARENT_JOB_DIR}/workflows/my-service/start.sh"
```

### wait_for_service
Waits for your service to be ready. Uses `utils/wait_service.sh`:

```bash
source utils/wait_service.sh
```

This script:
- Waits for `job.started` file
- Reads `HOSTNAME` and `SESSION_PORT` files
- Pings the service until it responds
- Outputs `HOSTNAME` and `SESSION_PORT` for other jobs to use

### update_session
Configures the session proxy to route traffic to your service.

```yaml
- uses: parallelworks/update-session
  with:
    target: ${{ inputs.resource.id }}
    name: ${{ sessions.session }}
    remoteHost: ${{ needs.wait_for_service.outputs.HOSTNAME }}
    remotePort: ${{ needs.wait_for_service.outputs.SESSION_PORT }}
    local_port: ${{ needs.update_session.outputs.local_port }}
```

### complete
Displays connection information to the user.

## Coordination Files

Your service script creates these files for workflow coordination:

| File | Purpose | Written By |
|------|---------|------------|
| `job.started` | Signals job has started | Your `start.sh` |
| `HOSTNAME` | Target hostname | Your `start.sh` |
| `SESSION_PORT` | Service port | Your `start.sh` |
| `job.ended` | Signals job completion | `session_runner` |

## Common Patterns

### Using a Container

```bash
# In start.sh
apptainer exec --bind $PWD /path/to/image.sif python -m http.server $SESSION_PORT
```

### Background Process with Cleanup

```bash
# In start.sh
cleanup() {
    kill $PID 2>/dev/null
}
trap cleanup EXIT

python -m my_service &
PID=$!
wait $PID
```

### Custom Health Check

Modify `utils/wait_service.sh` or inline your own check:

```bash
while ! curl -f http://${HOSTNAME}:${SESSION_PORT}/health; do
    sleep 3
done
```

## Testing

```bash
# Unit tests
python3 -m pytest tests/unit

# Integration tests (requires .env with credentials)
python3 -m pytest tests/integration -m integration
```

## Platform Documentation

- [Interactive Sessions](https://parallelworks.com/docs/workflows/interactive-sessions)
- [Creating Workflows](https://parallelworks.com/docs/workflows/creating-workflows)
- [Form Configuration](https://parallelworks.com/docs/workflows/creating-workflows#form-configuration)
