# activate-sessions

ACTIVATE interactive session workflow templates for Parallel Works. Each workflow launches a service (Jupyter, desktop, web app, etc.), waits for it to be ready, and exposes it through the platform session proxy.

## Quick Start

1. **Copy the template**
   ```bash
   cp -r workflows/hello-world workflows/my-service
   ```

2. **Edit the workflow**
   - `workflows/my-service/workflow.yaml` - Main workflow definition
   - `workflows/my-service/start.sh` - Your service startup script

3. **Run through the ACTIVATE platform**

For platform usage details, see:
- [Sessions Documentation](https://parallelworks.com/docs/run/sessions)
- [Building Workflows](https://parallelworks.com/docs/run/workflows-and-apps/building-workflows)

## Repository Layout

```
activate-sessions/
├── workflows/
│   └── hello-world/          # Example workflow (template)
│       ├── workflow.yaml      # Workflow definition
│       ├── start.sh           # Service startup script
│       ├── README.md          # Workflow docs
│       └── thumbnail.png      # Workflow icon
├── utils/
│   └── wait_service.sh        # Shared wait coordination script
├── tests/                     # Pytest tests
│   ├── test_workflow_yaml.py  # YAML validation
│   ├── test_start_script.py   # Script validation
│   └── README.md              # Test documentation
├── .gitignore
├── LICENSE
├── README.md                  # This file
└── DEVELOPER_GUIDE.md         # Detailed guide
```

## How It Works

The session workflow pattern uses marketplace utilities:

1. **preprocessing** - Checkout service scripts from repo
2. **session_runner** - Uses `marketplace/job_runner/v4.0` to submit SLURM/PBS/SSH job
3. **wait_for_service** - Waits for service to be ready
4. **update_session** - Configures the session proxy
5. **complete** - Displays connection URLs

Your `start.sh` script only needs to:
1. Allocate a port
2. Start your service
3. Write `HOSTNAME` and `SESSION_PORT` files
4. Create a `job.started` file

See [hello-world/start.sh](workflows/hello-world/start.sh) for a minimal example.

## Running Tests

```bash
pytest -v
```

## License

MIT
