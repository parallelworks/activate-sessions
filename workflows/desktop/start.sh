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

# =============================================================================
# Read VNC Mode and Session Name
# =============================================================================
vnc_mode="native"
if [ -f "${JOB_DIR}/VNC_MODE" ]; then
    vnc_mode=$(cat "${JOB_DIR}/VNC_MODE")
fi
echo "VNC Mode: ${vnc_mode}"

# =============================================================================
# Shared utility: build mount flags from newline-delimited paths file
# =============================================================================
# Usage: build_mount_flags <runtime> <paths_file>
#   runtime: "enroot" or "singularity"
#   paths_file: file containing one mount path per line
# Outputs space-separated flags to stdout
build_mount_flags() {
    local runtime="$1"
    local paths_file="$2"
    local flags=""

    if [ ! -f "${paths_file}" ]; then
        echo ""
        return 0
    fi

    while IFS= read -r mount_path || [ -n "${mount_path}" ]; do
        # Skip empty lines and comments
        mount_path=$(echo "${mount_path}" | xargs)  # trim whitespace
        [ -z "${mount_path}" ] && continue
        [[ "${mount_path}" == \#* ]] && continue

        # Skip paths that don't exist on this system
        if [ ! -e "${mount_path}" ]; then
            echo "  Skip (not found): ${mount_path}" >&2
            continue
        fi

        if [ "${runtime}" = "enroot" ]; then
            flags="${flags} -m ${mount_path}:${mount_path}"
        else
            flags="${flags} --bind ${mount_path}:${mount_path}"
        fi
        echo "  Mount: ${mount_path}" >&2
    done < "${paths_file}"

    echo "${flags}"
}

# Read session name (written by setup.sh)
if [ -f "${JOB_DIR}/SESSION_NAME" ]; then
    PW_SESSION_NAME=$(cat "${JOB_DIR}/SESSION_NAME")
fi

# =============================================================================
# KasmVNC Container Mode
# =============================================================================
if [[ "${vnc_mode}" == "kasmvnc_container" ]]; then
    echo "Starting KasmVNC Container Mode..."

    # Read container runtime (default to singularity for backward compatibility)
    container_runtime="singularity"
    if [ -f "${JOB_DIR}/KASMVNC_CONTAINER_RUNTIME" ]; then
        container_runtime=$(cat "${JOB_DIR}/KASMVNC_CONTAINER_RUNTIME")
    fi
    echo "Container runtime: ${container_runtime}"

    # Get service port (nginx external port)
    service_port=$(pw agent open-port)
    if [ -z "${service_port}" ]; then
        echo "ERROR: Failed to allocate service port" >&2
        exit 1
    fi
    echo "Service port: ${service_port}"

    # Get KasmVNC internal websocket port
    kasm_port=$(pw agent open-port)
    if [ -z "${kasm_port}" ]; then
        echo "ERROR: Failed to allocate KasmVNC port" >&2
        exit 1
    fi
    echo "KasmVNC websocket port: ${kasm_port}"

    # Clean up ALL stale VNC sessions from this user before selecting a display
    echo "Cleaning up stale VNC sessions..."
    pkill -u $(whoami) -f "Xvnc" 2>/dev/null || true
    sleep 1  # Give processes time to exit
    # Clean up any leftover lock/socket files for displays we might use
    for d in $(seq 1 99); do
        rm -f "/tmp/.X11-unix/X${d}" "/tmp/.X${d}-lock" 2>/dev/null || true
    done

    # Find available VNC display (5901-5999 range)
    # Checks: port not listening, no running Xvnc process on that display
    find_available_vnc_display() {
        # Get listening ports once (try ss first, fall back to netstat)
        local listening
        listening=$(ss -tuln 2>/dev/null || netstat -tuln 2>/dev/null || echo "")

        for display_num in $(seq 1 99 | shuf); do
            local port=$((5900 + display_num))
            # Check port is not in use
            if echo "${listening}" | grep -q ":${port} "; then
                continue
            fi
            # Check no Xvnc process is running on this display
            if pgrep -u $(whoami) -f "Xvnc.*:${display_num}( |$)" >/dev/null 2>&1; then
                continue
            fi
            echo "${display_num}"
            return 0
        done
        echo "1"  # Fallback to :1
    }
    vnc_display=$(find_available_vnc_display)
    echo "VNC display: :${vnc_display}"

    # Force-clean the selected display (remove any leftover artifacts)
    pkill -u $(whoami) -f "Xvnc.*:${vnc_display}( |$)" 2>/dev/null || true
    rm -f "/tmp/.X11-unix/X${vnc_display}" "/tmp/.X${vnc_display}-lock" 2>/dev/null || true

    # Build BASE_PATH for the container
    BASE_PATH="/me/session/${resource_user}/${PW_SESSION_NAME}/"
    echo "BASE_PATH: ${BASE_PATH}"

    # Cleanup function for KasmVNC container mode
    cleanup_kasmvnc_container() {
        echo "$(date) Stopping KasmVNC container..."
        if [ -n "${kasmvnc_container_pid:-}" ]; then
            kill ${kasmvnc_container_pid} 2>/dev/null || true
        fi
        # Clean up VNC display
        pkill -u $(whoami) -f "Xvnc.*:${vnc_display}" 2>/dev/null || true
        rm -f "/tmp/.X11-unix/X${vnc_display}" "/tmp/.X${vnc_display}-lock" 2>/dev/null || true
    }
    trap cleanup_kasmvnc_container EXIT INT TERM

    # Read mount paths (newline-delimited)
    MOUNT_FLAGS=""
    if [ -f "${JOB_DIR}/CONTAINER_MOUNT_PATHS" ]; then
        echo "Container mount paths:"
        MOUNT_FLAGS=$(build_mount_flags "${container_runtime}" "${JOB_DIR}/CONTAINER_MOUNT_PATHS")
    fi

    # =========================================================================
    # Enroot Runtime
    # =========================================================================
    if [[ "${container_runtime}" == "enroot" ]]; then
        echo "Using Enroot runtime..."

        # Read Enroot container path
        if [ -f "${JOB_DIR}/KASMVNC_ENROOT_PATH" ]; then
            ENROOT_CONTAINER_PATH=$(cat "${JOB_DIR}/KASMVNC_ENROOT_PATH")
        else
            ENROOT_CONTAINER_PATH="/mnt/data/containers/kasmvnc.sqsh"
        fi

        # Verify .sqsh file exists
        if [ ! -f "${ENROOT_CONTAINER_PATH}" ]; then
            echo "ERROR: Enroot container not found at ${ENROOT_CONTAINER_PATH}" >&2
            exit 1
        fi
        echo "Using Enroot container: ${ENROOT_CONTAINER_PATH}"

        # Container instance name (includes OS to avoid stale cached instances)
        ENROOT_CONTAINER_NAME="kasmvnc-${desktop_kasmvnc_os:-rocky9}"

        # Create container instance if it doesn't exist (one-time per user per OS)
        if ! enroot list 2>/dev/null | grep -q "^${ENROOT_CONTAINER_NAME}$"; then
            echo "Creating Enroot container instance..."
            enroot create --name "${ENROOT_CONTAINER_NAME}" "${ENROOT_CONTAINER_PATH}"
        else
            echo "Enroot container instance already exists"
        fi

        # Create temp home for VNC files (overlay fs at /root doesn't support
        # colons in filenames, which VNC uses for hostname:display.pid/log)
        KASMVNC_HOME="/tmp/${USER}-kasmhome"
        mkdir -p "${KASMVNC_HOME}"

        # Start Enroot container (GPU support is enabled by default in Enroot)
        echo "Starting Enroot container..."
        enroot start --rw \
            ${MOUNT_FLAGS} \
            -m ${KASMVNC_HOME}:/root \
            -e HOME=/root \
            -e BASE_PATH="${BASE_PATH}" \
            -e NGINX_PORT="${service_port}" \
            -e KASM_PORT="${kasm_port}" \
            -e VNC_DISPLAY="${vnc_display}" \
            "${ENROOT_CONTAINER_NAME}" /usr/local/bin/run_kasm_nginx.sh &
        kasmvnc_container_pid=$!
        echo "Enroot container started with PID ${kasmvnc_container_pid}"

    # =========================================================================
    # Singularity Runtime (default)
    # =========================================================================
    else
        echo "Using Singularity runtime..."

        # Read container path
        if [ -f "${JOB_DIR}/KASMVNC_CONTAINER_PATH" ]; then
            KASMVNC_CONTAINER_SIF=$(cat "${JOB_DIR}/KASMVNC_CONTAINER_PATH")
        else
            echo "ERROR: KASMVNC_CONTAINER_PATH not found" >&2
            exit 1
        fi

        # Verify container exists
        if [ ! -f "${KASMVNC_CONTAINER_SIF}" ]; then
            echo "ERROR: KasmVNC container not found at ${KASMVNC_CONTAINER_SIF}" >&2
            exit 1
        fi
        echo "Using container: ${KASMVNC_CONTAINER_SIF}"

        # Read GPU setting
        enable_gpu="true"
        if [ -f "${JOB_DIR}/KASMVNC_CONTAINER_ENABLE_GPU" ]; then
            enable_gpu=$(cat "${JOB_DIR}/KASMVNC_CONTAINER_ENABLE_GPU")
        fi

        # GPU flag
        GPU_FLAG=""
        if [[ "${enable_gpu}" == "true" ]]; then
            GPU_FLAG="--nv"
            echo "GPU support enabled (--nv)"
        else
            echo "GPU support disabled"
        fi

        # Start Singularity container
        echo "Starting Singularity container..."
        singularity run \
            ${GPU_FLAG} \
            ${MOUNT_FLAGS} \
            --env BASE_PATH="${BASE_PATH}" \
            --env NGINX_PORT="${service_port}" \
            --env KASM_PORT="${kasm_port}" \
            --env VNC_DISPLAY="${vnc_display}" \
            --bind /etc/passwd:/etc/passwd:ro \
            --bind /etc/group:/etc/group:ro \
            "${KASMVNC_CONTAINER_SIF}" &
        kasmvnc_container_pid=$!
        echo "Singularity container started with PID ${kasmvnc_container_pid}"
    fi

    # Write coordination files
    sleep 6  # Allow container to start

    echo "Writing coordination files to ${JOB_DIR}..."
    hostname > "${JOB_DIR}/HOSTNAME"
    echo "${service_port}" > "${JOB_DIR}/SESSION_PORT"

    # Verify files were written
    if [ ! -f "${JOB_DIR}/HOSTNAME" ] || [ ! -f "${JOB_DIR}/SESSION_PORT" ]; then
        echo "ERROR: Failed to write coordination files" >&2
        exit 1
    fi

    sync
    touch "${JOB_DIR}/job.started"

    echo "=========================================="
    echo "KasmVNC Container Desktop Service is RUNNING!"
    echo "=========================================="
    echo "HOSTNAME: $(cat ${JOB_DIR}/HOSTNAME)"
    echo "SESSION_PORT: $(cat ${JOB_DIR}/SESSION_PORT)"
    echo "BASE_PATH: ${BASE_PATH}"
    echo "=========================================="

    # Wait for container to exit
    wait ${kasmvnc_container_pid}

# =============================================================================
# KasmProxy Mode (native VNC + containerized proxy)
# =============================================================================
elif [[ "${vnc_mode}" == "kasmproxy" ]]; then
    echo "Starting KasmProxy Mode..."
    echo "Native VNC + containerized proxy"

    # Set up temp home directory early to avoid network filesystem issues
    VNC_HOME="/tmp/${USER}-vnchome"
    mkdir -p "${VNC_HOME}/.vnc"
    echo "VNC HOME: ${VNC_HOME}"

    # Read kasmproxy settings
    kasmproxy_runtime=$(cat "${JOB_DIR}/KASMPROXY_RUNTIME" 2>/dev/null || echo "enroot")
    echo "KasmProxy runtime: ${kasmproxy_runtime}"

    # Dynamically allocate KasmVNC websocket port
    kasm_port=$(pw agent open-port)
    if [ -z "${kasm_port}" ]; then
        echo "ERROR: Failed to allocate KasmVNC port" >&2
        exit 1
    fi
    echo "KasmVNC websocket port: ${kasm_port}"

    # Read container path based on runtime
    if [[ "${kasmproxy_runtime}" == "singularity" ]]; then
        kasmproxy_path=$(cat "${JOB_DIR}/KASMPROXY_SINGULARITY_PATH" 2>/dev/null || echo "/mnt/data/containers/kasmproxy.sif")
    else
        kasmproxy_path=$(cat "${JOB_DIR}/KASMPROXY_ENROOT_PATH" 2>/dev/null || echo "/mnt/data/containers/kasmproxy.sqsh")
    fi

    # Verify kasmproxy container exists
    if [ ! -f "${kasmproxy_path}" ]; then
        echo "ERROR: KasmProxy container not found at ${kasmproxy_path}" >&2
        exit 1
    fi
    echo "KasmProxy container: ${kasmproxy_path}"

    # Get service port for nginx
    service_port=$(pw agent open-port)
    if [ -z "${service_port}" ]; then
        echo "ERROR: Failed to allocate service port" >&2
        exit 1
    fi
    echo "Service port: ${service_port}"

    # Build BASE_PATH
    BASE_PATH="/me/session/${resource_user}/${PW_SESSION_NAME}/"
    echo "BASE_PATH: ${BASE_PATH}"

    # =========================================================================
    # Step 1: Detect and start native VNC
    # =========================================================================
    echo "Detecting native VNC server..."

    # Try to find vncserver in PATH (check multiple names)
    service_vnc_exec=""
    for vnc_cmd in vncserver kasmvncserver tigervncserver turbovncserver; do
        if which ${vnc_cmd} >/dev/null 2>&1; then
            service_vnc_exec=$(which ${vnc_cmd})
            echo "Found VNC command: ${service_vnc_exec}"
            break
        fi
    done

    # Debug: show PATH if not found
    if [ -z "${service_vnc_exec}" ]; then
        echo "DEBUG: PATH=${PATH}"
        echo "DEBUG: Checking common locations..."
        for loc in /usr/bin/vncserver /usr/local/bin/vncserver /opt/TurboVNC/bin/vncserver; do
            if [ -x "$loc" ]; then
                service_vnc_exec="$loc"
                echo "Found VNC at: ${service_vnc_exec}"
                break
            fi
        done
    fi

    # Detect VNC type
    service_vnc_type=""
    if [ -n "${service_vnc_exec}" ] && [ -x "${service_vnc_exec}" ]; then
        service_vnc_type=$(${service_vnc_exec} -list 2>/dev/null | grep -oP '(TigerVNC|TurboVNC|KasmVNC)' || echo "")
        # Fallback: check binary name
        if [ -z "${service_vnc_type}" ]; then
            case "${service_vnc_exec}" in
                *kasmvnc*) service_vnc_type="KasmVNC" ;;
                *tigervnc*) service_vnc_type="TigerVNC" ;;
                *turbovnc*) service_vnc_type="TurboVNC" ;;
            esac
        fi
    fi

    if [ -z "${service_vnc_type}" ]; then
        echo "ERROR: No native VNC server found (kasmvncserver, tigervnc, or turbovnc required)" >&2
        echo "DEBUG: service_vnc_exec='${service_vnc_exec}'"
        exit 1
    fi

    echo "Detected VNC: ${service_vnc_type}"

    # Find available display
    find_available_display_kasmproxy() {
        local minPort=5901
        local maxPort=5999

        for port in $(seq ${minPort} ${maxPort} | shuf); do
            out=$(netstat -aln 2>/dev/null | grep LISTEN | grep ${port} || true)
            displayNumber=${port: -2}
            XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')

            if [ -z "${out}" ] && ! [ -e /tmp/.X11-unix/X${XdisplayNumber} ] 2>/dev/null && ! [ -e /tmp/.X${XdisplayNumber}-lock ] 2>/dev/null; then
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

    displayPort=$(find_available_display_kasmproxy)
    if [ -z "${displayPort}" ]; then
        echo "ERROR: No available display port found" >&2
        exit 1
    fi

    displayNumber=${displayPort: -2}
    DISPLAY=:$(echo ${displayNumber} | sed 's/^0*//')
    XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')
    echo "Display: ${DISPLAY}"

    # Start native VNC based on type
    echo "Starting native VNC server on display ${DISPLAY}..."

    if [[ "${service_vnc_type}" == "KasmVNC" ]]; then
        # KasmVNC needs xstartup and user setup
        # Create xstartup for desktop environment detection (prefer Cinnamon, fallback to XFCE)
        XSTARTUP_PATH="${VNC_HOME}/.vnc/xstartup"

        # Write startup command to a file that xstartup can read
        STARTUP_CMD_FILE="${VNC_HOME}/.startup_command"
        if [ -f "${JOB_DIR}/STARTUP_COMMAND" ]; then
            cp "${JOB_DIR}/STARTUP_COMMAND" "${STARTUP_CMD_FILE}"
            echo "Startup command file: ${STARTUP_CMD_FILE}"
            echo "Command: $(cat ${STARTUP_CMD_FILE})"
        else
            rm -f "${STARTUP_CMD_FILE}" 2>/dev/null || true
        fi

        # Always write xstartup to ensure latest config is used
        cat > "${XSTARTUP_PATH}" <<'KASMEOF'
#!/bin/sh
set -eu

# Reset HOME to user's real home directory (not the temp VNC home)
# But preserve XAUTHORITY so X authentication still works
VNC_HOME_SAVED="$HOME"
REAL_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
if [ -n "$REAL_HOME" ] && [ -d "$REAL_HOME" ]; then
    # Keep XAUTHORITY pointing to VNC home where vncserver created it
    export XAUTHORITY="${VNC_HOME_SAVED}/.Xauthority"
    export HOME="$REAL_HOME"
    echo "HOME reset to: $HOME (XAUTHORITY: $XAUTHORITY)"
    cd "$HOME" 2>/dev/null || true
fi

# Run startup command if specified (read from file written by start.sh)
run_startup_command() {
    # VNC_HOME_SAVED contains the temp VNC home where start.sh wrote the file
    STARTUP_CMD_FILE="${VNC_HOME_SAVED}/.startup_command"
    if [ -f "${STARTUP_CMD_FILE}" ]; then
        STARTUP_COMMAND=$(cat "${STARTUP_CMD_FILE}")
        if [ -n "${STARTUP_COMMAND}" ]; then
            echo "Running startup command: ${STARTUP_COMMAND}"
            sleep 3  # Wait for desktop to fully initialize
            eval "${STARTUP_COMMAND}" &
        fi
    fi
}

detect_desktop_env() {
    # Prefer XFCE - it works best with KasmVNC
    if command -v xfce4-session >/dev/null 2>&1; then
        echo "xfce"
    elif command -v cinnamon-session >/dev/null 2>&1; then
        echo "cinnamon"
    elif command -v mate-session >/dev/null 2>&1; then
        echo "mate"
    elif command -v startlxde >/dev/null 2>&1; then
        echo "lxde"
    elif command -v lxqt-session >/dev/null 2>&1; then
        echo "lxqt"
    elif command -v startplasma-x11 >/dev/null 2>&1 || command -v plasmashell >/dev/null 2>&1; then
        echo "kde"
    elif command -v gnome-session >/dev/null 2>&1; then
        # GNOME last - often has issues with VNC
        echo "gnome"
    else
        echo "none"
    fi
}

de="$(detect_desktop_env)"
echo "*** running $de desktop ***"

# Disable screensaver and lock screen (important for VNC sessions)
# This function creates autostart overrides BEFORE the desktop starts
# and starts a watchdog to keep killing any screen lockers
disable_screen_lock() {
    echo "Disabling screensaver and lock screen..."

    # Use VNC_HOME_SAVED for autostart overrides (where XFCE reads them)
    local config_home="${VNC_HOME_SAVED:-$HOME}"
    mkdir -p "${config_home}/.config/autostart"
    mkdir -p "${config_home}/.config/xfce4/xfconf/xfce-perchannel-xml"

    # Also create in real home in case XFCE uses that
    local real_home=$(getent passwd "$(whoami)" | cut -d: -f6)
    if [ -n "$real_home" ] && [ -d "$real_home" ]; then
        mkdir -p "${real_home}/.config/autostart"
        mkdir -p "${real_home}/.config/xfce4/xfconf/xfce-perchannel-xml"
        mkdir -p "${real_home}/.cache/sessions"
    fi

    # Clear XFCE saved sessions to prevent restoring screen lockers
    echo "Clearing saved XFCE sessions..."
    rm -rf "${config_home}/.cache/sessions/"* 2>/dev/null || true
    rm -rf "${real_home}/.cache/sessions/"* 2>/dev/null || true

    # Disable XFCE session saving/restore
    for dir in "${config_home}/.config/xfce4/xfconf/xfce-perchannel-xml" "${real_home}/.config/xfce4/xfconf/xfce-perchannel-xml"; do
        [ -d "$dir" ] || continue
        cat > "${dir}/xfce4-session.xml" << 'XFCE_SESSION_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="LockScreen" type="bool" value="false"/>
    <property name="AutoLock" type="bool" value="false"/>
    <property name="SaveOnExit" type="bool" value="false"/>
  </property>
  <property name="sessions" type="empty">
    <property name="Failsafe" type="empty">
      <property name="IsFailsafe" type="bool" value="true"/>
    </property>
  </property>
</channel>
XFCE_SESSION_EOF
    done

    # List of screen lockers to disable
    local lockers="light-locker xfce4-screensaver xscreensaver gnome-screensaver org.gnome.ScreenSaver xautolock cinnamon-screensaver mate-screensaver"

    # Create autostart override files with Hidden=true in both locations
    for locker in $lockers; do
        for dir in "${config_home}/.config/autostart" "${real_home}/.config/autostart"; do
            [ -d "$dir" ] || continue
            cat > "${dir}/${locker}.desktop" << 'AUTOSTART_EOF'
[Desktop Entry]
Hidden=true
AUTOSTART_EOF
        done
    done

    # Remove xscreensaver config file if it exists
    rm -f "${config_home}/.xscreensaver" "${real_home}/.xscreensaver" 2>/dev/null || true

    # Kill any running screen lockers immediately
    killall -9 light-locker xfce4-screensaver xscreensaver gnome-screensaver xautolock cinnamon-screensaver mate-screensaver 2>/dev/null || true

    # Disable via xfconf (create channel files before xfce starts)
    if command -v xfconf-query >/dev/null 2>&1; then
        # Disable lock screen completely
        xfconf-query -c xfce4-screensaver -p /lock/enabled -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-screensaver -p /lock/saver-activation/enabled -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-screensaver -p /lock/user-switching/enabled -s false --create -t bool 2>/dev/null || true

        # Disable screensaver activation completely
        xfconf-query -c xfce4-screensaver -p /saver/enabled -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-screensaver -p /saver/idle-activation/enabled -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-screensaver -p /saver/mode -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-screensaver -p /saver/idle-activation/delay -s 0 --create -t int 2>/dev/null || true

        # Disable xfce4-power-manager screen blanking and lock
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-off -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-sleep -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-ac -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-battery -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-sleep-mode-on-ac -s 0 --create -t int 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-sleep-mode-on-battery -s 0 --create -t int 2>/dev/null || true

        # Disable xfce4-session lock
        xfconf-query -c xfce4-session -p /general/LockScreen -s false --create -t bool 2>/dev/null || true
        xfconf-query -c xfce4-session -p /general/AutoLock -s false --create -t bool 2>/dev/null || true
    fi

    # Disable via gsettings (for GNOME-based components)
    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
        gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
        gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
    fi

    # Disable DPMS via xset
    if command -v xset >/dev/null 2>&1; then
        xset s off 2>/dev/null || true
        xset s noblank 2>/dev/null || true
        xset s 0 0 2>/dev/null || true
        xset -dpms 2>/dev/null || true
    fi

    # Start aggressive watchdog - kill screen lockers every 5 seconds
    (
        sleep 5
        while true; do
            # Kill all known screen lockers
            for proc in light-locker xfce4-screensaver xscreensaver gnome-screensaver xautolock cinnamon-screensaver mate-screensaver; do
                pkill -9 -f "$proc" 2>/dev/null || true
            done
            # Re-apply xset settings
            xset s off s noblank s 0 0 -dpms 2>/dev/null || true
            # Re-apply xfconf settings
            xfconf-query -c xfce4-screensaver -p /lock/enabled -s false 2>/dev/null || true
            xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null || true
            sleep 5
        done
    ) &
    echo "Screen lock watchdog started (PID: $!)"

    echo "Screen lock disabled"
}

# Configure XFCE appearance (if xfconf-query available)
configure_xfce_appearance() {
    if ! command -v xfconf-query >/dev/null 2>&1; then
        echo "xfconf-query not found, skipping appearance config"
        return 0
    fi

    echo "Configuring XFCE appearance..."

    # Wait for xfce4-session to fully initialize
    for i in 1 2 3 4 5; do
        if xfconf-query -c xfce4-session -l >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # Disable screensaver and lock screen first
    disable_screen_lock

    # Set GTK theme (Adwaita-dark or fallback to Greybird-dark)
    for theme in "Adwaita-dark" "Greybird-dark" "Arc-Dark"; do
        if [ -d "/usr/share/themes/${theme}" ] || [ -d "$HOME/.themes/${theme}" ]; then
            xfconf-query -c xsettings -p /Net/ThemeName -s "${theme}" --create -t string 2>/dev/null && break
        fi
    done

    # Set window manager theme
    for theme in "Adwaita-dark" "Greybird-dark" "Arc-Dark"; do
        if [ -d "/usr/share/themes/${theme}/xfwm4" ] || [ -d "$HOME/.themes/${theme}/xfwm4" ]; then
            xfconf-query -c xfwm4 -p /general/theme -s "${theme}" --create -t string 2>/dev/null && break
        fi
    done

    # Set icon theme
    xfconf-query -c xsettings -p /Net/IconThemeName -s "Adwaita" --create -t string 2>/dev/null || true

    # Set solid black background - need to configure all detected monitors
    # First, list all backdrop properties to find the actual monitor paths
    monitors=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/backdrop/screen.*/monitor.*/workspace.*' | sed 's|/[^/]*$||' | sort -u)

    if [ -n "$monitors" ]; then
        for monitor_path in $monitors; do
            echo "Configuring backdrop: ${monitor_path}"
            # image-style: 0=None (solid color), 1=Centered, 2=Tiled, 3=Stretched, 4=Scaled, 5=Zoomed
            xfconf-query -c xfce4-desktop -p "${monitor_path}/image-style" -s 0 --create -t int 2>/dev/null || true
            # color-style: 0=Solid, 1=Horizontal gradient, 2=Vertical gradient, 3=Transparent
            xfconf-query -c xfce4-desktop -p "${monitor_path}/color-style" -s 0 --create -t int 2>/dev/null || true
            # rgba1: primary color (black = 0,0,0,1)
            xfconf-query -c xfce4-desktop -p "${monitor_path}/rgba1" -s 0.0 -s 0.0 -s 0.0 -s 1.0 --create -t double -t double -t double -t double 2>/dev/null || true
        done
    else
        # Fallback: try common paths
        for path in \
            "/backdrop/screen0/monitor0/workspace0" \
            "/backdrop/screen0/monitorscreen/workspace0" \
            "/backdrop/screen0/monitorVNC-0/workspace0"; do
            xfconf-query -c xfce4-desktop -p "${path}/image-style" -s 0 --create -t int 2>/dev/null || true
            xfconf-query -c xfce4-desktop -p "${path}/color-style" -s 0 --create -t int 2>/dev/null || true
            xfconf-query -c xfce4-desktop -p "${path}/rgba1" -s 0.0 -s 0.0 -s 0.0 -s 1.0 --create -t double -t double -t double -t double 2>/dev/null || true
        done
    fi

    echo "XFCE appearance configured"
}

# Disable screen lock BEFORE starting the desktop
disable_screen_lock

case "$de" in
xfce)
    # XFCE - preferred desktop for KasmVNC
    echo "Starting XFCE desktop environment..."
    # Configure appearance and run startup command after desktop fully starts
    # Need longer delay for xfdesktop to initialize and register with xfconf
    (sleep 5 && configure_xfce_appearance && run_startup_command) &
    exec dbus-run-session -- xfce4-session
    ;;
cinnamon)
    # Clean up stale Cinnamon processes that break restarts under VNC
    killall -q cinnamon cinnamon-session cinnamon-panel muffin nemo nemo-desktop || true

    # VNC stability for Cinnamon (prevents blank desktop on second start)
    export LIBGL_ALWAYS_SOFTWARE=1
    export CLUTTER_BACKEND=x11
    export GDK_BACKEND=x11
    export QT_QPA_PLATFORM=xcb
    export MOZ_ENABLE_WAYLAND=0

    # Start Cinnamon with a scoped D-Bus session
    exec dbus-run-session -- cinnamon-session
    ;;
mate)
    exec dbus-run-session -- mate-session
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
    # Safe fallback to XFCE (works well with KasmVNC)
    echo "Unknown desktop '$de', falling back to XFCE..."
    # Configure appearance and run startup command after desktop fully starts
    (sleep 5 && configure_xfce_appearance && run_startup_command) &
    exec dbus-run-session -- xfce4-session
    ;;
esac
KASMEOF
        chmod 0755 "${XSTARTUP_PATH}"
        echo "Kasm xstartup installed at ${XSTARTUP_PATH}"

        # FIXME: REMOVE THIS CODE WHEN ROCKY 9 IMAGE IS UPDATED!
        # Disable KasmVNC's interactive desktop selector script
        if [ -f /usr/lib/kasmvncserver/select-de.sh ]; then
            echo "Disabling KasmVNC select-de.sh interactive prompt..."
            sudo mv /usr/lib/kasmvncserver/select-de.sh /usr/lib/kasmvncserver/select-de.sh.bak 2>/dev/null || true
            sudo tee /usr/lib/kasmvncserver/select-de.sh >/dev/null <<'EOF'
#!/bin/sh
exit 0
EOF
            sudo chmod +x /usr/lib/kasmvncserver/select-de.sh
        fi

        # Generate self-signed SSL certificate for KasmVNC (system snakeoil certs may not exist)
        KASM_SSL_DIR="${VNC_HOME}/.vnc/ssl"
        mkdir -p "${KASM_SSL_DIR}"
        if [ ! -f "${KASM_SSL_DIR}/cert.pem" ] || [ ! -f "${KASM_SSL_DIR}/key.pem" ]; then
            echo "Generating self-signed SSL certificate for KasmVNC..."
            openssl req -x509 -nodes -newkey rsa:2048 \
                -keyout "${KASM_SSL_DIR}/key.pem" \
                -out "${KASM_SSL_DIR}/cert.pem" \
                -days 3650 -subj '/CN=localhost' 2>/dev/null
        fi

        # Pre-create kasmvnc.yaml to set SSL cert paths and avoid interactive prompts
        cat > "${VNC_HOME}/.vnc/kasmvnc.yaml" << YAML_EOF
network:
  ssl:
    pem_certificate: ${KASM_SSL_DIR}/cert.pem
    pem_key: ${KASM_SSL_DIR}/key.pem
    require_ssl: true
YAML_EOF

        # Pre-create .Xauthority to suppress xauth warnings
        touch "${VNC_HOME}/.Xauthority"

        # KasmVNC with websocket - use disableBasicAuth so proxy can connect
        echo "Starting KasmVNC with websocket port ${kasm_port}..."
        # Run vncserver backgrounded - it will daemonize anyway
        # Use subshell to isolate any shell effects
        (
            export HOME="${VNC_HOME}"
            echo "2" | ${service_vnc_exec} ${DISPLAY} \
                -disableBasicAuth \
                -xstartup "${XSTARTUP_PATH}" \
                -websocketPort ${kasm_port} \
                -rfbport ${displayPort}
        ) &
        echo "VNC server starting in background..."
    else
        # TigerVNC or TurboVNC - create basic xstartup
        XSTARTUP_PATH="${VNC_HOME}/.vnc/xstartup"
        cat > "${XSTARTUP_PATH}" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
/etc/X11/xinit/xinitrc
EOF
        chmod +x "${XSTARTUP_PATH}"

        HOME="${VNC_HOME}" ${service_vnc_exec} ${DISPLAY} &
        vnc_pid=$!
    fi

    echo "VNC server launched"

    # Give VNC a moment to start
    sleep 5

    # =========================================================================
    # Step 2: Write coordination files BEFORE starting proxy
    # =========================================================================
    echo "Writing coordination files to ${JOB_DIR}..."
    hostname > "${JOB_DIR}/HOSTNAME"
    echo "${service_port}" > "${JOB_DIR}/SESSION_PORT"
    sync
    touch "${JOB_DIR}/job.started"
    echo "Coordination files written"

    # =========================================================================
    # Step 3: Start KasmProxy container
    # =========================================================================
    echo "Starting KasmProxy container..."

    # Create a wrapper script that sets env vars and runs nginx directly
    # (avoids the pkill/killall in the container script that terminates enroot)
    PROXY_WRAPPER="/tmp/kasmproxy_wrapper_$$.sh"
    cat > "${PROXY_WRAPPER}" << 'WRAPPER_EOF'
#!/bin/bash
set -e

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

KASM_HOST="${KASM_HOST:-127.0.0.1}"
KASM_PORT="${KASM_PORT:-8443}"
NGINX_PORT="${NGINX_PORT:-8080}"
BASE_PATH="${BASE_PATH:-/}"

# Normalize base path
[[ "$BASE_PATH" != /* ]] && BASE_PATH="/$BASE_PATH"
[[ "$BASE_PATH" != "/" && "$BASE_PATH" == */ ]] && BASE_PATH="${BASE_PATH%/}"

echo "==========================================="
echo "  KasmProxy Starting"
echo "==========================================="
echo "[INFO] KasmVNC backend: ${KASM_HOST}:${KASM_PORT}"
echo "[INFO] Nginx port: ${NGINX_PORT}"
echo "[INFO] Base path: ${BASE_PATH}"

mkdir -p /tmp/nginx_client_body /tmp/nginx_proxy /tmp/nginx_fastcgi /tmp/nginx_uwsgi /tmp/nginx_scgi

# Generate nginx config
cat > /tmp/nginx_proxy.conf << EOF
worker_processes 1;
pid /tmp/nginx.pid;
error_log /tmp/nginx_error.log;

events { worker_connections 1024; }

http {
    default_type application/octet-stream;
    access_log /tmp/nginx_access.log;
    client_body_temp_path /tmp/nginx_client_body;
    proxy_temp_path /tmp/nginx_proxy;
    fastcgi_temp_path /tmp/nginx_fastcgi;
    uwsgi_temp_path /tmp/nginx_uwsgi;
    scgi_temp_path /tmp/nginx_scgi;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen ${NGINX_PORT};
        server_name _;

        location / {
            proxy_pass https://${KASM_HOST}:${KASM_PORT}/;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 61s;
            proxy_buffering off;
        }
EOF

if [ "$BASE_PATH" != "/" ]; then
    cat >> /tmp/nginx_proxy.conf << EOF

        location = ${BASE_PATH} {
            return 301 \$scheme://\$host\$request_uri/;
        }

        location ${BASE_PATH}/ {
            proxy_pass https://${KASM_HOST}:${KASM_PORT}/;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 61s;
            proxy_buffering off;
        }
EOF
fi

echo "    }
}" >> /tmp/nginx_proxy.conf

echo "[INFO] Starting nginx..."
exec nginx -g 'daemon off;' -c /tmp/nginx_proxy.conf
WRAPPER_EOF
    chmod +x "${PROXY_WRAPPER}"

    # Get host IP for container to connect to (localhost won't work from inside container)
    KASM_HOST_IP=$(hostname -I | awk '{print $1}')
    echo "Host IP for KasmVNC: ${KASM_HOST_IP}"

    # Cleanup function (kill VNC on exit)
    cleanup_kasmproxy() {
        echo "$(date) Stopping KasmProxy mode..."
        HOME="${VNC_HOME}" vncserver -kill ${DISPLAY} 2>/dev/null || true
    }
    trap cleanup_kasmproxy EXIT INT TERM

    echo "=========================================="
    echo "KasmProxy Desktop Service is RUNNING!"
    echo "=========================================="
    echo "HOSTNAME: $(cat ${JOB_DIR}/HOSTNAME)"
    echo "SESSION_PORT: $(cat ${JOB_DIR}/SESSION_PORT)"
    echo "BASE_PATH: ${BASE_PATH}"
    echo "VNC Display: ${DISPLAY}"
    echo "VNC Type: ${service_vnc_type}"
    echo "KasmProxy Runtime: ${kasmproxy_runtime}"
    echo "=========================================="

    # Start proxy container based on runtime
    if [[ "${kasmproxy_runtime}" == "singularity" ]]; then
        # =====================================================================
        # Singularity Runtime
        # =====================================================================
        echo "Starting kasmproxy container via Singularity (foreground)..."
        echo "Container: ${kasmproxy_path}"

        singularity run \
            --bind "${PROXY_WRAPPER}:/run_proxy.sh" \
            --env "KASM_HOST=${KASM_HOST_IP}" \
            --env "KASM_PORT=${kasm_port}" \
            --env "NGINX_PORT=${service_port}" \
            --env "BASE_PATH=${BASE_PATH}" \
            "${kasmproxy_path}" /run_proxy.sh
    else
        # =====================================================================
        # Enroot Runtime (default)
        # =====================================================================
        KASMPROXY_CONTAINER_NAME="kasmproxy"

        echo "DEBUG: About to check/create container..."

        # Remove old container and recreate fresh to avoid stale state
        echo "Removing any existing kasmproxy container..."
        enroot remove -f "${KASMPROXY_CONTAINER_NAME}" 2>/dev/null || true

        echo "Creating fresh kasmproxy container instance..."
        enroot create --force --name "${KASMPROXY_CONTAINER_NAME}" "${kasmproxy_path}" || {
            echo "ERROR: Failed to create container"
            exit 1
        }
        echo "Container created successfully"

        # Start enroot in FOREGROUND (blocking) - script waits here
        echo "Starting kasmproxy container via enroot (foreground)..."
        echo "Command: enroot start --rw -m ${PROXY_WRAPPER}:/run_proxy.sh -e KASM_HOST=${KASM_HOST_IP} -e KASM_PORT=${kasm_port} -e NGINX_PORT=${service_port} -e BASE_PATH=${BASE_PATH} ${KASMPROXY_CONTAINER_NAME} /run_proxy.sh"
        enroot start --rw \
            -m "${PROXY_WRAPPER}:/run_proxy.sh" \
            -e "KASM_HOST=${KASM_HOST_IP}" \
            -e KASM_PORT=${kasm_port} \
            -e NGINX_PORT=${service_port} \
            -e "BASE_PATH=${BASE_PATH}" \
            "${KASMPROXY_CONTAINER_NAME}" /run_proxy.sh
    fi

    echo "KasmProxy container exited"

# =============================================================================
# Native VNC Mode (existing behavior)
# =============================================================================
else
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
    # Write coordination files early so wait_service.sh can find them
    # (inject_markers creates job.started immediately, so we need these ready)
    # =============================================================================
    echo "Writing coordination files to ${JOB_DIR}..."
    hostname > "${JOB_DIR}/HOSTNAME"
    echo "${service_port}" > "${JOB_DIR}/SESSION_PORT"
    sync
    echo "  HOSTNAME=$(cat ${JOB_DIR}/HOSTNAME)"
    echo "  SESSION_PORT=$(cat ${JOB_DIR}/SESSION_PORT)"

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
            # Explicitly fetch LFS files - only pull vnc directory
            git lfs pull --include="vnc/*"

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
    # Prefer XFCE - it works best with KasmVNC
    if command -v xfce4-session >/dev/null 2>&1; then
        echo "xfce"
    elif command -v cinnamon-session >/dev/null 2>&1; then
        echo "cinnamon"
    elif command -v mate-session >/dev/null 2>&1; then
        echo "mate"
    elif command -v startlxde >/dev/null 2>&1; then
        echo "lxde"
    elif command -v lxqt-session >/dev/null 2>&1; then
        echo "lxqt"
    elif command -v startplasma-x11 >/dev/null 2>&1 || command -v plasmashell >/dev/null 2>&1; then
        echo "kde"
    elif command -v gnome-session >/dev/null 2>&1; then
        # GNOME last - often has issues with VNC
        echo "gnome"
    else
        echo "none"
    fi
}

    de="$(detect_desktop_env)"
    echo "*** running $de desktop ***"

    case "$de" in
    xfce)
        # XFCE - preferred desktop for KasmVNC
        exec dbus-run-session -- xfce4-session
        ;;
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
        exec dbus-run-session -- mate-session
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
        # Fallback to XFCE
        exec dbus-run-session -- xfce4-session
        ;;
    esac
KASMEOF
        chmod 0755 "${XSTARTUP_PATH}"
      fi

      # Generate self-signed SSL certificate for KasmVNC (system snakeoil certs may not exist)
      KASM_SSL_DIR="${HOME}/.vnc/ssl"
      mkdir -p "${KASM_SSL_DIR}"
      if [ ! -f "${KASM_SSL_DIR}/cert.pem" ] || [ ! -f "${KASM_SSL_DIR}/key.pem" ]; then
          echo "Generating self-signed SSL certificate for KasmVNC..."
          openssl req -x509 -nodes -newkey rsa:2048 \
              -keyout "${KASM_SSL_DIR}/key.pem" \
              -out "${KASM_SSL_DIR}/cert.pem" \
              -days 3650 -subj '/CN=localhost' 2>/dev/null
      fi

      # Write kasmvnc.yaml config to set SSL cert paths (avoids missing snakeoil cert error)
      cat > "${HOME}/.vnc/kasmvnc.yaml" << YAML_EOF
network:
  ssl:
    pem_certificate: ${KASM_SSL_DIR}/cert.pem
    pem_key: ${KASM_SSL_DIR}/key.pem
    require_ssl: true
YAML_EOF

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
    # Services started - coordination files already written earlier
    # =============================================================================
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
fi
