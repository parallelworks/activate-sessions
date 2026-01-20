# Developer Guide

This guide shows you how to create interactive session workflows for the Parallel Works ACTIVATE platform.

## Creating a New Workflow

The easiest way to create a workflow is to copy the `hello-world` example and modify it.

### Step 1: Copy the Template

```bash
cp -r workflows/hello-world workflows/my-service
cd workflows/my-service
```

### Step 2: Write Your Two Scripts

Interactive session workflows use **two scripts** that run at different stages:

| Script | Runs On | When | Purpose |
|--------|---------|------|---------|
| `setup.sh` | Controller/login node | session_runner, step 1 | Download dependencies, install containers, prepare shared resources |
| `start.sh` | Compute node (or controller if no scheduler) | session_runner, step 2 (via job_runner) | Start the service, write coordination files, keep session alive |

**Why separate them?**
- Controller nodes typically have internet access; compute nodes often don't
- Downloads should happen once (controller) before submitting to compute
- Shared resources (containers, software installs) persist across jobs

#### setup.sh (Controller, step 1)

Your setup script runs on the controller before the compute job is submitted. Use it to:

1. **Download software** from GitHub, PyPI, etc.
   ```bash
   curl -L https://github.com/example/tool/archive/refs/tags/v1.0.tar.gz | tar -xz
   ```

2. **Pull containers** via Git LFS
   ```bash
   git lfs pull --include="my-container/*"
   ```

3. **Generate passwords/tokens** that need to be shared
   ```bash
   password=$(openssl rand -base64 12 | head -c 12)
   echo "${password}" > VNC_PASSWORD
   echo "password=${password}" | tee -a $OUTPUTS
   ```

4. **Write coordination files** for start.sh to use
   ```bash
   touch SETUP_COMPLETE
   ```

See the full [hello-world/setup.sh](workflows/hello-world/setup.sh) example.

#### start.sh (Compute Node, step 2)

Your service script runs on the compute node (via SLURM/PBS) or directly on the controller. It needs to:

1. **Verify setup completed**
   ```bash
   if [ ! -f SETUP_COMPLETE ]; then
     echo "ERROR: setup.sh did not complete" >&2
     exit 1
   fi
   ```

2. **Find an available port**
   ```bash
   SESSION_PORT=$(~/pw/pw agent open-port)
   ```

3. **Write coordination files**
   ```bash
   hostname > HOSTNAME
   echo $SESSION_PORT > SESSION_PORT
   touch job.started
   ```

4. **Start your service** in the background with logging
   ```bash
   exec python -m http.server $SESSION_PORT > logs/server.log 2>&1
   ```

See the full [hello-world/start.sh](workflows/hello-world/start.sh) example.

### Step 3: Edit the Workflow (`workflow.yaml`)

Key sections to modify:

| Section | Purpose |
|---------|---------|
| `permissions` | Access controls (use `"*"` for open) |
| `sessions` | Define the session name (e.g., `session`) |
| `preprocessing` | Checkout your scripts from git |
| `session_runner` | Step 1: run setup.sh, Step 2: submit start.sh via job_runner |
| `wait_for_service` | Wait for your service to respond |
| `update_session` | Configure session proxy |
| `complete` | Display connection info |
| `on.execute.inputs` | Define your input form |

#### The session_runner Pattern

```yaml
session_runner:
  needs: [preprocessing]
  ssh:
    remoteHost: ${{ inputs.resource.ip }}
  steps:
    # Step 1: Run controller setup (downloads, containers, password generation)
    - name: Run controller setup
      run: |
        cd workflows/${{ inputs.workflow_dir }}
        bash setup.sh

    # Step 2: Submit start.sh to compute node
    - name: Submit session script
      uses: marketplace/job_runner/v4.0
      with:
        resource: ${{ inputs.resource }}
        rundir: "${PW_PARENT_JOB_DIR}"
        scheduler: ${{ inputs.resource.schedulerType != '' }}
        use_existing_script: true
        script_path: "${PW_PARENT_JOB_DIR}/workflows/${{ inputs.workflow_dir }}/start.sh"
```

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
Has two sequential steps:
1. **Run setup.sh** on the controller (downloads, containers, setup)
2. **Submit start.sh** to compute node via `marketplace/job_runner/v4.0`

Supports:
- **Controller mode** - Both steps run on the login node
- **SLURM** - Step 1 on controller, Step 2 submitted via sbatch
- **PBS** - Step 1 on controller, Step 2 submitted via qsub

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

Your scripts create these files for workflow coordination:

| File | Purpose | Written By |
|------|---------|------------|
| `SETUP_COMPLETE` | Signals setup completed successfully | Your `setup.sh` |
| `job.started` | Signals job has started | Your `start.sh` |
| `HOSTNAME` | Target hostname | Your `start.sh` |
| `SESSION_PORT` | Service port | Your `start.sh` |
| `job.ended` | Signals job completion | `session_runner` |

## Common Patterns

### Downloading Software in setup.sh

```bash
# In setup.sh (runs on controller with internet)
NOVNC_VERSION="v1.6.0"
if [ ! -d "${HOME}/pw/software/noVNC-${NOVNC_VERSION}" ]; then
    mkdir -p "${HOME}/pw/software"
    curl -L "https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_VERSION}.tar.gz" | \
        tar -xz -C "${HOME}/pw/software"
fi
```

### Pulling Containers via Git LFS

```bash
# In setup.sh (runs on controller with internet)
if ! git lfs version >/dev/null 2>&1; then
    # Install Git LFS if needed
    bash ~/singularity-containers/scripts/sif_parts.sh install-lfs
fi

# Clone/pull containers
CONTAINER_DIR="${HOME}/singularity-containers"
if [ ! -d "${CONTAINER_DIR}/.git" ]; then
    GIT_LFS_SKIP_SMUDGE=1 git clone \
        https://github.com/your-org/singularity-containers.git "${CONTAINER_DIR}"
    cd "${CONTAINER_DIR}"
    git lfs install
fi
git lfs pull --include="my-container/*"
```

### Using a Container in start.sh

```bash
# In start.sh (runs on compute node, uses container from setup.sh)
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
# Run all tests
pytest -v

# Run specific test file
pytest tests/test_workflow_yaml.py
pytest tests/test_start_script.py
```

See [tests/README.md](tests/README.md) for details on test coverage and adding tests for new workflows.

## Platform Documentation

- [Interactive Sessions](https://parallelworks.com/docs/workflows/interactive-sessions)
- [Creating Workflows](https://parallelworks.com/docs/workflows/creating-workflows)
- [Form Configuration](https://parallelworks.com/docs/workflows/creating-workflows#form-configuration)
