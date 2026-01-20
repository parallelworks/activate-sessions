# ACTIVATE Sessions

Interactive session workflow templates for the Parallel Works ACTIVATE platform. Each workflow launches a service (Jupyter, desktop, web app, etc.), waits for it to be ready, and exposes it through the platform session proxy.

## Quick Start

1. **Copy the template**
   ```bash
   cp -r workflows/hello-world workflows/my-service
   ```

2. **Edit the workflow files**
   - `workflow.yaml` - Workflow definition (inputs, jobs, session config)
   - `setup.sh` - Controller setup script (downloads, dependencies)
   - `start.sh` - Service startup script (runs on compute node)

3. **Run through the ACTIVATE platform**

For platform usage details, see:
- [Sessions Documentation](https://parallelworks.com/docs/run/sessions)
- [Building Workflows](https://parallelworks.com/docs/run/workflows-and-apps/building-workflows)

## Repository Layout

```
activate-sessions/
├── workflows/
│   └── hello-world/           # Template workflow (start here)
│       ├── workflow.yaml      # Workflow definition
│       ├── setup.sh           # Controller setup script
│       ├── start.sh           # Compute node service script
│       └── README.md          # Workflow documentation
├── utils/
│   └── wait_service.sh        # Shared coordination script
├── tests/                     # Pytest validation tests
├── README.md                  # This file
└── DEVELOPER_GUIDE.md         # Detailed development guide
```

## How It Works

### The Two-Script Pattern

Workflows use two scripts that run at different stages:

| Script | Runs On | Purpose |
|--------|---------|---------|
| `setup.sh` | Controller/login node | Download dependencies, pull containers, prepare shared resources |
| `start.sh` | Compute node | Start the service, write coordination files, keep session alive |

**Why two scripts?** Controller nodes typically have internet access while compute nodes often don't. Downloads happen once on the controller before the job is submitted.

### Workflow Jobs

Each workflow follows this 5-job pattern:

1. **preprocessing** - Checkout scripts from git to the remote host
2. **session_runner** - Step 1: runs `setup.sh`, Step 2: submits `start.sh` via job_runner
3. **wait_for_service** - Waits for service to be ready (checks for coordination files)
4. **update_session** - Configures the session proxy
5. **complete** - Displays connection URLs

### Coordination Files

Your `start.sh` script creates these files:
- `HOSTNAME` - The hostname where the service is running
- `SESSION_PORT` - The port the service is listening on
- `job.started` - Signals that the service is ready

See [hello-world](workflows/hello-world/) for a complete working example.

## Running Tests

```bash
pytest -v
```

## Documentation

- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) - Detailed guide for creating workflows
- [workflows/README.md](workflows/README.md) - Workflow directory overview
- [tests/README.md](tests/README.md) - Test documentation

## License

MIT
