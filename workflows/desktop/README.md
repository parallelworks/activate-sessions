# Desktop Workflow

Interactive remote desktop session workflow for the Parallel Works ACTIVATE platform. Provides a full graphical desktop environment accessible through a web browser via VNC.

## Purpose

This workflow provides a complete remote desktop experience with support for:
- **Multiple VNC types** - TigerVNC, TurboVNC, KasmVNC, and Singularity containers
- **Multiple desktop environments** - Auto-detects GNOME, XFCE, MATE, Cinnamon, KDE Plasma, LXDE
- **Auto-connect** - Embeds password in URL for seamless connection
- **Fallback container** - Uses Singularity container if no VNC server installed (downloaded only when needed)

## Two-Script Pattern

| Script | Runs On | When | Purpose |
|--------|---------|------|---------|
| `setup.sh` | Controller/login node | session_runner, step 1 | Download noVNC, pull nginx container via Git LFS, generate password |
| `start.sh` | Compute node (or controller if no scheduler) | session_runner, step 2 (via job_runner) | Detect VNC type, start VNC server, start noVNC proxy |

## Workflow Execution Flow

```
preprocessing
├── Checkout scripts from git
└── Transfer user inputs

session_runner (runs sequentially on controller)
├── Step 1: Run setup.sh (on controller)
│   ├── Download noVNC from GitHub
│   ├── Install Git LFS (if needed)
│   ├── Pull nginx container via Git LFS
│   └── Generate VNC password and connection slug
└── Step 2: Submit start.sh (to compute node via scheduler)
    ├── Detect VNC type (TigerVNC/TurboVNC/KasmVNC/container)
    ├── Find available display/port
    ├── Start VNC server with password
    └── Start noVNC proxy

wait_for_service
└── Wait for job.started, read HOSTNAME and SESSION_PORT

update_session
└── Configure session proxy with custom slug (embedded password)

complete
└── Display connection URL
```

## Files

| File | Purpose |
|------|---------|
| [workflow.yaml](workflow.yaml) | Main workflow definition with desktop-specific inputs |
| [setup.sh](setup.sh) | Controller setup: downloads noVNC, pulls nginx container, generates password |
| [start.sh](start.sh) | Compute node startup: VNC detection, server startup, noVNC proxy |

## How It Works

**setup.sh** (runs on controller, step 1 of session_runner):
1. Downloads noVNC v1.6.0 from GitHub releases
2. Installs Git LFS if not available
3. Pulls nginx container via Git LFS for KasmVNC support (~68MB)
4. Generates random VNC password (12 alphanumeric characters)
5. Builds connection slug with embedded password for autoconnect
6. Writes `SETUP_COMPLETE` and `VNC_PASSWORD` files

**start.sh** (runs on compute node, step 2 of session_runner):
1. Verifies setup completed successfully
2. Finds available display port (5901-5999)
3. Detects VNC type:
   - GAEA systems: `/usr/lib/vncserver`
   - System-installed: `which vncserver`
   - Fallback: Downloads and uses Singularity container (~1.2GB)
4. Auto-detects desktop environment (GNOME, XFCE, MATE, etc.)
5. Starts VNC server with generated password
6. Starts noVNC proxy on service port
7. Writes coordination files (`HOSTNAME`, `SESSION_PORT`, `job.started`)
8. Runs cleanup via `trap EXIT` when workflow ends

## VNC Type Support

| VNC Type | Detection Method | Notes |
|----------|------------------|-------|
| TigerVNC | `vncserver -list` output | Most common on HPC systems |
| TurboVNC | `vncserver -list` output | Alternative VNC server |
| KasmVNC | `vncserver -list` output | Built-in web client, uses nginx proxy |
| Singularity | Fallback via container | Downloaded only when no VNC server installed |

## Desktop Environment Support

Auto-detects in order of preference:
1. GNOME (`gnome-session`)
2. MATE (`mate-session`)
3. XFCE (`xfce4-session`)
4. Cinnamon (`cinnamon-session`)
5. KDE Plasma (`startplasma-x11`)
6. LXDE (`startlxde`)
7. LXQt (`lxqt-session`)
8. IceWM (`icewm-session`)

Can also be manually specified via `desktop.environment` input.

## Container Locations

Resources are cached in shared locations:

```
~/pw/software/
└── noVNC-v1.6.0/              # Downloaded from GitHub

~/pw/singularity/
├── nginx.sif                   # Git LFS sparse checkout (for KasmVNC)
└── vncserver.sif               # Git LFS sparse checkout (fallback only)
```

The vncserver container (~1.2GB) is only downloaded if no VNC server is installed on the system.

## Connection URL Format

The workflow generates a custom slug with embedded password for autoconnect:

```
vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&password={password}&host={platform}{basepath}/&dt=0
```

This format is preserved from the legacy workflow for backward compatibility.

## Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `resource` | compute-clusters | auto-select | Service host cluster |
| `desktop.environment` | dropdown | auto | Desktop environment (auto/gnome/xfce/mate/cinnamon/kde/lxde) |

## Migration Notes

This workflow migrates from `interactive_session/workflow/yamls/vncserver/general_v4.yaml` with the following changes:

| Legacy | New |
|--------|-----|
| `controller-v3.sh` (150 lines) | `setup.sh` - downloads via Git LFS |
| `start-template-v3.sh` (670 lines) | `start.sh` - VNC server, noVNC proxy |
| `kill-template.sh` (12 lines) | `trap EXIT` in `start.sh` |
| Sparse checkout for downloads | Direct curl + Git LFS |
| `script_submitter/v3.5` | `job_runner/v4.0` |
| vncserver name | `desktop` name (supports multiple VDI types) |

See [MIGRATION_PLAN.md](../../docs/MIGRATION_PLAN.md) for details.
