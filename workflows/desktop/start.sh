#!/bin/bash
# start.sh - Desktop Startup Script (runs on compute node)
#
# This script runs on the compute node in STEP 2 of the session_runner job.
# It is submitted via marketplace/job_runner/v4.0 (SLURM/PBS) or runs directly
# on the controller if no scheduler is configured.
#
# It uses resources prepared by setup.sh which runs in STEP 1 on the controller.
#
# Creates coordination files:
#   - HOSTNAME     - Target hostname
#   - SESSION_PORT - Allocated port
#   - job.started  - Signals job has started

set -e

[[ "${DEBUG:-}" == "true" ]] && set -x

echo "=========================================="
echo "Desktop Service Starting (Compute Node)"
echo "=========================================="

# =============================================================================
# Source inputs and verify setup
# =============================================================================
# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"

# Ensure we're working from the job directory
cd "${JOB_DIR}"

if [ -f inputs.sh ]; then
  source inputs.sh
fi

# Verify setup completed successfully
if [ ! -f SETUP_COMPLETE ]; then
  echo "ERROR: SETUP_COMPLETE marker not found in ${JOB_DIR}. setup.sh may not have run." >&2
  exit 1
fi

# Read password written by setup.sh
if [ -f VNC_PASSWORD ]; then
  password=$(cat VNC_PASSWORD)
else
  echo "ERROR: VNC_PASSWORD file not found in ${JOB_DIR}" >&2
  exit 1
fi

# =============================================================================
# Configuration - must match paths in setup.sh
# =============================================================================
SERVICE_PARENT_INSTALL_DIR="${HOME}/pw/software"
CONTAINER_DIR="${HOME}/pw/singularity"

# Container paths (downloaded by setup.sh)
SERVICE_NGINX_SIF="${CONTAINER_DIR}/nginx.sif"
SERVICE_VNCSERVER_SIF="${CONTAINER_DIR}/vncserver.sif"

NOVNC_VERSION="v1.6.0"
NOVNC_INSTALL_DIR="${SERVICE_PARENT_INSTALL_DIR}/noVNC-${NOVNC_VERSION}"

# Deactivate conda environments (required for some environments)
if ! [ -z "${CONDA_PREFIX}" ]; then
  echo "Deactivating conda environment"
  source ${CONDA_PREFIX}/etc/profile.d/conda.sh 2>/dev/null || true
  conda deactivate 2>/dev/null || true
  export LD_LIBRARY_PATH=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -v 'conda' | tr '\n' ':' | sed 's/:$//')
fi

# =============================================================================
# Port Allocation - Find available display port
# =============================================================================
find_available_display() {
  local minPort=5901
  local maxPort=5999

  for port in $(seq ${minPort} ${maxPort} | shuf); do
    out=$(netstat -aln 2>/dev/null | grep LISTEN | grep ${port} || true)
    displayNumber=${port: -2}
    XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')

    # Check if port and X display are available
    if [ -z "${out}" ] && ! [ -e /tmp/.X11-unix/X${XdisplayNumber} ] 2>/dev/null && ! [ -e /tmp/.X${XdisplayNumber}-lock ] 2>/dev/null; then
      # Reserve the port
      portFile=/tmp/${port}.port.used
      if ! [ -f "${portFile}" ]; then
        touch ${portFile}
        echo "${port}"
        return 0
      fi
    fi
  done
  return 1
}

displayPort=$(find_available_display)
if [ -z "${displayPort}" ]; then
  echo "ERROR: No available display port found" >&2
  exit 1
fi

displayNumber=${displayPort: -2}
DISPLAY=:$(echo ${displayNumber} | sed 's/^0*//')
XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')

echo "Display port: ${displayPort}"
echo "DISPLAY: ${DISPLAY}"

# =============================================================================
# Get service port
# =============================================================================
if [ -z "${service_port}" ] || [ "${service_port}" == "undefined" ]; then
  service_port=$(pw agent open-port)
fi

if [ -z "${service_port}" ]; then
  echo "ERROR: Failed to allocate service port" >&2
  exit 1
fi

echo "Service port: ${service_port}"

# =============================================================================
# VNC Type Detection
# =============================================================================
service_vnc_exec=""

# Check for GAEA-specific vncserver
if [[ "${HOSTNAME}" == gaea* ]] && [ -f /usr/lib/vncserver ]; then
  service_vnc_exec=/usr/lib/vncserver
  service_vnc_type="TigerVNC"
  mkdir -p ${HOME}/.vnc/
  if [ ! -f "${HOME}/.vnc/config" ]; then
    echo "securitytypes=None" > "${HOME}/.vnc/config"
  else
    if ! grep -Fxq "securitytypes=None" "${HOME}/.vnc/config" 2>/dev/null; then
      echo "securitytypes=None" >> "${HOME}/.vnc/config"
    fi
  fi
fi

# Try to find vncserver in PATH
if [ -z "${service_vnc_exec}" ]; then
  service_vnc_exec=$(which vncserver 2>/dev/null || true)
fi

# Detect VNC type
if [ -n "${service_vnc_exec}" ] && [ -f "${service_vnc_exec}" ]; then
  service_vnc_type=$(${service_vnc_exec} -list 2>/dev/null | grep -oP '(TigerVNC|TurboVNC|KasmVNC)' || echo "")
fi

# Fallback to Singularity container
if [ -z "${service_vnc_type}" ]; then
  if which singularity >/dev/null 2>&1; then
    if [ -f "${SERVICE_VNCSERVER_SIF}" ]; then
      echo "vncserver not installed. Using singularity container from cache..."
      export service_vnc_type="SingularityTurboVNC"
      service_vnc_exec="singularity exec --writable-tmpfs --bind /tmp/.X11-unix:/tmp/.X11-unix --bind ${HOME}:${HOME} ${SERVICE_VNCSERVER_SIF}"
    else
      # Try to download the vncserver container
      echo "vncserver not installed and container not found. Downloading..."
      CONTAINER_DIR="${HOME}/pw/singularity"

      # Ensure Git LFS is available
      if ! git lfs version >/dev/null 2>&1; then
        echo "Git LFS not found, installing..."
        git clone --depth 1 https://github.com/parallelworks/singularity-containers.git \
          ~/singularity-containers-tmp || true
        if [ -d ~/singularity-containers-tmp ]; then
          bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs
          rm -rf ~/singularity-containers-tmp
        fi
      fi

      # Sparse checkout vnc container to tmp, then join and move to cache
      # Check if exists AND is non-empty (LFS pointer files are small)
      if [ ! -f "${CONTAINER_DIR}/vncserver.sif" ] || [ ! -s "${CONTAINER_DIR}/vncserver.sif" ]; then
        echo "Fetching vncserver container via sparse checkout (~1.2GB)..."

        # Remove empty/corrupt file if it exists
        rm -f "${CONTAINER_DIR}/vncserver.sif" 2>/dev/null || true

        # Pull to tmp location first
        TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
        mkdir -p "${TMP_CONTAINER_DIR}"

        cd "${TMP_CONTAINER_DIR}"
        git init
        git remote add origin https://github.com/parallelworks/singularity-containers.git
        git config core.sparseCheckout true
        echo "vnc/*" > .git/info/sparse-checkout
        git lfs install
        git pull origin main
        # Explicitly fetch LFS files (git pull doesn't always do this in sparse checkout)
        git lfs pull

        # Join SIF parts if split, otherwise just copy
        mkdir -p "${CONTAINER_DIR}"

        # Check if there are split parts (vncserver.sif.00, vncserver.sif.01, etc.)
        if compgen -G "vnc/vncserver.sif.*" > /dev/null 2>&1; then
          echo "Joining SIF parts..."
          cat vnc/vncserver.sif.* > "${CONTAINER_DIR}/vncserver.sif"
        elif [ -f "vnc/vncserver.sif" ]; then
          echo "Copying vncserver container..."
          cp vnc/vncserver.sif "${CONTAINER_DIR}/vncserver.sif"
        else
          echo "WARNING: vncserver container not found after pull" >&2
        fi

        cd - >/dev/null
        rm -rf "${TMP_CONTAINER_DIR}"
      fi

      # Use the sif directly from cache
      SERVICE_VNCSERVER_SIF="${CONTAINER_DIR}/vncserver.sif"

      if [ -f "${SERVICE_VNCSERVER_SIF}" ]; then
        echo "Using singularity container..."
        export service_vnc_type="SingularityTurboVNC"
        service_vnc_exec="singularity exec --writable-tmpfs --bind /tmp/.X11-unix:/tmp/.X11-unix --bind ${HOME}:${HOME} ${SERVICE_VNCSERVER_SIF}"
      else
        echo "ERROR: No vncserver command found and Singularity container download failed" >&2
        exit 1
      fi
    fi
  else
    echo "ERROR: No vncserver command found. Supported: TigerVNC, TurboVNC, KasmVNC" >&2
    exit 1
  fi
fi

echo "VNC Type: ${service_vnc_type}"

# =============================================================================
# Desktop Environment Detection
# =============================================================================
detect_desktop() {
  local desktop_environment="${desktop_environment:-auto}"

  if [ "${desktop_environment}" != "auto" ]; then
    echo "${desktop_environment}"
    return 0
  fi

  # Auto-detect desktop environment
  if which gnome-session >/dev/null 2>&1; then
    echo "gnome-session"
  elif which mate-session >/dev/null 2>&1; then
    echo "mate-session"
  elif which xfce4-session >/dev/null 2>&1; then
    echo "xfce4-session"
  elif which cinnamon-session >/dev/null 2>&1; then
    echo "cinnamon-session"
  elif which startplasma-x11 >/dev/null 2>&1 || which plasmashell >/dev/null 2>&1; then
    echo "kde"
  elif which startlxde >/dev/null 2>&1; then
    echo "lxde"
  elif which lxqt-session >/dev/null 2>&1; then
    echo "lxqt"
  elif which icewm-session >/dev/null 2>&1; then
    echo "icewm-session"
  elif which gnome >/dev/null 2>&1; then
    echo "gnome"
  else
    echo "none"
  fi
}

service_desktop=$(detect_desktop)
echo "Desktop Environment: ${service_desktop}"

if [ "${service_desktop}" == "none" ]; then
  echo "WARNING: No desktop environment detected. Session may not display properly." >&2
fi

# =============================================================================
# Start VNC Server based on type
# =============================================================================
# Cleanup function
cleanup() {
  echo "$(date) Cleaning up VNC session..."
  # Kill nginx wrapper if running (for KasmVNC)
  if [ -n "${nginx_pid:-}" ]; then
    kill ${nginx_pid} 2>/dev/null || true
  fi
  # Kill VNC server
  if [ -n "${service_vnc_exec}" ]; then
    ${service_vnc_exec} -kill ${DISPLAY} 2>/dev/null || true
  fi
  # Clean up VNC files
  rm -f ~/.vnc/${HOSTNAME}${DISPLAY}.* 2>/dev/null || true
  rm -f /tmp/.X11-unix/X${XdisplayNumber} 2>/dev/null || true
  rm -f /tmp/${displayPort}.port.used 2>/dev/null || true
}

trap cleanup EXIT INT TERM

mkdir -p ~/.vnc

# =============================================================================
# TigerVNC Startup
# =============================================================================
if [[ "${service_vnc_type}" == "TigerVNC" ]]; then
  echo "Starting TigerVNC..."

  # Set TVNC_WM for mate-session (TurboVNC compatibility)
  if [[ "${service_desktop}" == "mate-session" ]]; then
    export TVNC_WM=mate
  fi

  # Configure xstartup
  if [ -f "${HOME}/.vnc/xstartup" ]; then
    # Disable self-kill in xstartup
    sed -i '/vncserver -kill $DISPLAY/ s/^#*/#/' ~/.vnc/xstartup
  else
    cat > ~/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
EOF
    # Rocky Linux 9 specific fix
    if grep -q 'ID="rocky"' /etc/os-release 2>/dev/null && grep -q 'VERSION_ID="9\.' /etc/os-release 2>/dev/null; then
      echo 'export XDG_SESSION_TYPE=x11' >> ~/.vnc/xstartup
      echo 'export GDK_BACKEND=x11' >> ~/.vnc/xstartup
      echo 'export LIBGL_ALWAYS_SOFTWARE=1' >> ~/.vnc/xstartup
    else
      echo '/etc/X11/xinit/xinitrc' >> ~/.vnc/xstartup
    fi
    chmod +x ~/.vnc/xstartup
  fi

  # Create password file
  printf "${password}\n${password}\n\n" | vncpasswd -f > ${PWD}/.vncpasswd 2>/dev/null
  chmod 600 ${PWD}/.vncpasswd

  # Start VNC server
  if [[ "${HOSTNAME}" == gaea* ]] && [ -f /usr/lib/vncserver ]; then
    ${service_vnc_exec} ${DISPLAY} &> ${PWD}/vncserver.log &
  else
    ${service_vnc_exec} ${DISPLAY} -SecurityTypes VncAuth -PasswordFile ${PWD}/.vncpasswd
  fi

  # Need this to activate pam_systemd when running under SLURM
  if [ -n "${SLURM_JOB_ID}" ]; then
    ssh -N -f localhost &
  fi

  # Setup dconf directory for GNOME
  mkdir -p /run/user/$(id -u)/dconf 2>/dev/null || true
  chmod og+rx /run/user/$(id -u) 2>/dev/null || true
  chmod 0700 /run/user/$(id -u)/dconf 2>/dev/null || true

  # Start desktop environment
  if [[ "${service_desktop}" == "gnome-session" ]]; then
    # Special handling for GNOME with retries
    (
      k=1
      while true; do
        if xset q >/dev/null 2>&1; then
          echo "$(date) X server on $DISPLAY is alive."
          sleep $((k*10))
        else
          echo "$(date) X server on $DISPLAY is unresponsive."
          if [ $k -gt 1 ]; then
            echo "$(date) Restarting vncserver"
            ${service_vnc_exec} -kill ${DISPLAY} 2>/dev/null || true
            sleep 3
            ${service_vnc_exec} ${DISPLAY} -SecurityTypes VncAuth -PasswordFile ${PWD}/.vncpasswd
          fi
          sleep 2
          gnome-session --debug
          sleep $((k*10))
        fi
        k=$((k+1))
      done
    ) &
  else
    eval ${service_desktop} &
  fi

  # Start noVNC proxy
  cd ${NOVNC_INSTALL_DIR}
  ./utils/novnc_proxy --vnc ${HOSTNAME}:${displayPort} --listen ${HOSTNAME}:${service_port} </dev/null &

# =============================================================================
# SingularityTurboVNC Startup
# =============================================================================
elif [[ "${service_vnc_type}" == "SingularityTurboVNC" ]]; then
  echo "Starting Singularity TurboVNC..."

  export TMPDIR=${PWD}/tmp
  mkdir -p $TMPDIR
  mkdir -p /tmp/.X11-unix

  rm -f ~/.vnc/xstartup.turbovnc
  cat > ~/.vnc/xstartup.turbovnc <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
EOF
  chmod +x ~/.vnc/xstartup.turbovnc

  # Create vncserver startup script for container
  cat > ${PWD}/vncserver.sh <<EOF
#!/bin/bash
[[ "\${DEBUG:-}" == "true" ]] && set -x
vncserver -kill ${DISPLAY} 2>/dev/null || true
vncserver ${DISPLAY} -SecurityTypes None
mkdir -p /run/user/\$(id -u)
chown "\$(id -u):\$(id -g)" /run/user/\$(id -u)
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export DISPLAY=${DISPLAY}
export XAUTHORITY="\$HOME/.Xauthority"
mkdir -p \$HOME/.run
export XDG_RUNTIME_DIR=\$HOME/.run
chmod 700 \$HOME/.run
addr=\$(dbus-daemon --session --fork --print-address)
export DBUS_SESSION_BUS_ADDRESS="\$addr"
mkdir -p \${TMPDIR} \${WORKDIR}
mkdir -p "\$HOME/.config"
chmod 700 "\$HOME/.config"
startxfce4 --replace
EOF
  chmod +x ${PWD}/vncserver.sh

  # Start VNC in container
  singularity exec --writable-tmpfs --bind /tmp/.X11-unix:/tmp/.X11-unix --bind ${HOME}:${HOME} ${SERVICE_VNCSERVER_SIF} bash ${PWD}/vncserver.sh &

  # Start noVNC proxy
  cd ${NOVNC_INSTALL_DIR}
  ./utils/novnc_proxy --vnc ${HOSTNAME}:${displayPort} --listen ${HOSTNAME}:${service_port} </dev/null &

# =============================================================================
# KasmVNC Startup (requires nginx wrapper for HTTP->HTTPS proxy)
# =============================================================================
elif [[ "${service_vnc_type}" == "KasmVNC" ]]; then
  echo "Starting KasmVNC..."

  export XDG_RUNTIME_DIR=""

  # KasmVNC serves HTTPS natively, so we need nginx to proxy HTTP -> HTTPS
  # Find an available port for KasmVNC's websocket (different from service_port)
  kasmvnc_port=$(pw agent open-port)
  if [ -z "${kasmvnc_port}" ]; then
    echo "ERROR: Failed to allocate KasmVNC port" >&2
    exit 1
  fi
  echo "KasmVNC websocket port: ${kasmvnc_port}"

  # Set password
  printf "%s\n%s\n" "${password}" "${password}" | vncpasswd -u "$USER" -w -r

  ${service_vnc_exec} -kill ${DISPLAY} 2>/dev/null || true

  # Create kasm-xstartup if not exists
  XSTARTUP_PATH="$HOME/.vnc/kasm-xstartup"
  if ! [ -f "${XSTARTUP_PATH}" ]; then
    cat > ${XSTARTUP_PATH} <<'KASMEOF'
#!/bin/sh
set -eu

detect_desktop_env() {
    if command -v cinnamon-session >/dev/null 2>&1; then
        echo "cinnamon"
    elif command -v mate-session >/dev/null 2>&1; then
        echo "mate"
    elif command -v startlxde >/dev/null 2>&1; then
        echo "lxde"
    elif command -v gnome-session >/dev/null 2>&1; then
        echo "gnome"
    elif command -v lxqt-session >/dev/null 2>&1; then
        echo "lxqt"
    elif command -v startplasma-x11 >/dev/null 2>&1 || command -v plasmashell >/dev/null 2>&1; then
        echo "kde"
    else
        echo "none"
    fi
}

    de="$(detect_desktop_env)"
    echo "*** running $de desktop ***"

    case "$de" in
    cinnamon)
        killall -q cinnamon cinnamon-session cinnamon-panel muffin nemo nemo-desktop 2>/dev/null || true
        export LIBGL_ALWAYS_SOFTWARE=1
        export CLUTTER_BACKEND=x11
        export GDK_BACKEND=x11
        export QT_QPA_PLATFORM=xcb
        export MOZ_ENABLE_WAYLAND=0
        exec dbus-run-session -- cinnamon-session
        ;;
    mate)
        exec mate-session
        ;;
    lxde)
        exec startlxde
        ;;
    gnome)
        export XDG_CURRENT_DESKTOP=GNOME
        export XDG_SESSION_TYPE=x11
        export GDK_BACKEND=x11
        export QT_QPA_PLATFORM=xcb
        export MOZ_ENABLE_WAYLAND=0
        exec dbus-run-session -- gnome-session --session=gnome
        ;;
    lxqt)
        exec lxqt-session
        ;;
    kde)
        exec startplasma-x11
        ;;
    *)
        exec startlxde
        ;;
    esac
KASMEOF
    chmod 0755 "${XSTARTUP_PATH}"
  fi

  # Start KasmVNC (serves HTTPS on kasmvnc_port)
  vncserver_cmd="${service_vnc_exec} ${DISPLAY} -disableBasicAuth \
    -xstartup ${XSTARTUP_PATH} \
    -websocketPort ${kasmvnc_port} \
    -rfbport ${displayPort}"

  MAX_RETRIES=5
  RETRY_COUNT=0
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ${vncserver_cmd}
    if [ $? -eq 0 ]; then
      echo "KasmVNC server started successfully."
      break
    else
      echo "KasmVNC server failed to start. Retrying..."
      sleep 5
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
  done

  if ! [ -f "${HOME}/.vnc/$(hostname)${DISPLAY}.pid" ]; then
    echo "ERROR: KasmVNC server failed to start" >&2
    exit 1
  fi

  # =============================================================================
  # Start nginx wrapper to proxy HTTP -> HTTPS (required for KasmVNC)
  # =============================================================================
  echo "Starting nginx wrapper on service port ${service_port} -> KasmVNC ${kasmvnc_port}"

  # Write nginx server config
  cat > ${JOB_DIR}/config.conf <<HERE
server {
 listen ${service_port};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 client_max_body_size 1000M;
 location / {
     proxy_pass https://127.0.0.1:${kasmvnc_port};
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
 }
}
HERE

  # Write main nginx config
  cat > ${JOB_DIR}/nginx.conf <<HERE
worker_processes  2;

error_log  /var/log/nginx/error.log notice;
pid        /tmp/nginx.pid;

events {
    worker_connections  1024;
}

http {
    proxy_temp_path /tmp/proxy_temp;
    client_body_temp_path /tmp/client_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    keepalive_timeout  65;

    include /etc/nginx/conf.d/*.conf;
}
HERE

  # Empty file to overwrite default nginx config
  touch ${JOB_DIR}/empty

  # Start nginx using Singularity container
  if [ -f "${SERVICE_NGINX_SIF}" ]; then
    echo "Running nginx container: ${SERVICE_NGINX_SIF}"
    mkdir -p ${JOB_DIR}/tmp
    singularity run \
      -B ${JOB_DIR}/tmp:/tmp \
      -B ${JOB_DIR}/config.conf:/etc/nginx/conf.d/config.conf \
      -B ${JOB_DIR}/nginx.conf:/etc/nginx/nginx.conf \
      -B ${JOB_DIR}/empty:/etc/nginx/conf.d/default.conf \
      ${SERVICE_NGINX_SIF} >> ${JOB_DIR}/nginx.logs 2>&1 &
    nginx_pid=$!
    echo "nginx started with PID ${nginx_pid}"
  else
    echo "ERROR: nginx container not found at ${SERVICE_NGINX_SIF}" >&2
    echo "KasmVNC requires nginx wrapper for HTTP access" >&2
    exit 1
  fi
fi

# =============================================================================
# Write coordination files to job directory
# =============================================================================
sleep 6  # Allow services to fully start

echo "Writing coordination files to ${JOB_DIR}..."
echo "  service_port=${service_port}"

# Write files with verification
hostname > "${JOB_DIR}/HOSTNAME"
echo "${service_port}" > "${JOB_DIR}/SESSION_PORT"

# Verify files were written before signaling job started
if [ ! -f "${JOB_DIR}/HOSTNAME" ]; then
  echo "ERROR: Failed to write HOSTNAME file" >&2
  exit 1
fi
if [ ! -f "${JOB_DIR}/SESSION_PORT" ]; then
  echo "ERROR: Failed to write SESSION_PORT file" >&2
  exit 1
fi

# Sync filesystem to ensure files are visible (important for networked filesystems)
sync

# Signal that job has started (must be last)
touch "${JOB_DIR}/job.started"

echo "=========================================="
echo "Desktop Service is RUNNING!"
echo "=========================================="
echo "HOSTNAME: $(cat ${JOB_DIR}/HOSTNAME)"
echo "SESSION_PORT: $(cat ${JOB_DIR}/SESSION_PORT)"
echo "=========================================="

# =============================================================================
# Keep script running
# =============================================================================
sleep inf
