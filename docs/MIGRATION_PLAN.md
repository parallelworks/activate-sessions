# VNC Server Workflow Migration Plan

## Overview

Migrating the VNC server workflow from the legacy `interactive_session` repository to the new `activate-sessions` repository format. This establishes the pattern for migrating subsequent workflows.

**Source:**
- Workflow YAML: `~/interactive_session/workflow/yamls/vncserver/general_v4.yaml`
- Scripts: `~/interactive_session/vncserver/`

**Target:**
- `workflows/vncserver/workflow.yaml`
- `workflows/vncserver/setup.sh` - Controller setup (downloads, containers)
- `workflows/vncserver/start.sh` - Compute node service startup
- Supporting scripts in `workflows/vncserver/`

---

## Key Differences Between Legacy and New Format

| Aspect | Legacy (`general_v4.yaml`) | New (`hello-world`) |
|--------|---------------------------|---------------------|
| Job Submitter | `marketplace/script_submitter/v3.5` | `marketplace/job_runner/v4.0` |
| Script Structure | 3 separate scripts (controller, start, kill) | 2 scripts: `setup.sh` + `start.sh` |
| Controller/Compute Split | `controller-v3.sh` → controller, `start-template-v3.sh` → compute | `setup.sh` → controller (preprocessing), `start.sh` → compute (session_runner) |
| Script Location | `parallelworks/interactive_session` repo | `parallelworks/activate-sessions` repo |
| Coordination Files | Mixed custom logic | Standardized via `utils/wait_service.sh` |
| Session URL | Custom slug with embedded password | Same (preserved for autoconnect) |
| Cleanup | Separate `cleanup` job with branches | Handled by `trap EXIT` in scripts |

---

## Migration Steps

### Step 1: Create New Workflow Directory

```bash
mkdir -p /home/mattshax/activate-sessions/workflows/vncserver
```

### Step 2: Create Simplified `workflow.yaml`

The new workflow follows the hello-world pattern with 5 jobs:

1. **preprocessing** - Checkout scripts, run `setup.sh` on controller
2. **session_runner** - Submit `start.sh` to compute node via `marketplace/job_runner/v4.0`
3. **wait_for_service** - Wait for VNC to be ready
4. **update_session** - Configure session proxy with custom slug
5. **complete** - Display connection info

Key changes from legacy:
- Move SSH config to job level (not per-step)
- Call `setup.sh` explicitly in preprocessing
- Remove inline script generation
- Use `utils/wait_service.sh` for coordination

### Step 3: Create Two-Script Structure

The legacy has 3 scripts that map to 2 new scripts:

| Legacy Script | Runs On | New Script | Purpose |
|--------------|---------|------------|---------|
| `controller-v3.sh` | Controller | `setup.sh` | Download noVNC, containers via Git LFS |
| `start-template-v3.sh` | Compute | `start.sh` | Start VNC server, noVNC proxy, desktop |
| `kill-template.sh` | Both | (in `start.sh`) | Cleanup via `trap EXIT` |

**Why this split?**
- Controller nodes have internet access for downloads
- Compute nodes may be isolated (no internet, limited storage)
- Shared resources (noVNC, containers) persist across jobs

New structure:
```
workflows/vncserver/
├── workflow.yaml          # Main workflow definition
├── setup.sh               # Controller: downloads, containers, Git LFS
├── start.sh               # Compute: VNC server, noVNC proxy, desktop
├── README.md              # Workflow documentation
└── thumbnail.png          # VNC icon
```

### Step 4: Define Input Schema

Legacy inputs (simplified):
- `cluster.resource` - Compute cluster selection
- `cluster.scheduler` - Boolean for scheduler vs controller
- `cluster.slurm.*` - SLURM directives
- `cluster.pbs.*` - PBS directives
- `service.novnc_parent_install_dir` - noVNC install location
- `service.novnc_tgz_basename` - noVNC tarball name

New inputs (streamlined):
- `resource` - Auto-detected schedulerType
- `vnc.*` - VNC-specific settings

### Step 5: Handle VNC Password and URL

Preserve the legacy approach with custom slug containing embedded password:
```
vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&password=${password}&host=${PW_PLATFORM_HOST}${basepath}/&dt=0
```

Implementation:
- Generate password in `preprocessing` job
- Pass to `start.sh` via inputs.sh (shared filesystem)
- Include slug in `update_session` call for autoconnect

---

## Workflow Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ preprocessing (controller node)                                 │
├─────────────────────────────────────────────────────────────────┤
│ 1. Checkout scripts from activate-sessions repo                 │
│ 2. Run setup.sh →                                               │
│    - Download noVNC from GitHub                                 │
│    - Install Git LFS if needed                                  │
│    - Pull containers (nginx, vncserver) via LFS                 │
│ 3. Generate VNC password, build slug                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ session_runner (compute node via SLURM/PBS)                     │
├─────────────────────────────────────────────────────────────────┤
│ 1. Execute start.sh →                                           │
│    - Detect VNC type (TigerVNC/TurboVNC/KasmVNC/container)      │
│    - Find available display/port                                │
│    - Start VNC server with password                             │
│    - Start noVNC proxy                                          │
│    - Write HOSTNAME, SESSION_PORT, job.started                  │
│ 2. Wait for workflow cancellation                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ wait_for_service (controller node)                              │
├─────────────────────────────────────────────────────────────────┤
│ - Wait for job.started file                                     │
│ - Read HOSTNAME and SESSION_PORT                                │
│ - Verify service is responding                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ update_session (controller node)                                │
├─────────────────────────────────────────────────────────────────┤
│ - Allocate local port for proxy                                 │
│ - Configure session with custom slug (embedded password)        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ complete (controller node)                                      │
├─────────────────────────────────────────────────────────────────┤
│ - Display connection URL                                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Detailed File Structure

### workflows/vncserver/workflow.yaml

```yaml
# yaml-language-server: $schema=https://activate.parallel.works/workflow.schema.json
---
permissions:
  - "*"
sessions:
  session:
    useTLS: false
    redirect: true   # VNC uses redirect with custom slug

jobs:
  preprocessing:
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Checkout service scripts
        uses: parallelworks/checkout
        with:
          repo: https://github.com/parallelworks/activate-sessions.git
          branch: main
          sparse_checkout:
            - workflows/${{ inputs.workflow_dir }}
            - utils

      - name: Generate password and slug
        run: |
          # Generate random password
          password=$(openssl rand -base64 12 | head -c 12)
          echo "password=${password}" | tee -a $OUTPUTS

          # Build basepath
          basepath=/me/session/${PW_USER}/${{ sessions.session }}

          # Build slug with embedded password (for autoconnect)
          if [ -z "${PW_PLATFORM_HOST}" ]; then
            PW_PLATFORM_HOST=activate.parallel.works
          fi
          slug="vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&password=${password}&host=${PW_PLATFORM_HOST}${basepath}/&dt=0"
          echo "slug=${slug}" | tee -a $OUTPUTS

  session_runner:
    needs: [preprocessing]
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Submit session script
        uses: marketplace/job_runner/v4.0
        with:
          resource: ${{ inputs.resource }}
          rundir: "${PW_PARENT_JOB_DIR}"
          scheduler: ${{ inputs.resource.schedulerType != '' }}
          use_existing_script: true
          script_path: "${PW_PARENT_JOB_DIR}/workflows/${{ inputs.workflow_dir }}/start.sh"

      - name: Notify job ended
        run: touch job.ended

  wait_for_service:
    needs: [preprocessing]
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Wait for VNC ready
        run: |
          # Source the reusable wait script
          source utils/wait_service.sh

  update_session:
    needs: [wait_for_service]
    ssh:
      remoteHost: ${{ inputs.resource.ip }}
    steps:
      - name: Get local port
        run: |
          local_port=$(pw agent open-port)
          echo "local_port=${local_port}" | tee -a $OUTPUTS

      - name: Update session with custom slug
        uses: parallelworks/update-session
        with:
          target: ${{ inputs.resource.id }}
          name: ${{ sessions.session }}
          slug: ${{ needs.preprocessing.outputs.slug }}
          remoteHost: ${{ needs.wait_for_service.outputs.HOSTNAME }}
          remotePort: ${{ needs.wait_for_service.outputs.SESSION_PORT }}
          local_port: ${{ needs.update_session.outputs.local_port }}

  complete:
    needs: [update_session]
    steps:
      - name: Display connection info
        run: |
          basepath="/me/session/${PW_USER}/${{ sessions.session }}"
          echo "=========================================="
          echo "VNC Session is ready!"
          echo "=========================================="
          echo "  Connect via: ${PW_PLATFORM_HOST}${basepath}/"
          echo "=========================================="

"on":
  execute:
    inputs:
      resource:
        type: compute-clusters
        label: Service host
        include-workspace: false
        autoselect: true

      workflow_dir:
        type: string
        default: vncserver
        hidden: true

      vnc:
        type: group
        label: VNC Settings
        items:
          desktop:
            type: dropdown
            label: Desktop Environment
            default: auto
            options:
              - label: Auto-detect
                value: auto
              - label: GNOME
                value: gnome
              - label: XFCE
                value: xfce
              - label: MATE
                value: mate
          resolution:
            type: dropdown
            label: Screen Resolution
            default: 1280x1024
            options:
              - {label: "1280x1024", value: "1280x1024"}
              - {label: "1920x1080", value: "1920x1080"}
```

### workflows/vncserver/setup.sh (Controller)

```bash
#!/bin/bash
set -e

# 1. Download noVNC from GitHub releases
NOVNC_VERSION="v1.6.0"
NOVNC_INSTALL_DIR="${HOME}/pw/software/noVNC-${NOVNC_VERSION}"
if [ ! -d "${NOVNC_INSTALL_DIR}" ]; then
    echo "Downloading noVNC ${NOVNC_VERSION}..."
    mkdir -p "${HOME}/pw/software"
    curl -L "https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_VERSION}.tar.gz" | \
        tar -xz -C "${HOME}/pw/software"
fi

# 2. Ensure Git LFS is available
if ! git lfs version >/dev/null 2>&1; then
    echo "Git LFS not found, installing..."
    git clone --depth 1 https://github.com/parallelworks/singularity-containers.git \
        ~/singularity-containers-tmp || true
    bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs
    rm -rf ~/singularity-containers-tmp
fi

# 3. Pull containers via Git LFS
CONTAINER_DIR="${HOME}/singularity-containers"
if [ ! -d "${CONTAINER_DIR}/.git" ]; then
    echo "Cloning singularity-containers repo..."
    GIT_LFS_SKIP_SMUDGE=1 git clone \
        https://github.com/parallelworks/singularity-containers.git "${CONTAINER_DIR}"
    cd "${CONTAINER_DIR}"
    git lfs install
fi

cd "${CONTAINER_DIR}"
if [ ! -f "vnc/vncserver.sif" ]; then
    echo "Pulling vncserver container..."
    git lfs pull --include="vnc/*"
fi
if [ ! -f "nginx/nginx-unprivileged.sif" ]; then
    echo "Pulling nginx container..."
    git lfs pull --include="nginx/*"
fi

# 4. Write setup complete marker
touch SETUP_COMPLETE
```

### workflows/vncserver/start.sh (Compute Node)

```bash
#!/bin/bash
set -e

# 1. Source inputs (includes password from preprocessing)
[[ -f inputs.sh ]] && source inputs.sh

# 2. Verify setup completed
if [ ! -f SETUP_COMPLETE ]; then
    echo "ERROR: setup.sh did not complete successfully" >&2
    exit 1
fi

# 3. VNC detection and configuration
#    - Detect VNC type (TigerVNC, TurboVNC, KasmVNC, or container)
#    - Find available display port

# 4. Desktop environment setup
#    - Auto-detect or use user selection (gnome, xfce, mate, etc.)

# 5. Start VNC server
#    - Use password from inputs.sh
#    - Start VNC with password

# 6. Start noVNC proxy
#    - Start websockify/novnc_proxy
#    - Get proxy port

# 7. Write coordination files
echo "${proxy_port}" > SESSION_PORT
hostname > HOSTNAME
touch job.started

# 8. Cleanup trap
cleanup() {
    ${service_vnc_exec} -kill ${DISPLAY}
    # Kill child processes
}
trap cleanup EXIT INT TERM

# 9. Keep script running
sleep inf
```

**Key Changes from Legacy:**

| Legacy | New |
|--------|-----|
| `controller-v3.sh` (150 lines) | `setup.sh` - downloads, Git LFS, containers |
| `start-template-v3.sh` (670 lines) | `start.sh` - VNC server, noVNC proxy, desktop |
| `kill-template.sh` (12 lines) | `trap EXIT` in `start.sh` |
| Sparse checkout for downloads | Direct curl + Git LFS from ~/singularity-containers |

---

## Container Pulling via Git LFS

The VNC workflow needs to pull Singularity containers from the `~/singularity-containers` repo:

```
~/singularity-containers/
├── nginx/
│   └── nginx-unprivileged.sif    (~68MB)
└── vnc/
    └── vncserver.sif             (~1.2GB)
```

### Pulling Containers in start.sh

```bash
# 1. Ensure Git LFS is available
if ! git lfs version >/dev/null 2>&1; then
    echo "Git LFS not found, installing..."
    # Clone singularity-containers repo (shallow, LFS pointers only)
    git clone --depth 1 https://github.com/parallelworks/singularity-containers.git ~/singularity-containers-tmp || true
    # Install LFS using the script from that repo
    bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs
    rm -rf ~/singularity-containers-tmp
fi

# 2. Clone/pull containers repo (if not already present)
CONTAINER_DIR="${HOME}/singularity-containers"
if [ ! -d "${CONTAINER_DIR}/.git" ]; then
    echo "Cloning singularity-containers repo..."
    GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/parallelworks/singularity-containers.git "${CONTAINER_DIR}"
    cd "${CONTAINER_DIR}"
    git lfs install
fi

# 3. Pull required containers
cd "${CONTAINER_DIR}"
if [ ! -f "vnc/vncserver.sif" ]; then
    echo "Pulling vncserver container..."
    git lfs pull --include="vnc/*"
fi

if [ ! -f "nginx/nginx-unprivileged.sif" ]; then
    echo "Pulling nginx container..."
    git lfs pull --include="nginx/*"
fi

# 4. Use the containers
export SINGULARITY_VNC_CONTAINER="${CONTAINER_DIR}/vnc/vncserver.sif"
export SINGULARITY_NGINX_CONTAINER="${CONTAINER_DIR}/nginx/nginx-unprivileged.sif"
```

### noVNC Download from GitHub

```bash
NOVNC_VERSION="v1.6.0"
NOVNC_INSTALL_DIR="${HOME}/pw/software/noVNC-${NOVNC_VERSION}"

if [ ! -d "${NOVNC_INSTALL_DIR}" ]; then
    echo "Downloading noVNC ${NOVNC_VERSION}..."
    mkdir -p "${HOME}/pw/software"
    curl -L "https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_VERSION}.tar.gz" | tar -xz -C "${HOME}/pw/software"
fi

# Use noVNC
cd "${NOVNC_INSTALL_DIR}"
./utils/novnc_proxy --vnc ${HOSTNAME}:${displayPort} --listen ${HOSTNAME}:${service_port}
```

---

## Script Consolidation Details

### From controller-v3.sh (150 lines)

**Functions to migrate:**
- `download_and_install_novnc()` - Keep as is
- `download_singularity_container()` - Keep as is
- `download_oras()` / `oras_pull_file()` - Keep as is

**Logic to include in start.sh setup phase:**
1. Create `service_parent_install_dir` (default: `$HOME/pw/software`)
2. Download noVNC if not present
3. Download nginx container if needed

### From start-template-v3.sh (670 lines)

**Major sections:**
1. **Lines 1-35**: Port finding logic - **KEEP**, simplify
2. **Lines 36-210**: VNC type detection (TigerVNC/TurboVNC/KasmVNC/Singularity) - **KEEP**
3. **Lines 211-349**: TigerVNC startup - **KEEP**
4. **Lines 350-368**: SingularityTurboVNC startup - **KEEP**
5. **Lines 369-647**: KasmVNC startup with nginx proxy - **KEEP**

**Simplifications:**
- Remove inline cancel.sh generation (use trap instead)
- Remove `jobschedulertype` checks (handled by job_runner)
- Consolidate desktop detection into function

### From kill-template.sh (12 lines)

**Replace with:**
```bash
cleanup() {
    # Kill VNC server
    ${service_vnc_exec} -kill ${DISPLAY}
    # Kill child processes
    kill $(cat ${resource_jobdir}/service.pid) 2>/dev/null || true
    # Clean up .vnc files
    rm -f ~/.vnc/${HOSTNAME}${DISPLAY}.*
}
trap cleanup EXIT INT TERM
```

---

## Design Decisions

1. **Session URL Format**: Keep the legacy approach with custom slug containing embedded password:
   ```
   vnc.html?resize=remote&autoconnect=true&show_dot=true&path=websockify&password=${password}&host=${PW_PLATFORM_HOST}${basepath}/&dt=0
   ```
   This maintains backward compatibility and seamless user experience.

2. **noVNC Download**: Use external GitHub release links (not in repo):
   - https://github.com/novnc/noVNC/archive/refs/tags/v1.6.0.tar.gz
   - Download on-demand, cache in `service_parent_install_dir`

3. **VNC Container Support**: Keep container fallback using Git LFS:
   - Pull containers from `~/singularity-containers` repo
   - Required containers:
     - `nginx/nginx-unprivileged.sif` (~68MB)
     - `vnc/vncserver.sif` (~1.2GB)
   - Auto-install Git LFS if not available using `scripts/sif_parts.sh install-lfs`

4. **KasmVNC vs noVNC**: Keep all VNC type support (TigerVNC, TurboVNC, KasmVNC, SingularityTurboVNC)

---

## Testing Checklist

After migration, test:

- [ ] Controller mode (no scheduler)
- [ ] SLURM submission
- [ ] PBS submission
- [ ] TigerVNC detection and startup
- [ ] TurboVNC detection and startup
- [ ] KasmVNC detection and startup
- [ ] Password generation and display
- [ ] Session connection via proxy
- [ ] Cleanup on workflow cancellation
- [ ] Desktop environment auto-detection

---

## Future Workflow Migrations

After completing VNC server, use this pattern for:

1. **Jupyter** - `~/interactive_session/workflow/yamls/jupyter/general_v4.yaml`
2. **Code Server** - `~/interactive_session/workflow/yamls/code-server/general_v4.yaml`
3. **Desktop (GNOME/KDE)** - Similar to VNC but different desktop setup

Each migration should:
1. Copy hello-world as starting point
2. Consolidate 2-3 legacy scripts into single `start.sh`
3. Follow 5-job pattern
4. Use `utils/wait_service.sh` or create custom wait variant
5. Document any unique requirements in workflow README
