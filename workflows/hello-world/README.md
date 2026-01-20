# Hello World Workflow

A minimal interactive session workflow for the Parallel Works ACTIVATE platform. This workflow starts a simple Python HTTP server that displays a customizable greeting message.

## Purpose

This is the **template workflow** for creating new interactive sessions. It demonstrates:
1. **Two-script pattern** - Separate setup (controller) vs start (compute) scripts
2. **Controller/Compute separation** - Downloads on controller, service on compute
3. **Minimal workflow structure** - 5 jobs: preprocessing → session_runner → wait → update → complete

## Two-Script Pattern

| Script | Runs On | When | Purpose |
|--------|---------|------|---------|
| `setup.sh` | Controller/login node | session_runner, step 1 | Download dependencies, install containers, prepare shared resources |
| `start.sh` | Compute node (or controller if no scheduler) | session_runner, step 2 (via job_runner) | Start the service, write coordination files, keep session alive |

**Why separate them?**
- Controller nodes typically have internet access; compute nodes often don't
- Downloads should happen once (controller) before submitting to compute
- Shared resources (containers, software installs) persist across jobs

## Workflow Execution Flow

```
preprocessing
├── Checkout scripts from git
└── Transfer user inputs

session_runner (runs sequentially on controller)
├── Step 1: Run setup.sh (on controller) → downloads, installs, prepares
└── Step 2: Submit start.sh (to compute node via scheduler) → starts service

wait_for_service
└── Wait for job.started, HOSTNAME, SESSION_PORT

update_session
└── Configure session proxy

complete
└── Display connection info
```

**Key point**: `setup.sh` runs in step 1 of `session_runner` on the controller. `start.sh` is submitted to the compute node in step 2 via `marketplace/job_runner/v4.0`.

## Files

| File | Purpose |
|------|---------|
| [workflow.yaml](workflow.yaml) | Main workflow definition |
| [setup.sh](setup.sh) | Controller setup script (runs first in session_runner) |
| [start.sh](start.sh) | Compute node startup script (submitted via job_runner) |

## How It Works

**setup.sh** (runs on controller, step 1 of session_runner):
- Verifies Python is available
- Creates shared logs directory
- Writes `SETUP_COMPLETE` marker

**start.sh** (runs on compute node, step 2 of session_runner):
- Verifies setup completed successfully
- Allocates an available port
- Writes coordination files (`HOSTNAME`, `SESSION_PORT`, `job.started`)
- Serves HTML page via Python HTTP server
- Keeps running until workflow is cancelled

## Creating Your Own Workflow

Copy this directory as a starting point:

```bash
cp -r workflows/hello-world workflows/my-service
```

Then edit:
- `workflow.yaml` - Update inputs, repo paths, session names
- `setup.sh` - Add your controller-side setup (downloads, container pulls)
- `start.sh` - Add your compute-side service startup logic

### What Goes in setup.sh vs start.sh?

**setup.sh** (controller, step 1):
```bash
# Download software from GitHub
curl -L https://github.com/example/tool/archive/refs/tags/v1.0.tar.gz | tar -xz

# Pull containers via Git LFS
git lfs pull --include="my-container/*"

# Install shared dependencies
pip install --user some-package
```

**start.sh** (compute node, step 2):
```bash
# Use resources prepared by setup.sh
source ~/.local/bin/activate
singularity exec ~/singularity-containers/my-container/*.sif python app.py

# Write coordination files
hostname > HOSTNAME
echo $PORT > SESSION_PORT
touch job.started
```

See [DEVELOPER_GUIDE.md](../../docs/DEVELOPER_GUIDE.md) for details.
