#!/usr/bin/env bash
#
# dex-manager
#
# Interactive manager for running Samsung DeX in a window on Fedora Linux
# via scrcpy. Handles virtual display creation, scrcpy launch, wireless
# ADB setup (with network scan), developer-option toggles, and persistent
# configuration.
#
# On first run the script can self-install to ~/.local/bin and create a
# GNOME launcher. Subsequent runs present a menu-driven interface.
#
# Usage:
#   ./dex-manager.sh              interactive menu
#   dex-manager launch            skip menu, launch session directly
#   dex-manager status            skip menu, show status
#

set -euo pipefail

# ============================================================
# Constants and paths
# ============================================================

SCRIPT_NAME="dex-manager"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$SCRIPT_NAME"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$SCRIPT_NAME"

# Defaults (used on first run and for "reset" action)
DEFAULT_RESOLUTION="2560x1440"
DEFAULT_DPI="180"
DEFAULT_BITRATE="20M"
DEFAULT_AUDIO_CODEC="opus"
DEFAULT_VIDEO_CODEC="h264"
DEFAULT_WINDOW_TITLE="DeX"
DEFAULT_EXTRA_FLAGS=""
DEFAULT_WIRELESS_IP=""
DEFAULT_WIRELESS_PORT="5555"
DEFAULT_USE_MANUAL_COMMAND="no"
DEFAULT_MANUAL_COMMAND=""

# ============================================================
# Colors (only when stdout is a TTY)
# ============================================================

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

info() { echo "${BLUE}[info]${NC}  $*"; }
ok()   { echo "${GREEN}[ ok ]${NC}  $*"; }
warn() { echo "${YELLOW}[warn]${NC}  $*"; }
err()  { echo "${RED}[err!]${NC}  $*" >&2; }
hr()   { printf "${DIM}%s${NC}\n" "------------------------------------------------------------"; }
pause() { echo; read -r -p "Press Enter to continue..." _; }

# ============================================================
# Config management
# ============================================================

write_config() {
  mkdir -p "$CONFIG_DIR"
  # Use literal quotes so empty values are preserved as empty strings
  cat > "$CONFIG_FILE" <<EOF
# dex-manager configuration
# Edit directly or use the menu (option 3). Values are shell variables.
#
# IMPORTANT: Any field set to "" (empty) means "don't pass this flag to
# scrcpy" -- scrcpy's built-in default will be used. scrcpy's defaults
# are often higher quality than explicit overrides on modern hardware
# (especially on newer Samsung phones with better HEVC/AV1 encoders).
# Leaving BITRATE/AUDIO_CODEC/VIDEO_CODEC empty is the recommended
# starting point.

# Virtual display resolution (WIDTHxHEIGHT)
RESOLUTION="${RESOLUTION:-$DEFAULT_RESOLUTION}"

# Virtual display DPI
#   120 = tiny UI, tons of space    160 = standard desktop
#   180 = comfortable laptop use    240+ = phone-native, very large
DPI="${DPI:-$DEFAULT_DPI}"

# Video bitrate (e.g. 8M, 20M, 40M). Empty = scrcpy default (8 Mbps).
BITRATE="${BITRATE-$DEFAULT_BITRATE}"

# Audio codec: opus | aac | flac | raw. Empty = scrcpy default (opus).
AUDIO_CODEC="${AUDIO_CODEC-$DEFAULT_AUDIO_CODEC}"

# Video codec: h264 | h265 | av1. Empty = scrcpy default (h264 / device-preferred).
VIDEO_CODEC="${VIDEO_CODEC-$DEFAULT_VIDEO_CODEC}"

# Window title shown in GNOME task switcher
WINDOW_TITLE="${WINDOW_TITLE-$DEFAULT_WINDOW_TITLE}"

# Any additional scrcpy flags. Example: "--no-audio --always-on-top"
EXTRA_FLAGS="${EXTRA_FLAGS-$DEFAULT_EXTRA_FLAGS}"

# Wireless ADB address (blank = USB only)
WIRELESS_IP="${WIRELESS_IP-$DEFAULT_WIRELESS_IP}"
WIRELESS_PORT="${WIRELESS_PORT:-$DEFAULT_WIRELESS_PORT}"

# --- Manual command override ---------------------------------------
# When USE_MANUAL_COMMAND="yes", the video/audio/bitrate/extra-flags
# settings above are ignored and MANUAL_COMMAND is used as the scrcpy
# argument list instead. --display-id is always appended automatically
# after the overlay is created. Do NOT include the 'scrcpy' binary
# name in MANUAL_COMMAND.
#
# Example (scrcpy defaults except for window title):
#   USE_MANUAL_COMMAND="yes"
#   MANUAL_COMMAND="--window-title=DeX"
USE_MANUAL_COMMAND="${USE_MANUAL_COMMAND-$DEFAULT_USE_MANUAL_COMMAND}"
MANUAL_COMMAND="${MANUAL_COMMAND-$DEFAULT_MANUAL_COMMAND}"
EOF
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    write_config
    info "Created default config at $CONFIG_FILE"
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

save_config() { write_config; }

# ============================================================
# Prerequisites
# ============================================================

check_prerequisites() {
  local missing=()
  command -v scrcpy >/dev/null 2>&1 || missing+=(scrcpy)
  command -v adb >/dev/null 2>&1 || missing+=(android-tools)
  [[ ${#missing[@]} -eq 0 ]] && return 0

  warn "Missing packages: ${missing[*]}"
  read -r -p "Install via dnf? [Y/n] " yn
  if [[ -z "$yn" || "$yn" =~ ^[Yy] ]]; then
    sudo dnf install -y "${missing[@]}"
    ok "Dependencies installed"
  else
    err "Cannot continue without dependencies"
    exit 1
  fi
}

ensure_nmap() {
  command -v nmap >/dev/null 2>&1 && return 0
  warn "nmap is not installed (required for network scanning)"
  read -r -p "Install nmap via dnf? [Y/n] " yn
  if [[ -z "$yn" || "$yn" =~ ^[Yy] ]]; then
    sudo dnf install -y nmap && return 0
  fi
  return 1
}

# ============================================================
# Device detection
# ============================================================

# Outputs "model|serial|state"; state is "device" when ready or "none" otherwise
detect_device() {
  local state model serial
  state=$(adb get-state 2>/dev/null | tr -d '\r' || true)
  if [[ "$state" == "device" ]]; then
    model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    serial=$(adb get-serialno 2>/dev/null | tr -d '\r')
    echo "${model}|${serial}|device"
  else
    echo "||none"
  fi
}

require_device() {
  local dev state
  dev=$(detect_device)
  state="${dev##*|}"
  if [[ "$state" != "device" ]]; then
    err "No ADB device connected."
    warn "Use option 2 to connect wirelessly, or plug the phone in via USB."
    return 1
  fi
  return 0
}

# ============================================================
# Address parsing
# ============================================================

# Parse "host" or "host:port" into HOST|PORT (default port 5555)
parse_address() {
  local input="$1"
  local host port
  if [[ "$input" == *:* ]]; then
    host="${input%:*}"
    port="${input##*:}"
  else
    host="$input"
    port="5555"
  fi
  echo "${host}|${port}"
}

# Try to connect and fetch model. Outputs model name (or empty) on stdout.
try_connect_identify() {
  local addr="$1"   # host:port
  local model=""
  if timeout 3 adb connect "$addr" >/dev/null 2>&1; then
    model=$(timeout 3 adb -s "$addr" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "")
    echo "$model"
    return 0
  fi
  return 1
}

# ============================================================
# Command builder
# ============================================================

# Populates global array BUILT_SCRCPY_CMD with the full scrcpy
# command for the given display id. Empty config values are
# omitted so scrcpy falls back to its built-in defaults.
# When USE_MANUAL_COMMAND=yes, MANUAL_COMMAND is spliced in
# verbatim (word-split on spaces) instead of building from the
# typed config fields.
#
# Usage:
#   build_scrcpy_command "<display-id-or-placeholder>"
#   "${BUILT_SCRCPY_CMD[@]}"
BUILT_SCRCPY_CMD=()
build_scrcpy_command() {
  local display_id="${1:-<auto>}"
  BUILT_SCRCPY_CMD=(scrcpy "--display-id=$display_id")

  if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
    if [[ -n "${MANUAL_COMMAND:-}" ]]; then
      # shellcheck disable=SC2206
      local manual=($MANUAL_COMMAND)
      BUILT_SCRCPY_CMD+=("${manual[@]}")
    fi
    return 0
  fi

  [[ -n "${AUDIO_CODEC:-}" ]]  && BUILT_SCRCPY_CMD+=("--audio-codec=$AUDIO_CODEC")
  [[ -n "${VIDEO_CODEC:-}" ]]  && BUILT_SCRCPY_CMD+=("--video-codec=$VIDEO_CODEC")
  [[ -n "${BITRATE:-}" ]]      && BUILT_SCRCPY_CMD+=("--video-bit-rate=$BITRATE")
  [[ -n "${WINDOW_TITLE:-}" ]] && BUILT_SCRCPY_CMD+=("--window-title=$WINDOW_TITLE")

  if [[ -n "${EXTRA_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra=($EXTRA_FLAGS)
    BUILT_SCRCPY_CMD+=("${extra[@]}")
  fi
}

# Human-readable "quoted" form for display. Adds quotes around
# any arg containing whitespace so copy-paste reproduces the run.
format_scrcpy_command() {
  local out="" arg
  for arg in "${BUILT_SCRCPY_CMD[@]}"; do
    if [[ "$arg" =~ [[:space:]] ]]; then
      out+=" '$arg'"
    else
      out+=" $arg"
    fi
  done
  echo "${out# }"
}

# ============================================================
# Launch DeX
# ============================================================

launch_dex() {
  clear; hr
  echo " ${BOLD}Launching DeX session${NC}"
  hr

  require_device || { pause; return; }

  local dev
  dev=$(detect_device)
  info "Device:     ${dev%|*|*}"
  info "Resolution: $RESOLUTION @ $DPI DPI"
  if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
    info "Mode:       ${CYAN}manual${NC}"
    info "Command:    scrcpy ${MANUAL_COMMAND:-<scrcpy defaults>}"
  else
    info "Mode:       auto (from config)"
    info "Stream:     bitrate=${BITRATE:-<default>} audio=${AUDIO_CODEC:-<default>} video=${VIDEO_CODEC:-<default>}"
    [[ -n "$EXTRA_FLAGS" ]] && info "Extra:      $EXTRA_FLAGS"
  fi

  # Ensure cleanup fires on any exit path within this function
  local cleanup_done=0
  cleanup_overlay_silent() {
    [[ $cleanup_done -eq 1 ]] && return
    cleanup_done=1
    adb shell settings delete global overlay_display_devices >/dev/null 2>&1 || true
  }
  trap cleanup_overlay_silent RETURN INT TERM

  adb shell settings delete global overlay_display_devices >/dev/null 2>&1 || true
  sleep 0.5
  adb shell settings put global overlay_display_devices "${RESOLUTION}/${DPI}"
  sleep 1

  local display_id
  display_id=$(adb shell dumpsys display | grep -oP 'Display \K[0-9]+(?=:)' | tail -1 | tr -d '\r')

  if [[ -z "$display_id" || "$display_id" == "0" ]]; then
    err "Could not determine virtual display ID"
    info "Check with: adb shell dumpsys display"
    pause
    return
  fi
  ok "Virtual display created with ID $display_id"

  build_scrcpy_command "$display_id"

  hr
  info "Running: $(format_scrcpy_command)"
  hr
  "${BUILT_SCRCPY_CMD[@]}" || warn "scrcpy exited with non-zero status"
  hr

  cleanup_overlay_silent
  ok "Session ended, virtual display removed"
  trap - RETURN INT TERM
  pause
}

# ============================================================
# Preview launch command
# ============================================================

preview_command() {
  clear; hr
  echo " ${BOLD}Preview launch command${NC}"
  hr

  if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
    echo "  Mode:            ${CYAN}manual${NC}"
    echo "  Manual command:  ${MANUAL_COMMAND:-<empty -- pure scrcpy defaults>}"
  else
    echo "  Mode:            ${CYAN}auto${NC} (built from config)"
    printf "  %-16s %s\n" "Bitrate:"     "${BITRATE:-<scrcpy default>}"
    printf "  %-16s %s\n" "Audio codec:" "${AUDIO_CODEC:-<scrcpy default>}"
    printf "  %-16s %s\n" "Video codec:" "${VIDEO_CODEC:-<scrcpy default>}"
    printf "  %-16s %s\n" "Window title:" "${WINDOW_TITLE:-<scrcpy default>}"
    printf "  %-16s %s\n" "Extra flags:"  "${EXTRA_FLAGS:-<none>}"
  fi
  printf "  %-16s %sx%s @ %s DPI\n" "Virtual display:" "${RESOLUTION%x*}" "${RESOLUTION#*x}" "$DPI"
  echo
  hr
  echo " ${BOLD}Command that will be executed:${NC}"
  echo
  build_scrcpy_command "<auto-detected>"
  echo "  ${GREEN}$(format_scrcpy_command)${NC}"
  echo
  info "<auto-detected> is replaced at launch with the ID that Android"
  info "assigns to the overlay virtual display (varies per session)."
  echo
  hr
  echo "  ${GREEN}l${NC}) Launch now with this command"
  echo "  ${GREEN}c${NC}) Copy to clipboard (needs wl-copy or xclip)"
  echo "  ${GREEN}m${NC}) Toggle manual mode"
  echo "  ${GREEN}e${NC}) Edit manual command"
  echo "  ${GREEN}b${NC}) Back"
  echo
  read -r -p "Choice: " c
  case "$c" in
    l|L) launch_dex ;;
    c|C)
      local text
      text="$(format_scrcpy_command)"
      if command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$text" | wl-copy && ok "Copied (Wayland)"
      elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$text" | xclip -selection clipboard && ok "Copied (X11)"
      else
        warn "Neither wl-copy nor xclip is installed"
      fi
      pause
      ;;
    m|M)
      if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
        USE_MANUAL_COMMAND="no"
      else
        USE_MANUAL_COMMAND="yes"
      fi
      save_config
      ok "Manual mode is now: $USE_MANUAL_COMMAND"
      sleep 1
      preview_command
      ;;
    e|E)
      edit_manual_command
      preview_command
      ;;
    *) return ;;
  esac
}

edit_manual_command() {
  echo
  info "Current manual command: ${MANUAL_COMMAND:-<empty>}"
  info "Enter the full scrcpy argument string. Do not include 'scrcpy'"
  info "or '--display-id' (those are added automatically)."
  info "Leave empty for pure scrcpy defaults."
  echo
  info "Examples:"
  info "  <empty>                              pure scrcpy defaults"
  info "  --window-title=DeX                   defaults plus custom title"
  info "  --video-codec=h265 --video-bit-rate=30M   high-quality H.265"
  info "  --no-audio --max-fps=60              silent, capped framerate"
  echo
  read -r -p "Manual command: " new_cmd
  MANUAL_COMMAND="$new_cmd"
  save_config
  ok "Manual command saved"
}

# ============================================================
# Wireless ADB: scan / manual / saved
# ============================================================

scan_and_connect() {
  echo
  if ! ensure_nmap; then
    err "Cannot scan without nmap"
    return 1
  fi

  # Determine local subnet from the active default route
  local my_ip subnet_cidr
  my_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  if [[ -z "$my_ip" ]]; then
    err "Could not determine local IP"
    return 1
  fi
  subnet_cidr=$(echo "$my_ip" | awk -F. '{print $1"."$2"."$3".0/24"}')

  info "Scanning ${CYAN}${subnet_cidr}${NC} for ADB on port ${CYAN}${WIRELESS_PORT}${NC}..."
  info "This takes 10-20 seconds"
  echo

  # Parse nmap output: find hosts with the target port open
  local -a found_ips=()
  local current_ip=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^Nmap\ scan\ report\ for\ (.+)$ ]]; then
      local target="${BASH_REMATCH[1]}"
      if [[ "$target" =~ \(([0-9.]+)\)$ ]]; then
        current_ip="${BASH_REMATCH[1]}"
      else
        current_ip="$target"
      fi
    elif [[ "$line" =~ ^${WIRELESS_PORT}/tcp[[:space:]]+open ]]; then
      [[ -n "$current_ip" ]] && found_ips+=("$current_ip")
      current_ip=""
    fi
  done < <(nmap -p "$WIRELESS_PORT" --open -T4 -n "$subnet_cidr" 2>/dev/null)

  if [[ ${#found_ips[@]} -eq 0 ]]; then
    warn "No devices found with port ${WIRELESS_PORT} open on ${subnet_cidr}"
    info "Make sure the phone has wireless ADB enabled."
    info "If this is the first time, connect via USB once and run 'adb tcpip ${WIRELESS_PORT}'"
    return 1
  fi

  ok "Found ${#found_ips[@]} candidate device(s)"
  echo

  # Probe each for device info
  local i=1
  for ip in "${found_ips[@]}"; do
    local model
    model=$(try_connect_identify "${ip}:${WIRELESS_PORT}" || echo "")
    if [[ -n "$model" ]]; then
      printf "  ${GREEN}%d${NC}) %-15s  ${CYAN}%s${NC}\n" "$i" "$ip" "$model"
    else
      printf "  ${GREEN}%d${NC}) %-15s  ${DIM}(unresponsive / not authorized)${NC}\n" "$i" "$ip"
    fi
    ((i++))
  done

  echo
  read -r -p "Select device [1-${#found_ips[@]}] or 'b' to cancel: " choice

  [[ "$choice" =~ ^[Bb]$ ]] && return 1
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#found_ips[@]} )); then
    err "Invalid selection"
    return 1
  fi

  local selected_ip="${found_ips[$((choice-1))]}"
  connect_and_save "$selected_ip" "$WIRELESS_PORT"
}

manual_connect() {
  echo
  info "Enter an IP address or hostname, with optional :port"
  info "Examples: ${DIM}192.168.1.50${NC}, ${DIM}192.168.1.50:5555${NC}, ${DIM}myphone.local${NC}, ${DIM}myphone.local:5556${NC}"
  read -r -p "Address: " input
  [[ -z "$input" ]] && return 1

  local parsed host port
  parsed=$(parse_address "$input")
  host="${parsed%|*}"
  port="${parsed##*|}"

  # Resolve hostname to IP (for saving and display)
  local resolved_ip="$host"
  if ! [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "Resolving ${host}..."
    resolved_ip=$(getent ahosts "$host" 2>/dev/null | awk '{print $1; exit}' || echo "")
    if [[ -z "$resolved_ip" ]]; then
      err "Could not resolve hostname: $host"
      return 1
    fi
    info "Resolved to ${CYAN}${resolved_ip}${NC}"
  fi

  connect_and_save "$resolved_ip" "$port"
}

connect_and_save() {
  local ip="$1" port="$2"
  local addr="${ip}:${port}"

  info "Connecting to ${CYAN}${addr}${NC}..."
  if ! adb connect "$addr" 2>&1 | grep -qE 'connected|already connected'; then
    err "Connection failed"
    info "If the phone needs USB-pairing first, connect via USB and run 'adb tcpip ${port}' there."
    return 1
  fi

  local model
  model=$(timeout 3 adb -s "$addr" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "")
  if [[ -z "$model" ]]; then
    warn "Connected but device did not respond to queries"
    warn "Check the phone for an ADB authorization prompt"
  else
    ok "Connected to ${CYAN}${model}${NC} at ${addr}"
  fi

  WIRELESS_IP="$ip"
  WIRELESS_PORT="$port"
  save_config
  ok "Saved to config"
  return 0
}

setup_wireless() {
  while true; do
    clear; hr
    echo " ${BOLD}Wireless ADB${NC}"
    hr

    if [[ -n "$WIRELESS_IP" ]]; then
      echo " Saved: ${CYAN}${WIRELESS_IP}:${WIRELESS_PORT}${NC}"
    else
      echo " Saved: ${DIM}<none>${NC}"
    fi
    hr
    echo
    echo "  ${GREEN}1${NC}) Scan local network for ADB devices"
    echo "  ${GREEN}2${NC}) Connect to saved address"
    echo "  ${GREEN}3${NC}) Enter IP or hostname manually"
    echo "  ${GREEN}4${NC}) Clear saved address"
    echo "  ${GREEN}5${NC}) Disconnect current ADB session"
    echo
    echo "  ${GREEN}b${NC}) Back"
    echo
    read -r -p "Choice: " c
    case "$c" in
      1) scan_and_connect; pause ;;
      2)
        if [[ -z "$WIRELESS_IP" ]]; then
          warn "No saved address"
          pause
        else
          connect_and_save "$WIRELESS_IP" "$WIRELESS_PORT"
          pause
        fi
        ;;
      3) manual_connect; pause ;;
      4) WIRELESS_IP=""; save_config; ok "Saved address cleared"; sleep 1 ;;
      5)
        info "Current ADB connections:"
        adb devices | awk 'NR>1 && NF>0 {print "  " $0}'
        echo
        adb disconnect 2>&1 | sed 's/^/  /'
        ok "All wireless connections closed"
        pause
        ;;
      b|B|q|Q) return ;;
      *) warn "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ============================================================
# Developer settings (apply any time, no reboot)
# ============================================================

apply_developer_settings() {
  clear; hr
  echo " ${BOLD}Apply phone developer settings${NC}"
  hr
  cat <<EOF
Applies the developer-option tweaks required for windowed DeX on One UI 8+:

  * enable_freeform_support                 = 1
  * force_desktop_mode_on_external_displays = 1
  * enable_non_resizable_multi_window       = 1

These take effect immediately, no reboot required. You can run this any
time (for example after a factory reset or system update).

If they aren't already enabled on the phone, you'll also need:
  1. Settings > About phone > Software info > tap Build number 7 times
  2. Settings > Developer options > USB debugging (ON)
  3. USB-connect and authorize this laptop once so ADB trusts it

EOF
  read -r -p "Apply now? [Y/n] " yn
  [[ -n "$yn" && ! "$yn" =~ ^[Yy] ]] && return

  require_device || { pause; return; }

  info "Reading current values..."
  local cur_ff cur_dm cur_mw
  cur_ff=$(adb shell settings get global enable_freeform_support 2>/dev/null | tr -d '\r')
  cur_dm=$(adb shell settings get global force_desktop_mode_on_external_displays 2>/dev/null | tr -d '\r')
  cur_mw=$(adb shell settings get global enable_non_resizable_multi_window 2>/dev/null | tr -d '\r')
  echo "    enable_freeform_support:                 $cur_ff"
  echo "    force_desktop_mode_on_external_displays: $cur_dm"
  echo "    enable_non_resizable_multi_window:       $cur_mw"
  echo

  info "Applying..."
  adb shell settings put global enable_freeform_support 1
  adb shell settings put global force_desktop_mode_on_external_displays 1
  adb shell settings put global enable_non_resizable_multi_window 1

  ok "Settings applied (effective immediately)"
  pause
}

# ============================================================
# Misc actions
# ============================================================

cleanup_overlay() {
  clear; hr
  echo " ${BOLD}Remove virtual display overlay${NC}"
  hr
  require_device || { pause; return; }
  adb shell settings delete global overlay_display_devices >/dev/null 2>&1 || true
  ok "overlay_display_devices setting cleared"
  pause
}

show_status() {
  clear; hr
  echo " ${BOLD}Status${NC}"
  hr

  local dev model serial state
  dev=$(detect_device)
  model="${dev%|*|*}"
  serial=$(echo "$dev" | cut -d'|' -f2)
  state="${dev##*|}"

  if [[ "$state" == "device" ]]; then
    echo "  Device:        ${GREEN}${model}${NC}"
    echo "  Serial:        ${serial}"
    echo "  Connection:    ${GREEN}connected${NC}"
  else
    echo "  Device:        ${RED}not connected${NC}"
  fi
  echo

  echo "  ${BOLD}Configuration${NC}"
  printf "    %-18s %s\n" "Resolution:" "$RESOLUTION"
  printf "    %-18s %s\n" "DPI:"         "$DPI"
  printf "    %-18s %s\n" "Bitrate:"     "${BITRATE:-<scrcpy default>}"
  printf "    %-18s %s\n" "Audio codec:" "${AUDIO_CODEC:-<scrcpy default>}"
  printf "    %-18s %s\n" "Video codec:" "${VIDEO_CODEC:-<scrcpy default>}"
  printf "    %-18s %s\n" "Window title:" "${WINDOW_TITLE:-<scrcpy default>}"
  printf "    %-18s %s\n" "Extra flags:"  "${EXTRA_FLAGS:-<none>}"
  printf "    %-18s %s\n" "Manual mode:"  "${USE_MANUAL_COMMAND:-no}"
  if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
    printf "    %-18s %s\n" "Manual command:" "${MANUAL_COMMAND:-<empty>}"
  fi
  if [[ -n "$WIRELESS_IP" ]]; then
    printf "    %-18s %s\n" "Wireless:" "${WIRELESS_IP}:${WIRELESS_PORT}"
  else
    printf "    %-18s %s\n" "Wireless:" "<not configured>"
  fi
  echo
  echo "  ${BOLD}Effective command${NC}"
  build_scrcpy_command "<auto>"
  echo "    $(format_scrcpy_command)"
  echo
  echo "  Config file:   $CONFIG_FILE"

  if [[ "$state" == "device" ]]; then
    echo
    echo "  ${BOLD}Current overlay_display_devices${NC}"
    local overlay
    overlay=$(adb shell settings get global overlay_display_devices 2>/dev/null | tr -d '\r')
    if [[ "$overlay" == "null" || -z "$overlay" ]]; then
      echo "    <none>"
    else
      echo "    $overlay"
    fi

    echo
    echo "  ${BOLD}Developer settings state${NC}"
    local cur_ff cur_dm cur_mw
    cur_ff=$(adb shell settings get global enable_freeform_support 2>/dev/null | tr -d '\r')
    cur_dm=$(adb shell settings get global force_desktop_mode_on_external_displays 2>/dev/null | tr -d '\r')
    cur_mw=$(adb shell settings get global enable_non_resizable_multi_window 2>/dev/null | tr -d '\r')
    printf "    %-42s %s\n" "enable_freeform_support:"                 "$cur_ff"
    printf "    %-42s %s\n" "force_desktop_mode_on_external_displays:" "$cur_dm"
    printf "    %-42s %s\n" "enable_non_resizable_multi_window:"       "$cur_mw"
  fi
  pause
}

# ============================================================
# Configuration submenu
# ============================================================

configure_menu() {
  while true; do
    clear; hr
    echo " ${BOLD}Configure settings${NC}"
    hr
    echo "  ${DIM}Empty value means: use scrcpy's built-in default${NC}"
    echo
    printf "  ${GREEN}1${NC}) %-18s [${CYAN}%s${NC}]\n" "Resolution"    "$RESOLUTION"
    printf "  ${GREEN}2${NC}) %-18s [${CYAN}%s${NC}]\n" "DPI"           "$DPI"
    printf "  ${GREEN}3${NC}) %-18s [${CYAN}%s${NC}]\n" "Bitrate"       "${BITRATE:-<scrcpy default>}"
    printf "  ${GREEN}4${NC}) %-18s [${CYAN}%s${NC}]\n" "Audio codec"   "${AUDIO_CODEC:-<scrcpy default>}"
    printf "  ${GREEN}5${NC}) %-18s [${CYAN}%s${NC}]\n" "Video codec"   "${VIDEO_CODEC:-<scrcpy default>}"
    printf "  ${GREEN}6${NC}) %-18s [${CYAN}%s${NC}]\n" "Window title"  "${WINDOW_TITLE:-<scrcpy default>}"
    printf "  ${GREEN}7${NC}) %-18s [${CYAN}%s${NC}]\n" "Extra flags"   "${EXTRA_FLAGS:-<none>}"
    echo
    echo "  ${BOLD}Manual command override${NC}"
    printf "  ${GREEN}8${NC}) %-18s [${CYAN}%s${NC}]\n" "Manual mode"     "${USE_MANUAL_COMMAND:-no}"
    printf "  ${GREEN}9${NC}) %-18s [${CYAN}%s${NC}]\n" "Manual command"  "${MANUAL_COMMAND:-<empty>}"
    echo
    echo "  ${GREEN}p${NC}) Preview resulting command"
    echo "  ${GREEN}r${NC}) Reset to defaults"
    echo "  ${GREEN}e${NC}) Open config file in \$EDITOR"
    echo
    echo "  ${GREEN}b${NC}) Back to main menu"
    echo
    read -r -p "Choice: " c
    case "$c" in
      1) read -r -p "Resolution (WIDTHxHEIGHT) [$RESOLUTION]: " v; [[ -n "$v" ]] && RESOLUTION="$v" && save_config ;;
      2) read -r -p "DPI [$DPI]: " v; [[ -n "$v" ]] && DPI="$v" && save_config ;;
      3) read -r -p "Bitrate (e.g. 20M, empty=default): " v; BITRATE="$v"; save_config ;;
      4) read -r -p "Audio codec (opus/aac/flac/raw, empty=default): " v; AUDIO_CODEC="$v"; save_config ;;
      5) read -r -p "Video codec (h264/h265/av1, empty=default): " v; VIDEO_CODEC="$v"; save_config ;;
      6) read -r -p "Window title (empty=default): " v; WINDOW_TITLE="$v"; save_config ;;
      7) read -r -p "Extra scrcpy flags (empty to clear): " v; EXTRA_FLAGS="$v"; save_config ;;
      8)
        if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
          USE_MANUAL_COMMAND="no"
        else
          USE_MANUAL_COMMAND="yes"
        fi
        save_config
        ok "Manual mode is now: $USE_MANUAL_COMMAND"
        sleep 1
        ;;
      9) edit_manual_command ;;
      p|P) preview_command ;;
      r|R)
        RESOLUTION="$DEFAULT_RESOLUTION"
        DPI="$DEFAULT_DPI"
        BITRATE="$DEFAULT_BITRATE"
        AUDIO_CODEC="$DEFAULT_AUDIO_CODEC"
        VIDEO_CODEC="$DEFAULT_VIDEO_CODEC"
        WINDOW_TITLE="$DEFAULT_WINDOW_TITLE"
        EXTRA_FLAGS="$DEFAULT_EXTRA_FLAGS"
        USE_MANUAL_COMMAND="$DEFAULT_USE_MANUAL_COMMAND"
        MANUAL_COMMAND="$DEFAULT_MANUAL_COMMAND"
        save_config
        ok "Reset to defaults"
        sleep 1
        ;;
      e|E)
        ${EDITOR:-vi} "$CONFIG_FILE"
        load_config
        ok "Config reloaded"
        pause
        ;;
      b|B) return ;;
      *) warn "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ============================================================
# Main menu
# ============================================================

main_menu() {
  while true; do
    clear; hr
    echo " ${BOLD}${BLUE}DeX Manager${NC} ${DIM}(Fedora)${NC}"
    hr

    local dev state
    dev=$(detect_device)
    state="${dev##*|}"
    if [[ "$state" == "device" ]]; then
      echo "  Device:     ${GREEN}${dev%|*|*}${NC}   (${GREEN}connected${NC})"
    else
      echo "  Device:     ${RED}not connected${NC}"
    fi
    echo "  Display:    ${CYAN}${RESOLUTION}${NC} @ ${CYAN}${DPI}${NC} DPI"
    if [[ "${USE_MANUAL_COMMAND:-no}" == "yes" ]]; then
      echo "  Mode:       ${CYAN}manual${NC} (${MANUAL_COMMAND:-scrcpy defaults})"
    else
      local stream_info=""
      [[ -n "$BITRATE" ]]     && stream_info+="${BITRATE} / "
      [[ -n "$VIDEO_CODEC" ]] && stream_info+="${VIDEO_CODEC} / "
      [[ -n "$AUDIO_CODEC" ]] && stream_info+="${AUDIO_CODEC} / "
      stream_info="${stream_info% / }"
      if [[ -n "$stream_info" ]]; then
        echo "  Stream:     ${CYAN}${stream_info}${NC}"
      else
        echo "  Stream:     ${CYAN}scrcpy defaults${NC}"
      fi
    fi
    if [[ -n "$WIRELESS_IP" ]]; then
      echo "  Wireless:   ${CYAN}${WIRELESS_IP}:${WIRELESS_PORT}${NC}"
    fi
    hr
    echo
    echo "  ${GREEN}1${NC}) Launch DeX session"
    echo "  ${GREEN}2${NC}) Preview / edit launch command"
    echo "  ${GREEN}3${NC}) Wireless ADB (scan / connect / manual)"
    echo "  ${GREEN}4${NC}) Configure settings"
    echo "  ${GREEN}5${NC}) Apply phone developer settings"
    echo "  ${GREEN}6${NC}) Remove virtual display"
    echo "  ${GREEN}7${NC}) Show status"
    echo
    echo "  ${GREEN}q${NC}) Quit"
    echo
    read -r -p "Choice: " c
    case "$c" in
      1) launch_dex ;;
      2) preview_command ;;
      3) setup_wireless ;;
      4) configure_menu ;;
      5) apply_developer_settings ;;
      6) cleanup_overlay ;;
      7) show_status ;;
      q|Q|0) echo "Bye"; exit 0 ;;
      *) warn "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ============================================================
# Self-install
# ============================================================

self_install() {
  local script_path install_path desktop_file
  script_path="$(realpath "$0")"
  install_path="$HOME/.local/bin/$SCRIPT_NAME"
  desktop_file="$HOME/.local/share/applications/${SCRIPT_NAME}.desktop"

  if [[ "$script_path" == "$(realpath -q "$install_path" 2>/dev/null)" ]]; then
    return
  fi

  if [[ -f "$install_path" ]]; then
    info "Already installed at $install_path"
    read -r -p "Overwrite with this version? [y/N] " yn
    [[ ! "$yn" =~ ^[Yy] ]] && return
  else
    echo
    info "This script is not yet installed to $install_path"
    read -r -p "Install it there for easy launching? [Y/n] " yn
    [[ -n "$yn" && ! "$yn" =~ ^[Yy] ]] && return
  fi

  mkdir -p "$HOME/.local/bin"
  cp "$script_path" "$install_path"
  chmod +x "$install_path"
  ok "Installed to $install_path"

  read -r -p "Create GNOME Activities launcher? [Y/n] " yn
  if [[ -z "$yn" || "$yn" =~ ^[Yy] ]]; then
    mkdir -p "$(dirname "$desktop_file")"
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=DeX Manager
Comment=Run Samsung DeX in a window via scrcpy
Exec=gnome-terminal --title="DeX Manager" -- $install_path
Icon=phone
Terminal=false
Type=Application
Categories=Utility;Network;
Keywords=dex;samsung;scrcpy;android;
EOF
    ok "Launcher created: $desktop_file"
  fi

  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
    warn "$HOME/.local/bin is not on your PATH"
    warn "Add to ~/.bashrc:"
    warn "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  echo
  info "Run with: $SCRIPT_NAME"
  pause
}

# ============================================================
# Direct-action shortcuts (bypass menu)
# ============================================================

handle_direct_action() {
  local action="${1:-}"
  case "$action" in
    launch)   launch_dex ;;
    status)   show_status ;;
    cleanup)  cleanup_overlay ;;
    devsettings|apply) apply_developer_settings ;;
    wireless) setup_wireless ;;
    config)   configure_menu ;;
    preview)  preview_command ;;
    help|-h|--help)
      cat <<EOF
Usage: $SCRIPT_NAME [ACTION]

Without an action, opens the interactive menu.

Actions:
  launch         Launch a DeX session immediately
  status         Show current device and config status
  cleanup        Remove the virtual display overlay
  devsettings    Apply phone developer settings (no reboot)
  wireless       Open the wireless ADB menu (scan/connect)
  config         Open configuration menu
  preview        Preview the scrcpy command that would be run
  help           This message

Config file: $CONFIG_FILE
EOF
      ;;
    *) return 1 ;;
  esac
  return 0
}

# ============================================================
# Main
# ============================================================

main() {
  mkdir -p "$STATE_DIR"
  check_prerequisites
  load_config

  if [[ $# -gt 0 ]]; then
    handle_direct_action "$@" && exit 0
    err "Unknown action: $1"
    handle_direct_action help
    exit 1
  fi

  self_install
  main_menu
}

main "$@"
