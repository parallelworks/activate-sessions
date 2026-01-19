# Workflows

Interactive session workflow templates for Parallel Works ACTIVATE.

## Creating a New Workflow

Copy the `hello-world` example as a template:

```bash
cp -r workflows/hello-world workflows/my-service
```

Then edit:
- `workflows/my-service/workflow.yaml` - Workflow definition
- `workflows/my-service/start.sh` - Service startup script

## Workflow Structure

```
workflows/
└── hello-world/              # Example workflow (template)
    ├── workflow.yaml         # Main workflow definition
    ├── start.sh              # Service startup script
    ├── README.md             # Workflow documentation
    └── thumbnail.png         # Workflow icon
```

## Multiple Configurations

You can create multiple workflow YAMLs that share the same service script:

```
workflows/my-service/
├── workflow.yaml       # Default configuration
├── slurm.yaml          # SLURM-specific configuration
├── pbs.yaml            # PBS-specific configuration
└── start.sh            # Shared service script
```

Each YAML can have different inputs, scheduler settings, or job parameters while using the same `start.sh`.

## Key Concepts

Each workflow follows this pattern:

1. **preprocessing** - Checkout service scripts from git
2. **session_runner** - Submit job via `marketplace/job_runner/v4.0`
3. **wait_for_service** - Wait for service to be ready
4. **update_session** - Configure session proxy
5. **complete** - Display connection info

Your `start.sh` script only needs to:
1. Allocate a port
2. Start your service
3. Write `HOSTNAME` and `SESSION_PORT` files
4. Create `job.started` file

See [hello-world](hello-world/) for a complete working example.
