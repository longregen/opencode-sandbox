{ lib
, stdenv
, patchelf
, glibc
, bubblewrap
, makeWrapper
, writeShellScript
, fetchurl
, cacert
, tun2socks
, slirp4netns
, iproute2
, util-linux
}:

let
  # Create the sandboxed wrapper script
  sandboxWrapper = writeShellScript "opencode-sandbox" ''
    #!${stdenv.shell}

    # Parse command line flags
    ENABLE_FUSE=0
    ENABLE_SSH_GIT=0
    ENABLE_LIBVIRT=0
    ENABLE_GUI=0
    ENABLE_NVIDIA=0
    ENABLE_KVM=0
    ENABLE_AUDIO=0
    SOCKS_PROXY=""
    EXTRA_ENVS=()
    OPENCODE_ARGS=()

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --fuse)
          ENABLE_FUSE=1
          shift
          ;;
        --ssh-git)
          ENABLE_SSH_GIT=1
          shift
          ;;
        --libvirt)
          ENABLE_LIBVIRT=1
          shift
          ;;
        --gui)
          ENABLE_GUI=1
          shift
          ;;
        --nvidia)
          ENABLE_NVIDIA=1
          shift
          ;;
        --kvm)
          ENABLE_KVM=1
          shift
          ;;
        --audio)
          ENABLE_AUDIO=1
          shift
          ;;
        --env)
          EXTRA_ENVS+=("$2")
          shift 2
          ;;
        --env=*)
          EXTRA_ENVS+=("''${1#*=}")
          shift
          ;;
        --socks-proxy)
          SOCKS_PROXY="$2"
          shift 2
          ;;
        --socks-proxy=*)
          SOCKS_PROXY="''${1#*=}"
          shift
          ;;
        *)
          OPENCODE_ARGS+=("$1")
          shift
          ;;
      esac
    done

    # Create isolated sandbox home directory
    SANDBOX_HOME="/tmp/opencode-sandbox-home-$$"
    SANDBOX_TMP="/tmp/opencode-sandbox-tmp-$$"
    trap 'rm -rf "$SANDBOX_HOME" "$SANDBOX_TMP"; rm -f "/tmp/opencode-socks-$$" "/tmp/opencode-socks-ns-$$"' EXIT

    mkdir -p "$SANDBOX_TMP"
    mkdir -p "$SANDBOX_HOME"
    mkdir -p "$SANDBOX_HOME/.cache"
    mkdir -p "$SANDBOX_HOME/.config"
    # Make sure the working directory path exists in the sandbox
    mkdir -p "$SANDBOX_HOME/$(echo "$PWD" | sed "s|^/home/$USER||")"
    USER=$(whoami)

    # Only allow access to current project directory and essential system files
    ALLOWLIST=(
      "$SANDBOX_HOME:/home/$USER"
      "$PWD"                # current project dir (read-write)
      "ro:/etc"             # System configuration (read-only)
      "/nix"
      "ro:/run/current-system/sw"
      "ro:/bin/sh"
      "ro:/usr/bin/env"     # env command
      "$SANDBOX_TMP:/tmp"
    )
    HOME_ALLOW=(
      ".opencode"
      ".android"
      ".ansible"
      ".cargo"
      ".config/opencode"
      ".config/opencode-sandbox.json"
      ".config/nix"
      ".cursor"
      ".docker"
      ".go"
      ".java"
      ".local/share/opencode"
      ".nix-defexpr"
      ".nix-channels"
      ".nix-profile"
      ".npm"
      ".yarn"
    )
    CACHE_DIRS=(
      "go"
      "pip"
      "deno"
      "pnpm"
      "yarn"
      "uv"
      "huggingface"
      "cached-nix-shell"
      "nix"
      "nix-hug"
      "gradle"
      "zig"
      # Additional language-specific caches and tools
      "bun"
      "black"
      "gopls"
      "jedi"
      "lua-language-server"
      "pylint"
      "staticcheck"
      "typescript"
      "fish"
      "fontconfig"
      "prisma"
      "prisma-nodejs"
      "puppeteer"
      "tokenizer"
      "whisper"
    )
    for cache_dir in "''${CACHE_DIRS[@]}"; do
      if [ -d "$HOME/.cache/$cache_dir" ]; then
        ALLOWLIST+=( "$HOME/.cache/$cache_dir" )
      fi
    done
    for cache_dir in "''${HOME_ALLOW[@]}"; do
      if [ -e "$HOME/$cache_dir" ]; then
        ALLOWLIST+=( "$HOME/$cache_dir" )
      fi
    done

    # Add conditional paths based on flags
    if [ "$ENABLE_FUSE" -eq 1 ]; then
      # Allow access to /tmp for fuse mounts
      ALLOWLIST+=( "/tmp" )
      # Allow access to common fuse mount points
      if [ -d "/run/user/$(id -u)" ]; then
        ALLOWLIST+=( "/run/user/$(id -u)" )
      fi
      # Allow access to /dev/fuse for FUSE operations (dev: prefix for device access)
      ALLOWLIST+=( "dev:/dev/fuse" )
    fi

    if [ "$ENABLE_SSH_GIT" -eq 1 ]; then
      # Allow access to SSH and git config in real home
      if [ -d "$HOME/.ssh" ]; then
        ALLOWLIST+=( "$HOME/.ssh" )
      fi
      if [ -d "$HOME/.gitconfig" ] || [ -f "$HOME/.gitconfig" ]; then
        ALLOWLIST+=( "$HOME/.gitconfig" )
      fi
      if [ -d "$HOME/.git-credentials" ] || [ -f "$HOME/.git-credentials" ]; then
        ALLOWLIST+=( "$HOME/.git-credentials" )
      fi
      # Also need SSH agent socket if it exists
      if [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
        ALLOWLIST+=( "$SSH_AUTH_SOCK" )
      fi
      # GnuPG for git commit signing
      if [ -d "$HOME/.gnupg" ]; then
        ALLOWLIST+=( "$HOME/.gnupg" )
      fi
      # GPG agent socket
      if [ -n "$GPG_AGENT_INFO" ]; then
        GPG_SOCK=$(echo "$GPG_AGENT_INFO" | cut -d: -f1)
        if [ -e "$GPG_SOCK" ]; then
          ALLOWLIST+=( "$GPG_SOCK" )
        fi
      fi
      # Modern gpg agent socket location
      if [ -S "/run/user/$(id -u)/gnupg/S.gpg-agent" ]; then
        ALLOWLIST+=( "/run/user/$(id -u)/gnupg/S.gpg-agent" )
      fi
    fi

    if [ "$ENABLE_LIBVIRT" -eq 1 ]; then
      # Allow access to libvirt socket
      if [ -S "/var/run/libvirt/libvirt-sock" ]; then
        ALLOWLIST+=( "/var/run/libvirt/libvirt-sock" )
      fi
      if [ -S "/run/libvirt/libvirt-sock" ]; then
        ALLOWLIST+=( "/run/libvirt/libvirt-sock" )
      fi
      # Allow access to user session libvirt socket
      if [ -S "/run/user/$(id -u)/libvirt/libvirt-sock" ]; then
        ALLOWLIST+=( "/run/user/$(id -u)/libvirt/libvirt-sock" )
      fi
    fi

    if [ "$ENABLE_GUI" -eq 1 ]; then
      # X11 support
      if [ -d "/tmp/.X11-unix" ]; then
        ALLOWLIST+=( "/tmp/.X11-unix" )
      fi
      if [ -f "$HOME/.Xauthority" ]; then
        ALLOWLIST+=( "$HOME/.Xauthority" )
      fi

      # Wayland support
      if [ -n "$WAYLAND_DISPLAY" ] && [ -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" )
      fi

      # D-Bus session bus (needed by most GUI apps)
      if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/bus" )
      fi

      # GPU access for hardware acceleration (dev: prefix for device access)
      if [ -d "/dev/dri" ]; then
        ALLOWLIST+=( "dev:/dev/dri" )
      fi

      # Fonts
      if [ -d "/usr/share/fonts" ]; then
        ALLOWLIST+=( "ro:/usr/share/fonts" )
      fi
      if [ -d "/run/current-system/sw/share/fonts" ]; then
        ALLOWLIST+=( "ro:/run/current-system/sw/share/fonts" )
      fi
      if [ -d "$HOME/.local/share/fonts" ]; then
        ALLOWLIST+=( "ro:$HOME/.local/share/fonts" )
      fi

      # Icon/theme directories
      if [ -d "/usr/share/icons" ]; then
        ALLOWLIST+=( "ro:/usr/share/icons" )
      fi
      if [ -d "/run/current-system/sw/share/icons" ]; then
        ALLOWLIST+=( "ro:/run/current-system/sw/share/icons" )
      fi

      # GTK/Qt theming
      for theme_dir in ".config/gtk-3.0" ".config/gtk-4.0" ".config/qt5ct" ".config/qt6ct"; do
        if [ -d "$HOME/$theme_dir" ]; then
          ALLOWLIST+=( "ro:$HOME/$theme_dir" )
        fi
      done

      # Audio support (PulseAudio)
      if [ -d "$XDG_RUNTIME_DIR/pulse" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/pulse" )
      fi
      # Audio support (PipeWire)
      if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/pipewire-0" )
      fi
    fi

    if [ "$ENABLE_NVIDIA" -eq 1 ]; then
      # NVIDIA control devices (dev: prefix for device access)
      for dev in /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        if [ -e "$dev" ]; then
          ALLOWLIST+=( "dev:$dev" )
        fi
      done
      # NVIDIA GPU devices (nvidia0, nvidia1, ...)
      for dev in /dev/nvidia[0-9]*; do
        if [ -c "$dev" ]; then
          ALLOWLIST+=( "dev:$dev" )
        fi
      done
      # NVIDIA caps
      if [ -d "/dev/nvidia-caps" ]; then
        ALLOWLIST+=( "dev:/dev/nvidia-caps" )
      fi
      # OpenGL/CUDA driver libraries
      if [ -d "/run/opengl-driver" ]; then
        ALLOWLIST+=( "ro:/run/opengl-driver" )
      fi
    fi

    if [ "$ENABLE_KVM" -eq 1 ]; then
      # KVM virtualization device (dev: prefix for device access)
      if [ -c "/dev/kvm" ]; then
        ALLOWLIST+=( "dev:/dev/kvm" )
      fi
      # VFIO devices for device passthrough
      if [ -d "/dev/vfio" ]; then
        ALLOWLIST+=( "dev:/dev/vfio" )
      fi
    fi

    if [ "$ENABLE_AUDIO" -eq 1 ]; then
      # PulseAudio socket
      if [ -d "$XDG_RUNTIME_DIR/pulse" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/pulse" )
      fi
      # PipeWire socket
      if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/pipewire-0" )
      fi
      # ALSA devices (for QEMU_AUDIO_DRV=alsa backend)
      if [ -d "/dev/snd" ]; then
        ALLOWLIST+=( "dev:/dev/snd" )
      fi
      # D-Bus session bus (PulseAudio often needs it)
      if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        ALLOWLIST+=( "$XDG_RUNTIME_DIR/bus" )
      fi
    fi

    # Always read config file if it exists
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode-sandbox.json"
    if [ -f "$CONFIG_FILE" ]; then
      # Parse the JSON config file
      if command -v jq >/dev/null 2>&1; then
        if [ -f "$CONFIG_FILE" ]; then
          # Read includeFolders array
          while IFS= read -r folder; do
            # Expand tilde to home directory
            expanded_folder=$(echo "$folder" | sed "s|^~|$HOME|")
            if [ -d "$expanded_folder" ]; then
              ALLOWLIST+=( "$expanded_folder" )
            fi
          done < <(jq -r '.includeFolders[]? // empty' "$CONFIG_FILE" 2>/dev/null)

          # Read includeHomePatterns array
          while IFS= read -r pattern; do
            # Add to HOME_ALLOW if it exists
            if [ -e "$HOME/$pattern" ]; then
              ALLOWLIST+=( "$HOME/$pattern" )
            fi
          done < <(jq -r '.includeHomePatterns[]? // empty' "$CONFIG_FILE" 2>/dev/null)

          # Read gui option - always enable GUI if set to true
          if jq -e '.gui == true' "$CONFIG_FILE" >/dev/null 2>&1; then
            ENABLE_GUI=1
          fi

          # Read nvidia option - always enable NVIDIA GPU access if set to true
          if jq -e '.nvidia == true' "$CONFIG_FILE" >/dev/null 2>&1; then
            ENABLE_NVIDIA=1
          fi

          # Read kvm option - enable KVM virtualization access if set to true
          if jq -e '.kvm == true' "$CONFIG_FILE" >/dev/null 2>&1; then
            ENABLE_KVM=1
          fi

          # Read audio option - enable headless audio support if set to true
          if jq -e '.audio == true' "$CONFIG_FILE" >/dev/null 2>&1; then
            ENABLE_AUDIO=1
          fi

          # Read extraEnvs - pass arbitrary environment variables into the sandbox
          while IFS= read -r env_pair; do
            EXTRA_ENVS+=("$env_pair")
          done < <(jq -r '.extraEnvs[]? // empty' "$CONFIG_FILE" 2>/dev/null)

          # Read yolo option - add --yolo if set to true
          if jq -e '.yolo == true' "$CONFIG_FILE" >/dev/null 2>&1; then
            OPENCODE_ARGS+=("--yolo")
          fi

          # Read socksProxy option - force all traffic through a SOCKS proxy
          if [ -z "$SOCKS_PROXY" ]; then
            _cfg_proxy=$(jq -r '.socksProxy // empty' "$CONFIG_FILE" 2>/dev/null)
            if [ -n "$_cfg_proxy" ]; then
              SOCKS_PROXY="$_cfg_proxy"
            fi
          fi
        fi
      else
        # Fallback to basic parsing if jq is not available
        echo "Warning: jq not found. Please install jq for proper config parsing." >&2
      fi
    fi

    whitelisted_envs=(
      "SHELL"
      "PATH"
      "HOME"
      "USER"
      "LOGNAME"
      "MAIL"
      "TERM"
      "SSL_CERT_FILE"
      "NIX_SSL_CERT_FILE"
      "CURL_CA_BUNDLE"
    )
    env_args=()
    for env in "''${whitelisted_envs[@]}"; do
      if [ -n "''${!env}" ]; then
        env_args+=( --setenv "$env" "''${!env}" )
      fi
    done
    env_args+=( --setenv "SSL_CERT_FILE" "''${SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}" )
    env_args+=( --setenv "NIX_SSL_CERT_FILE" "''${NIX_SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}" )
    env_args+=( --setenv "CURL_CA_BUNDLE" "''${CURL_CA_BUNDLE:-${cacert}/etc/ssl/certs/ca-bundle.crt}" )
    env_args+=( --setenv "SHELL" "$(readlink $(which $SHELL))" )
    env_args+=( --setenv "DISABLE_AUTOUPDATER" "1")
    env_args+=( --setenv "DISABLE_ERROR_REPORTING" "1")
    env_args+=( --setenv "DISABLE_BUG_COMMAND" "1")
    env_args+=( --setenv "DISABLE_TELEMETRY" "1")

    # Pass SSH_AUTH_SOCK and GPG variables if --ssh-git is enabled
    if [ "$ENABLE_SSH_GIT" -eq 1 ]; then
      if [ -n "$SSH_AUTH_SOCK" ]; then
        env_args+=( --setenv "SSH_AUTH_SOCK" "$SSH_AUTH_SOCK" )
      fi
      if [ -n "$GPG_AGENT_INFO" ]; then
        env_args+=( --setenv "GPG_AGENT_INFO" "$GPG_AGENT_INFO" )
      fi
      if [ -n "$GPG_TTY" ]; then
        env_args+=( --setenv "GPG_TTY" "$GPG_TTY" )
      fi
    fi

    # Pass display and audio variables if --gui is enabled
    if [ "$ENABLE_GUI" -eq 1 ]; then
      if [ -n "$DISPLAY" ]; then
        env_args+=( --setenv "DISPLAY" "$DISPLAY" )
      fi
      if [ -n "$WAYLAND_DISPLAY" ]; then
        env_args+=( --setenv "WAYLAND_DISPLAY" "$WAYLAND_DISPLAY" )
      fi
      if [ -n "$XDG_RUNTIME_DIR" ]; then
        env_args+=( --setenv "XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR" )
      fi
      if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
        env_args+=( --setenv "DBUS_SESSION_BUS_ADDRESS" "$DBUS_SESSION_BUS_ADDRESS" )
      fi
      if [ -n "$XDG_SESSION_TYPE" ]; then
        env_args+=( --setenv "XDG_SESSION_TYPE" "$XDG_SESSION_TYPE" )
      fi
      # For Qt apps on Wayland
      if [ -n "$QT_QPA_PLATFORM" ]; then
        env_args+=( --setenv "QT_QPA_PLATFORM" "$QT_QPA_PLATFORM" )
      fi
    fi

    # Pass audio-related variables if --audio is enabled
    if [ "$ENABLE_AUDIO" -eq 1 ]; then
      if [ -n "$XDG_RUNTIME_DIR" ]; then
        env_args+=( --setenv "XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR" )
      fi
      if [ -n "$PULSE_SERVER" ]; then
        env_args+=( --setenv "PULSE_SERVER" "$PULSE_SERVER" )
      fi
      if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
        env_args+=( --setenv "DBUS_SESSION_BUS_ADDRESS" "$DBUS_SESSION_BUS_ADDRESS" )
      fi
    fi

    # Pass NVIDIA/CUDA variables if --nvidia is enabled
    if [ "$ENABLE_NVIDIA" -eq 1 ]; then
      env_args+=( --setenv "LD_LIBRARY_PATH" "/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" )
      if [ -n "$CUDA_VISIBLE_DEVICES" ]; then
        env_args+=( --setenv "CUDA_VISIBLE_DEVICES" "$CUDA_VISIBLE_DEVICES" )
      fi
    fi

    # Pass arbitrary environment variables from --env flags and config extraEnvs
    for env_pair in "''${EXTRA_ENVS[@]}"; do
      env_key="''${env_pair%%=*}"
      env_val="''${env_pair#*=}"
      if [ -n "$env_key" ]; then
        env_args+=( --setenv "$env_key" "$env_val" )
      fi
    done

    # Normalise SOCKS_PROXY into a socks5:// URL
    if [ -n "$SOCKS_PROXY" ]; then
      case "$SOCKS_PROXY" in
        socks5://*|socks://*) ;; # already a URL
        :*) SOCKS_PROXY="socks5://127.0.0.1$SOCKS_PROXY" ;;  # :port shorthand
        *:*) SOCKS_PROXY="socks5://$SOCKS_PROXY" ;;           # host:port
        *) SOCKS_PROXY="socks5://$SOCKS_PROXY" ;;
      esac
    fi

    # Build bwrap argument list
    args=(
      --die-with-parent                     # auto-kill if parent shell exits
      --ro-bind /nix /nix                   # Nix store read-only
    )

    if [ -n "$SOCKS_PROXY" ]; then
      # In SOCKS mode we're already inside unshare --user --net.
      # Bind-mount /proc and /dev from the namespace so network info is visible.
      # Still isolate PID/IPC/UTS namespaces for security.
      args+=( --ro-bind /proc /proc --dev /dev --unshare-pid --unshare-ipc --unshare-uts )
    else
      # Normal mode: fresh /proc, isolate everything, share host network.
      args+=( --proc /proc --dev /dev --unshare-all --share-net )
    fi

    # Create /usr/bin directory and bind node
    args+=(
      --tmpfs /usr
      --dir /usr/bin
      "''${env_args[@]}"
    )

    for p in "''${ALLOWLIST[@]}"; do
      if [[ "$p" == ro:* ]]; then
        p="''${p#ro:}";
        if [ -e "$p" ]; then
          args+=( --ro-bind "$p" "$p" )
        fi
      elif [[ "$p" == dev:* ]]; then
        # Device nodes need --dev-bind (no MS_NODEV flag) to allow device access
        p="''${p#dev:}"
        if [ -e "$p" ]; then
          args+=( --dev-bind "$p" "$p" )
        fi
      elif [[ "$p" == *:* ]]; then
        source="''${p%%:*}"
        dest="''${p#*:}"
        if [ -e "$source" ]; then
          args+=( --bind "$source" "$dest" )
        fi
      else
        if [ -e "$p" ]; then
          args+=( --bind "$p" "$p" )
        fi
      fi
    done

    # Determine bwrap target binary
    if [ $START_SHELL ]; then
      BWRAP_TARGET=$(readlink $(which $SHELL))
    else
      BWRAP_TARGET="$out/bin/opencode-unwrapped"
    fi

    if [ -n "$SOCKS_PROXY" ]; then
      # Parse proxy host for route exclusion (avoid routing loop)
      PROXY_HOST=$(echo "$SOCKS_PROXY" | sed -E 's|socks5?://||;s|:[0-9]+$||')

      # Validate PROXY_HOST to prevent command injection
      if ! [[ "$PROXY_HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Error: Invalid proxy host: $PROXY_HOST" >&2
        exit 1
      fi

      # FIFO for parent->child coordination (PID-suffixed)
      COORD_FIFO="/tmp/opencode-socks-$$"
      mkfifo "$COORD_FIFO"

      # Build the quoted bwrap command for embedding in the namespace script
      BWRAP_QUOTED=$(printf '%q ' ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$BWRAP_TARGET" "''${OPENCODE_ARGS[@]}")

      # Write the inner namespace script to a temp file to avoid quoting issues
      NS_SCRIPT="/tmp/opencode-socks-ns-$$"
      cat > "$NS_SCRIPT" <<NSEOF
#!/usr/bin/env bash
rm -f "$NS_SCRIPT"
# Wait for slirp4netns to attach tap0
read < "$COORD_FIFO"
rm -f "$COORD_FIFO"

# Bring up loopback
${iproute2}/bin/ip link set dev lo up

# Create TUN device for tun2socks
${iproute2}/bin/ip tuntap add mode tun dev tunopencode
${iproute2}/bin/ip addr add 198.18.0.1/15 dev tunopencode
${iproute2}/bin/ip link set dev tunopencode up

# Route proxy host via slirp gateway to avoid routing loop
${iproute2}/bin/ip route add $PROXY_HOST via 10.0.2.2 dev tap0

# Default route through TUN -> tun2socks -> SOCKS proxy
# (replaces the default route that slirp4netns --configure created)
${iproute2}/bin/ip route replace default dev tunopencode

# Start tun2socks in background (redirect output so it doesn't hold pipes open)
${tun2socks}/bin/tun2socks -device tunopencode -proxy "$SOCKS_PROXY" > /dev/null 2>&1 &
TUN2SOCKS_PID=\$!
trap "kill \$TUN2SOCKS_PID 2>/dev/null" EXIT

# Small delay to let tun2socks bind
sleep 0.3

# Run bwrap inside this namespace (use wait instead of exec so trap fires)
$BWRAP_QUOTED

NSEOF
      chmod +x "$NS_SCRIPT"

      # Launch isolated user+net namespace (preserve stdin with <&0)
      ${util-linux}/bin/unshare --user --map-root-user --net -- bash "$NS_SCRIPT" <&0 &
      NS_PID=$!

      # Create pipe for slirp4netns ready signal
      exec {SLIRP_READY_FD}<> <(:)

      # From parent: attach slirp4netns to give the namespace NAT connectivity
      ${slirp4netns}/bin/slirp4netns --configure --mtu=65520 --ready-fd=$SLIRP_READY_FD $NS_PID tap0 &
      SLIRP_PID=$!

      # Set up trap to clean up slirp4netns on exit
      trap 'kill $SLIRP_PID 2>/dev/null; rm -f "$COORD_FIFO"' EXIT

      # Wait for slirp4netns to signal ready (reads until EOF or data)
      read -t 5 -u $SLIRP_READY_FD || true
      exec {SLIRP_READY_FD}<&-

      # Signal child that tap0 is ready
      echo "ready" > "$COORD_FIFO"

      # Wait for namespace (bwrap) to finish, then clean up
      wait $NS_PID 2>/dev/null
      EXIT_CODE=$?
      kill $SLIRP_PID 2>/dev/null
      rm -f "$COORD_FIFO"
      trap - EXIT
      exit $EXIT_CODE
    else
      # Normal (non-SOCKS) path
      if [ $DRY_RUN ]; then
        echo ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$BWRAP_TARGET" "''${OPENCODE_ARGS[@]}"
      elif [ $START_SHELL ]; then
        exec ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$BWRAP_TARGET"
      else
        exec ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$BWRAP_TARGET" "''${OPENCODE_ARGS[@]}"
      fi
    fi
  '';

  # Script to add current directory to allowed folders
  allowDirScript = writeShellScript "opencode-allow-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode-sandbox.json"

    # Create config file with empty structure if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
      echo '{"includeFolders":[],"includeHomePatterns":[],"gui":false,"yolo":false}' > "$CONFIG_FILE"
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: jq is required but not found. Please install jq." >&2
      exit 1
    fi

    # Get absolute path of current directory
    DIR="$(pwd)"

    # Check if directory is already in the list
    if jq -e --arg dir "$DIR" '.includeFolders | index($dir) != null' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory already allowed: $DIR"
      exit 0
    fi

    # Add directory to includeFolders
    jq --arg dir "$DIR" '.includeFolders += [$dir]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Added to allowed directories: $DIR"
  '';

  # Script to remove current directory from allowed folders
  forgetDirScript = writeShellScript "opencode-forget-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/opencode-sandbox.json"

    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
      echo "No config file found at: $CONFIG_FILE"
      exit 0
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: jq is required but not found. Please install jq." >&2
      exit 1
    fi

    # Get absolute path of current directory
    DIR="$(pwd)"

    # Check if directory is in the list
    if ! jq -e --arg dir "$DIR" '.includeFolders | index($dir) != null' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory not in allowed list: $DIR"
      exit 0
    fi

    # Remove directory from includeFolders
    jq --arg dir "$DIR" '.includeFolders = (.includeFolders | map(select(. != $dir)))' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Removed from allowed directories: $DIR"
  '';

in stdenv.mkDerivation rec {
  pname = "opencode-sandbox";
  version = "1.2.4";

  src = fetchurl {
    url = "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${version}.tgz";
    sha256 = "0ymrqdkjaxw21wcvq0cbwgxxpy3h8rmshb8h3ydqvq3ajhk33a6p";
  };

  sourceRoot = "package";

  nativeBuildInputs = [ makeWrapper patchelf ];
  buildInputs = [ glibc bubblewrap cacert tun2socks slirp4netns iproute2 util-linux ];

  # No build phase needed
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;

  installPhase = ''
    # Create directories
    mkdir -p $out/bin

    # Install native binary
    cp bin/opencode $out/bin/opencode-unwrapped
    chmod +x $out/bin/opencode-unwrapped

    # Patch ELF interpreter for NixOS compatibility
    patchelf --set-interpreter "${glibc}/lib/ld-linux-x86-64.so.2" $out/bin/opencode-unwrapped

    # Create our sandboxed wrapper
    cp ${sandboxWrapper} $out/bin/opencode-sandbox
    chmod +x $out/bin/opencode-sandbox

    # Alias the sandboxed opencode to the original opencode
    ln -s $out/bin/opencode-sandbox $out/bin/opencode

    # Install helper scripts for managing allowed directories
    cp ${allowDirScript} $out/bin/opencode-allow-dir
    chmod +x $out/bin/opencode-allow-dir
    cp ${forgetDirScript} $out/bin/opencode-forget-dir
    chmod +x $out/bin/opencode-forget-dir

    # Substitute the $out placeholder with actual output path
    substituteInPlace $out/bin/opencode-sandbox \
      --replace '$out/bin/opencode-unwrapped' "$out/bin/opencode-unwrapped"
  '';

  meta = with lib; {
    description = "Sandboxed OpenCode environment using bubblewrap";
    homepage = "https://opencode.ai";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "opencode-sandbox";
  };
}
