# Hello World Workflow

A minimal interactive session workflow for the Parallel Works ACTIVATE platform. This workflow starts a simple Python HTTP server that displays a customizable greeting message.

## Purpose

This is the **template workflow** for creating new interactive sessions. It demonstrates the minimal pattern:
1. Checkout service scripts from git
2. Submit job via `marketplace/job_runner/v4.0` (Controller/SLURM/PBS)
3. Wait for service to be ready
4. Configure session proxy
5. Display connection info

## Usage

1. Select a compute resource
2. Customize the greeting message (optional, default: "Hello World")
3. Execute the workflow
4. Open the session URL when ready

## Files

| File | Purpose |
|------|---------|
| [workflow.yaml](workflow.yaml) | Main workflow definition |
| [start.sh](start.sh) | Service startup script |

## How It Works

The `start.sh` script:

1. Allocates an available port using Python
2. Writes coordination files (`HOSTNAME`, `SESSION_PORT`, `job.started`)
3. Serves a simple HTML page via Python HTTP server
4. Keeps running until the workflow is cancelled

## Creating Your Own Workflow

Copy this directory as a starting point:

```bash
cp -r workflows/hello-world workflows/my-service
```

Then edit:
- `workflow.yaml` - Update inputs, repo paths, session names
- `start.sh` - Replace with your service startup logic

See [DEVELOPER_GUIDE.md](../../../DEVELOPER_GUIDE.md) for details.
