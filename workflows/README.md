# Workflows

Interactive session workflow templates for the Parallel Works ACTIVATE platform.

## Creating a New Workflow

1. **Copy the template**
   ```bash
   cp -r workflows/hello-world workflows/my-service
   ```

2. **Edit the files**
   - `workflow.yaml` - Workflow definition (inputs, jobs, session config)
   - `setup.sh` - Controller setup (downloads, dependencies)
   - `start.sh` - Service startup (runs on compute node)

## Workflow Structure

Each workflow follows this structure:

```
workflows/
└── my-service/
    ├── workflow.yaml         # Workflow definition
    ├── setup.sh              # Controller setup script
    ├── start.sh              # Compute node service script
    ├── README.md             # Workflow documentation
    └── thumbnail.png         # Workflow icon (optional)
```

See [hello-world](hello-world/) for a complete working example.

## The Two-Script Pattern

Workflows use two scripts that run at different stages:

| Script | Runs On | Purpose |
|--------|---------|---------|
| `setup.sh` | Controller/login node | Download software, pull containers, prepare shared resources |
| `start.sh` | Compute node | Start the service, write coordination files, keep session alive |

**Why two scripts?** Controller nodes have internet access; compute nodes often don't. Downloads should happen once on the controller before submitting to compute.

## Multiple Configurations

You can create multiple workflow YAMLs that share the same scripts:

```
workflows/my-service/
├── workflow.yaml       # Default configuration
├── slurm.yaml          # SLURM-specific configuration
├── pbs.yaml            # PBS-specific configuration
├── setup.sh            # Shared setup script
└── start.sh            # Shared service script
```

Each YAML can have different inputs, scheduler settings, or job parameters while using the same scripts.

## Workflow Jobs

Each workflow follows this 5-job pattern:

1. **preprocessing** - Checkout scripts from git, run `setup.sh`
2. **session_runner** - Submit `start.sh` to compute node via job_runner
3. **wait_for_service** - Wait for service to be ready
4. **update_session** - Configure session proxy
5. **complete** - Display connection info

## Coordination Files

Your `start.sh` script creates these files to coordinate with the platform:

| File | Purpose |
|------|---------|
| `HOSTNAME` | Hostname where service is running |
| `SESSION_PORT` | Port the service listens on |
| `job.started` | Signals service is ready |

See [hello-world](hello-world/) for a complete working example, or [DEVELOPER_GUIDE.md](../DEVELOPER_GUIDE.md) for detailed instructions.
