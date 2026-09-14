#!/usr/bin/env bash
# ===========================================================================================
# Pure Protect Configurator for Linux
#
# This script reads network configuration from VMware guest info properties and applies
# static IP addresses, gateways, and DNS servers to network adapters.
#
# On first run, the script installs itself to a permanent location, creates a new systemd
# service (or cron job on systems without systemd), and sets up scheduled execution to run
# on system startup. On normal startup, the script performs no network configuration.
# Network configuration is only applied after a recovery operation has been executed.
#
# Uninstall: run the script with `--uninstall` (requires root). This stops and removes the
# scheduled execution (systemd service or cron job) and deletes the installed script and its
# log files. If a post-failover script is present in the install directory, the directory is
# kept and only the configurator files are removed.
# Note: the pureprotect.* guest-info properties are left in place. The VMware Tools RPC
# interface cannot delete or empty guestinfo keys from inside a guest. The properties are
# inert once the configurator is removed and are cleared automatically on the next VM power cycle.
# ===========================================================================================

set -eu

IFS=$IFS, # adds comma as delimiter character for splitting DNS addresses

# ===========================================================================================
# Installation & Scheduling Configuration
# ===========================================================================================
SCRIPT_VERSION="2.25.0"
INSTALL_PATH="/usr/local/pureprotect/scripts/configurator.sh"
INSTALL_DIR=$(dirname "$INSTALL_PATH")
SERVICE_NAME="pureprotect-configurator.service"
CRON_NAME="pureprotect-configurator"
SYSTEMD_DIR="/etc/systemd/system"
CRON_FILE="/etc/cron.d/$CRON_NAME"
CUSTOMER_SCRIPT_PATH="${INSTALL_DIR}/post-failover.sh"

# ===========================================================================================
# Installation & Scheduling Functions
# ===========================================================================================

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

is_installed_location() {
  local current_script
  current_script=$(readlink -f "$0")
  [ "$current_script" = "$INSTALL_PATH" ]
}

is_schedule_installed() {
  if has_systemd; then
    [ -f "$SYSTEMD_DIR/$SERVICE_NAME" ]
  else
    [ -f "$CRON_FILE" ]
  fi
}

install_script() {
  log_message "[Install] Installing Pure Protect Configurator..."

  local current_script
  current_script=$(readlink -f "$0")
  cp "$current_script" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  log_message "[Install] Installed script to: $INSTALL_PATH"

  set_guest_info "installed" "true"
}

install_systemd_schedule() {
  log_message "[Scheduling] Installing systemd service..."

  cat > "$SYSTEMD_DIR/$SERVICE_NAME" << SERVICEEOF
[Unit]
Description=Pure Protect Configurator
Documentation=https://support.purestorage.com
After=network-online.target vmtoolsd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"

  log_message "[Scheduling] Systemd service installed successfully"
  log_message "[Scheduling]   Service: $SERVICE_NAME (runs at boot)"
}

install_cron_schedule() {
  log_message "[Scheduling] Installing cron job..."

  cat > "$CRON_FILE" << CRONEOF
# Pure Protect Configurator
# Runs on system startup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

@reboot root sleep 60 && $INSTALL_PATH >/dev/null 2>&1
CRONEOF

  chmod 644 "$CRON_FILE"
  log_message "[Scheduling] Cron job installed successfully"
  log_message "[Scheduling]   Cron file: $CRON_FILE"
  log_message "[Scheduling]   Schedule: @reboot"
}

perform_installation() {
  if is_installed_location; then
    log_message "[Install] Already running from installed location"
    set_guest_info "installed" "true"

    if is_schedule_installed; then
      log_message "[Install] Schedule already installed, skipping installation"
      return
    fi

    log_message "[Install] Schedule not found, installing schedule..."
  else
    log_message "[Install] First run detected, installing script..."
    install_script
  fi

  if has_systemd; then
    install_systemd_schedule
  else
    install_cron_schedule
  fi

  log_message "[Install] Installation complete"
}

report_customer_script_existence() {
  if [[ -f "$CUSTOMER_SCRIPT_PATH" ]]; then
    log_message "[Customer Script] Script exists at $CUSTOMER_SCRIPT_PATH"
    set_guest_info "customer.exists" "true"
  else
    log_message "[Customer Script] Script does not exist at $CUSTOMER_SCRIPT_PATH"
    set_guest_info "customer.exists" "false"
  fi
}

# ===========================================================================================
# Uninstall Functions
# ===========================================================================================

perform_uninstall() {
  echo "[Uninstall] Starting uninstall"

  if has_systemd && [ -f "$SYSTEMD_DIR/$SERVICE_NAME" ]; then
    echo "[Uninstall] Removing systemd service: $SERVICE_NAME"
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    rm -f "$SYSTEMD_DIR/$SERVICE_NAME"
    systemctl daemon-reload
  fi

  if [ -f "$CRON_FILE" ]; then
    echo "[Uninstall] Removing cron file: $CRON_FILE"
    rm -f "$CRON_FILE"
  fi

  local preserve_install_dir=false
  if [ -d "$INSTALL_DIR" ] && [ -f "$CUSTOMER_SCRIPT_PATH" ]; then
    preserve_install_dir=true
    echo "[Uninstall] Customer script present at $CUSTOMER_SCRIPT_PATH; preserving $INSTALL_DIR"
    if [ -f "$INSTALL_PATH" ]; then
      echo "[Uninstall] Removing installed script: $INSTALL_PATH"
    fi
    echo "[Uninstall] Removing configurator log files from $INSTALL_DIR"
  elif [ -d "$INSTALL_DIR" ]; then
    echo "[Uninstall] Removing install directory: $INSTALL_DIR"
  fi

  # File operations last.
  if [ -d "$INSTALL_DIR" ]; then
    if $preserve_install_dir; then
      rm -f "$INSTALL_PATH"
      find "$INSTALL_DIR" -maxdepth 1 -type f -name 'configurator-*.log' -delete
    else
      rm -rf "$INSTALL_DIR"
      local parent_dir
      parent_dir=$(dirname "$INSTALL_DIR")
      if [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir")" ]; then
        echo "[Uninstall] Removing empty parent directory: $parent_dir"
        rm -rf "$parent_dir"
      fi
    fi
  fi

  echo "[Uninstall] Complete"
}

# ===========================================================================================
# Logging Configuration
# ===========================================================================================
LOG_TIMESTAMP_SUFFIX=$(date -u +"%Y%m%d_%H%M%S")
LOG_FILE="$INSTALL_DIR/configurator-${LOG_TIMESTAMP_SUFFIX}.log"

# Ensure directory exists before any logging can occur
mkdir -p "$INSTALL_DIR" 2>/dev/null || true

remove_old_log_files() {
  local keep_count=5
  find "$INSTALL_DIR" -maxdepth 1 -name 'configurator-*.log' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +$((keep_count + 1)) | cut -d' ' -f2- \
    | while IFS= read -r file; do
        if rm -f "$file" 2>/dev/null; then
          log_message "[Cleanup] Removed old log file: $(basename "$file")"
        fi
      done
}

log_message() {
  local message
  message="[$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")] $1"
  echo "$message"
  echo "$message" >> "$LOG_FILE" 2>/dev/null || true
}

log_output() {
  local message
  while IFS= read -r line; do
    message="[$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")] $line"
    echo "$message"
    echo "$message" >> "$LOG_FILE" 2>/dev/null || true
  done
}

flush_log_to_guest_info() {
  # Write log to guest info property (base64 encoded, truncated to ~48KB to stay under 64KB limit after encoding)
  if [ -f "$LOG_FILE" ]; then
    local encoded_log
    encoded_log=$(tail -c 48000 "$LOG_FILE" | { base64 -w 0 2>/dev/null || base64; })
    set_guest_info "exec.log" "$encoded_log"
  fi
}

get_guest_info() {
  local key="$1"
  local full_key
  if [[ "$key" == guestinfo.* ]]; then
    full_key="$key"
  else
    full_key="guestinfo.pureprotect.script.$key"
  fi
  # Avoids vmtoolsd RPC throttle that returns empty results or hangs ~2s on back-to-back calls.
  sleep 0.1
  vmtoolsd --cmd "info-get $full_key" 2>/dev/null || echo ""
}

set_guest_info() {
  local key="$1"
  local value="$2"
  local full_key="guestinfo.pureprotect.script.$key"
  sleep 0.1
  vmtoolsd --cmd "info-set $full_key $value" 2>/dev/null || true
}

NETWORK_ERROR_CODE=0

exit_with_error() {
  local exit_code="$1"
  local error_message="$2"
  log_message "ERROR: $error_message"
  set_guest_info "exec.exitCode" "$exit_code"
  set_guest_info "exec.errorMessage" "$error_message"
  set_guest_info "exec.endTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
  flush_log_to_guest_info
  exit "$exit_code"
}

report_network_result() {
  local exit_code="$1"
  local message="$2"
  log_message "$message"
  if [[ "$exit_code" -ne 0 ]]; then
    NETWORK_ERROR_CODE="$exit_code"
    set_guest_info "network.errorMessage" "$message"
  fi
  set_guest_info "network.exitCode" "$exit_code"
  set_guest_info "network.endTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
}

complete_execution() {
  set_guest_info "exec.exitCode" "0"
  set_guest_info "exec.endTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
  log_message "Script execution completed"
  flush_log_to_guest_info
  exit 0
}

NETWORK_CONFIG_PRESENT=false

init_nic_data() {
  local nic_count
  nic_count=$(get_guest_info "network.nicCount")

  if [[ -z "$nic_count" ]]; then
    local probe
    probe=$(get_guest_info "guestinfo.vmtools.buildNumber")
    if [[ -z "$probe" ]]; then
      log_message "[Network configuration] info-get visibility check failed"
    else
      log_message "[Network configuration] No network configuration will be performed in this run"
    fi
    report_network_result "17" "Network configuration was skipped because the script did not detect any network properties on this VM"
    NETWORK_CONFIG_PRESENT=false
    return
  fi
  if [[ "$nic_count" == "0" ]]; then
    log_message "[Network configuration] No network configuration will be performed in this run"
    report_network_result "17" "Network configuration was skipped because the script did not detect any network properties on this VM"
    NETWORK_CONFIG_PRESENT=false
    return
  fi

  NETWORK_CONFIG_PRESENT=true

  # Set network configuration start timestamp (only when network config is present)
  set_guest_info "network.startTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"

  log_message "Found $nic_count NIC(s) to configure from guest info properties"

  # Build NIC arrays from guest info properties
  NIC_MACS=()
  NIC_PCI_SLOTS=()
  NIC_IPS=()
  NIC_GWS=()
  NIC_DNSS=()

  for ((i=0; i<nic_count; i++)); do
    local mac pci_slot ip gateway dns
    mac=$(get_guest_info "network.nic.$i.mac")
    pci_slot=$(get_guest_info "network.nic.$i.pciSlot")
    ip=$(get_guest_info "network.nic.$i.ip")
    gateway=$(get_guest_info "network.nic.$i.gateway")
    dns=$(get_guest_info "network.nic.$i.dns")

    NIC_MACS+=("$mac")
    NIC_PCI_SLOTS+=("$pci_slot")
    NIC_IPS+=("$ip")
    NIC_GWS+=("$gateway")
    NIC_DNSS+=("$dns")
    log_message "NIC $i: MAC=$mac, PCI=$pci_slot, IP=$ip, Gateway=$gateway, DNS=$dns"
  done
}

check_vmtoolsd() {
  if ! command -v vmtoolsd >/dev/null 2>&1; then
    echo "Error: vmtoolsd not found. VMware Tools must be installed and running." >&2
    exit 18
  fi

  # Set execution start timestamp
  local start_time
  start_time=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  set_guest_info "exec.startTimestamp" "$start_time"
}

check_root() {
  if [ "$(id -u)" != 0 ]; then
    exit_with_error 10 "Must be run as root"
  fi
}

detect_network_stack() {
  # netplan takes top priority on most recent Ubuntu/Debian derivatives
  if command -v netplan >/dev/null 2>&1 && [ -d /etc/netplan ] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    echo netplan; return
  fi

  # NetworkManager (nmcli) if running
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo NetworkManager; return
  fi

  # ifconfig with ifcfg files in network-scripts
  if [ -d /etc/sysconfig/network-scripts ] && ls /etc/sysconfig/network-scripts/ifcfg-e* >/dev/null 2>&1; then
    echo ifconfig-rhel; return
  fi

  # ifconfig with ifcfg and config/routes files
  if [ -f /etc/sysconfig/network/config ] && [ -f /etc/sysconfig/network/routes ] && ls /etc/sysconfig/network/ifcfg-e* >/dev/null 2>&1; then
    echo ifconfig-sles; return
  fi

  # systemd-networkd
  if systemctl is-active --quiet systemd-networkd 2>/dev/null && ls /etc/systemd/network/*.network >/dev/null 2>&1; then
    echo systemd-networkd; return
  fi

  echo unknown
}

configure_netplan() {
  log_message "[netplan] Configuring static network settings"
  NETPLAN_DIR=/etc/netplan
  NETPLAN_DRAAS_FILE=99-draas.yaml
  NETPLAN_DRAAS_PATH=$NETPLAN_DIR/$NETPLAN_DRAAS_FILE

  log_message "[netplan] Files in /etc/netplan:"
  ls -1 /etc/netplan | log_output

  # Remove existing draas netplan configuration if it exists
  [ -f "$NETPLAN_DRAAS_PATH" ] && rm -f "$NETPLAN_DRAAS_PATH" && log_message "[netplan] Removed existing $NETPLAN_DRAAS_PATH"

  # Backup existing netplan YAML files
  for yaml_file in /etc/netplan/*.yaml; do
    [ -e "$yaml_file" ] || break
    mv -- "$yaml_file" "$yaml_file.backup"
    log_message "Backed up $yaml_file → $yaml_file.backup"
  done

  {
    cat <<EOF
# Generated by Pure Protect on $(date -Is)
network:
  version: 2
  renderer: networkd
  ethernets:
EOF
    for idx in "${!NIC_MACS[@]}"; do
      cat <<EOF
    nic${idx}:
      dhcp4: false
      dhcp6: false
      match:
        macaddress: "${NIC_MACS[$idx]}"
      set-name: draas-nic${idx}
      addresses:
        - ${NIC_IPS[$idx]}
EOF
      if [[ -n "${NIC_GWS[$idx]}" ]]; then
        cat <<EOF
      gateway4: ${NIC_GWS[$idx]}
EOF
      fi
      if [[ -n "${NIC_DNSS[$idx]}" ]]; then
        cat <<EOF
      nameservers:
        addresses: [ ${NIC_DNSS[$idx]} ]
EOF
      fi
    done
  } > "$NETPLAN_DRAAS_PATH"

  log_message "[netplan] Created netplan configuration file $NETPLAN_DRAAS_PATH"
  log_message "[netplan] File content:"
  cat "$NETPLAN_DRAAS_PATH" | log_output

  chown root:root "$NETPLAN_DRAAS_PATH"
  chmod 600 "$NETPLAN_DRAAS_PATH"

  netplan apply
  log_message "[netplan] Static network settings applied successfully"
}

disable_competing_connections() {
  local iface=$1 mac=$2 keep=$3
  local uuid name intf cmac

  while IFS= read -r uuid; do
    [[ -z "$uuid" ]] && continue

    name=$(nmcli -g connection.id connection show "$uuid" 2>/dev/null) || true
    [[ "$name" == "$keep" ]] && continue

    intf=$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null) || true
    cmac=$(nmcli -g 802-3-ethernet.mac-address connection show "$uuid" 2>/dev/null) || true

    if [[ "$intf" == "$iface" ]] || { [[ -n "$cmac" ]] && [[ "${cmac,,}" == "${mac,,}" ]]; }; then
      log_message "[NetworkManager] Disabling autoconnect on competing connection '$name' ($uuid) bound to $iface"
      if nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1; then
        # Release the device now if this profile currently holds it; harmless otherwise.
        nmcli connection down "$uuid" >/dev/null 2>&1 || true
      else
        log_message "[NetworkManager] WARNING: failed to disable autoconnect on '$name' ($uuid)"
      fi
    fi
  done < <(nmcli -t -f UUID connection show)
}

delete_draas_connections() {
  local name
  while IFS= read -r name; do
    case "$name" in
      draas-nic*)
        log_message "[NetworkManager] Deleting existing connection '$name'"
        nmcli connection delete "$name" >/dev/null 2>&1 \
          || log_message "[NetworkManager] WARNING: failed to delete connection '$name'"
        ;;
    esac
  done < <(nmcli -t -f NAME connection show)
}

configure_network_manager() {
  log_message "[NetworkManager] Configuring static network settings"

  # Delete every draas-nic* profile from a previous recovery, up front and
  # regardless of the current NIC set.
  delete_draas_connections

  for idx in "${!NIC_MACS[@]}"; do
    mac="${NIC_MACS[$idx]}"
    ipaddr="${NIC_IPS[$idx]}"
    gateway="${NIC_GWS[$idx]}"
    dns="${NIC_DNSS[$idx]:-}"
    conn_name="draas-nic${idx}"

    log_message "[NetworkManager] Processing MAC $mac (index $idx)"

    # Find interface name by MAC
    iface=$(ip -o link show | awk -v mac="$mac" 'BEGIN{IGNORECASE=1} $0 ~ mac {print $2}' | sed 's/://')
    if [[ -z "$iface" ]]; then
      report_network_result 12 "[NetworkManager] ERROR: Could not find interface for MAC $mac"
      return
    fi
    log_message "[NetworkManager] Found interface: $iface"

    # Create new static connection. A high autoconnect-priority makes this profile
    # win the interface at boot over any profile left at the default priority 0.
    if [[ -z "$gateway" ]]; then
        add_cmd=(nmcli connection add type ethernet ifname "$iface" con-name "$conn_name" autoconnect yes
             connection.autoconnect-priority 999
             ipv4.method manual ipv4.addresses "$ipaddr" ipv4.dns "$dns" ipv6.method ignore)
    else
        add_cmd=(nmcli connection add type ethernet ifname "$iface" con-name "$conn_name" autoconnect yes
            connection.autoconnect-priority 999
            ipv4.method manual ipv4.addresses "$ipaddr" ipv4.gateway "$gateway" ipv4.dns "$dns" ipv6.method ignore)
    fi

    log_message "[NetworkManager] Adding connection: ${add_cmd[*]}"
    if ! "${add_cmd[@]}" >/dev/null; then
      report_network_result 13 "[NetworkManager] ERROR: Failed to add connection for $iface"
      return
    fi

    # Bring the connection up
    if nmcli connection up "$conn_name" >/dev/null; then
      log_message "[NetworkManager] Activated connection '$conn_name' ($iface) with IP $ipaddr"
    else
      report_network_result 13 "[NetworkManager] WARNING: Failed to activate connection '$conn_name'"
      return
    fi

    # With draas-nic<idx> now holding the interface, disable autoconnect on every
    # other profile bound to it so the interface cannot be reclaimed on reboot.
    disable_competing_connections "$iface" "$mac" "$conn_name"
  done

  log_message "[NetworkManager] Static network settings applied."
}

ifconfig_device_restart() {
  local device=$1
  local log_prefix=$2

  log_message ""
  log_message "[$log_prefix] Bringing $device down"
  ifdown $device

  log_message "[$log_prefix] Bringing $device up"
  if ifup $device; then
    log_message "[$log_prefix] Configuration of $device has been updated successfully"
  else
    report_network_result 13 "[$log_prefix] WARNING: Failed to update configuration of $device (exit code $?)"
  fi
}

configure_ifconfig_rhel() {
  IFCONFIG_DIR=/etc/sysconfig/network-scripts

  log_message "[ifconfig-rhel] Configuring static network settings"
  log_message "[ifconfig-rhel] Files in $IFCONFIG_DIR:"
  ls -1 $IFCONFIG_DIR | log_output

  for idx in "${!NIC_MACS[@]}"; do
    mac="${NIC_MACS[$idx]}"
    ip_and_prefix=${NIC_IPS[$idx]}
    ip=$(echo $ip_and_prefix | cut -d/ -f1)
    prefix=$(echo $ip_and_prefix | cut -d/ -f2)

    log_message ""
    log_message "[ifconfig-rhel] Processing MAC address $mac (index $idx)"

    # Find interface name by MAC
    device=$(ip -o link show | awk -v mac="$mac" 'BEGIN{IGNORECASE=1} $0 ~ mac {print $2}' | sed 's/://')
    if [[ -z "$device" ]]; then
      report_network_result 12 "[ifconfig-rhel] Could not find interface for MAC address $mac"
      return
    fi

    log_message "[ifconfig-rhel] Setting up configuration of interface $device"
    filename=ifcfg-$device
    if [ -s "$IFCONFIG_DIR/$filename" ] ; then
      log_message "[ifconfig-rhel] Current contents of $filename file:"
      cat "$IFCONFIG_DIR/$filename" | log_output
    else
      log_message "[ifconfig-rhel] $filename file is empty or does not exist yet"
    fi

    log_message "[ifconfig-rhel] New contents of $filename file:"
    {
      cat <<EOF
# Generated by Pure Protect on $(date -Is)
TYPE=Ethernet
NAME=$device
DEVICE=$device
HWADDR=${NIC_MACS[$idx]}
IPADDR=$ip
PREFIX=$prefix
BOOTPROTO=no
DEFROUTE=yes
PROXY_METHOD=none
BROWSER_ONLY=no
ONBOOT=yes
EOF
      if [[ -n "${NIC_GWS[$idx]}" ]]; then
        cat <<EOF
GATEWAY=${NIC_GWS[$idx]}
EOF
      fi

      dns_count=0
      for dns in ${NIC_DNSS[$idx]}; do
        dns_count=$((dns_count+1))
        cat <<EOF
DNS$dns_count=$dns
EOF
      done
    } > "$IFCONFIG_DIR/$filename"
    cat "$IFCONFIG_DIR/$filename" | log_output

    ifconfig_device_restart $device "ifconfig-rhel"
    [[ $NETWORK_ERROR_CODE -ne 0 ]] && return

    log_message ""
  done

  log_message "[ifconfig-rhel] Static network settings applied"
}

configure_ifconfig_sles() {
  IFCONFIG_DIR=/etc/sysconfig/network

  log_message "[ifconfig-sles] Configuring static network settings"
  log_message "[ifconfig-sles] Files in $IFCONFIG_DIR:"
  ls -1 $IFCONFIG_DIR | log_output
  log_message ""

  if [[ -n "${NIC_GWS[0]}" ]]; then
      gw_file=$IFCONFIG_DIR/routes
      gw_string="default ${NIC_GWS[0]} - -"
      log_message "[ifconfig-sles] Setting up default gateway: ${NIC_GWS[0]}"

      if [ -s $gw_file ] && [[ ! -z $(grep '[^[:space:]]' $gw_file) ]] ; then
        log_message "[ifconfig-sles] Current contents of $gw_file file:"
        cat $gw_file | log_output
        if grep -q '^\s*default\s' $gw_file; then
          sed -i "s/\s*default\s\+.*/$gw_string/" $gw_file
        else
          log_message "[ifconfig-sles] default route not found, appending"
          echo $gw_string >> $gw_file
        fi
      else
        log_message "[ifconfig-sles] $gw_file file is empty"
        echo $gw_string > $gw_file
      fi
      log_message "[ifconfig-sles] New contents of $gw_file file:"
      cat $gw_file | log_output
      log_message ""
  fi

  read -ra dns_array <<< "${NIC_DNSS[0]}"
  dns_joined="${dns_array[*]}"
  dns_string="NETCONFIG_DNS_STATIC_SERVERS=\"$dns_joined\""
  dns_file=$IFCONFIG_DIR/config
  log_message "[ifconfig-sles] Setting up DNS: $dns_joined"
  if [ -s "$dns_file" ]; then
    log_message "[ifconfig-sles] Current values in $dns_file file:"
    grep NETCONFIG_DNS_STATIC_SERVERS "$dns_file" | log_output || true
    if grep -q NETCONFIG_DNS_STATIC_SERVERS "$dns_file"; then
      sed -i "s/\s*NETCONFIG_DNS_STATIC_SERVERS=.*/$dns_string/" "$dns_file"
    else
      log_message "[ifconfig-sles] NETCONFIG_DNS_STATIC_SERVERS not found, appending"
      echo "$dns_string" >> "$dns_file"
    fi
  else
    log_message "[ifconfig-sles] $dns_file file is empty"
    echo "$dns_string" >> "$dns_file"
  fi
  log_message "[ifconfig-sles] New values in $dns_file file:"
  grep NETCONFIG_DNS_STATIC_SERVERS "$dns_file" | log_output || true
  log_message ""

  for idx in "${!NIC_MACS[@]}"; do
    mac="${NIC_MACS[$idx]}"
    ip_and_prefix=${NIC_IPS[$idx]}

    log_message "[ifconfig-sles] Processing MAC address $mac (index $idx)"

    # Find interface name by MAC
    device=$(ip -o link show | awk -v mac="$mac" 'BEGIN{IGNORECASE=1} $0 ~ mac {print $2}' | sed 's/://')
    if [[ -z "$device" ]]; then
      report_network_result 12 "[ifconfig-sles] Could not find interface for MAC address $mac"
      return
    fi

    log_message "[ifconfig-sles] Setting up configuration of interface $device"
    filename=ifcfg-$device
    if [ -s "$IFCONFIG_DIR/$filename" ] ; then
      log_message "[ifconfig-sles] Current contents of $filename file:"
      cat "$IFCONFIG_DIR/$filename" | log_output
    else
      log_message "[ifconfig-sles] $filename file is empty or does not exist yet"
    fi

    log_message "[ifconfig-sles] New contents of $filename file:"
    {
      cat <<EOF
# Generated by Pure Protect on $(date -Is)
NAME=$device
IPADDR=$ip_and_prefix
BOOTPROTO=static
STARTMODE=auto
EOF
    } > "$IFCONFIG_DIR/$filename"
    cat "$IFCONFIG_DIR/$filename" | log_output

    ifconfig_device_restart $device "ifconfig-sles"
    [[ $NETWORK_ERROR_CODE -ne 0 ]] && return

    log_message ""
  done

  log_message "[ifconfig-sles] Static network settings applied"
}

configure_systemd_networkd() {
  NETWORK_DIR=/etc/systemd/network

  log_message "[systemd] Configuring static network settings"
  log_message "[systemd] Files in $NETWORK_DIR:"
  ls -1 $NETWORK_DIR | log_output
  log_message ""

  for idx in "${!NIC_MACS[@]}"; do
    mac="${NIC_MACS[$idx]}"
    ip_and_prefix=${NIC_IPS[$idx]}

    log_message "[systemd] Processing MAC address $mac (index $idx)"

    # Find interface name by MAC
    device=$(ip -o link show | awk -v mac="$mac" 'BEGIN{IGNORECASE=1} $0 ~ mac {print $2}' | sed 's/://')
    if [[ -z "$device" ]]; then
      report_network_result 12 "[systemd] Could not find interface for MAC address $mac"
      return
    fi

    log_message "[systemd] Setting up configuration of interface $device"

    # Find file containing device name and remove directory part (grep might return the full path)
    filename=$(grep --include=*.network -lre "Name=$device" $NETWORK_DIR | sed 's/\/etc\/systemd\/network\///')
    if [[ -z "$filename" ]] ; then
      log_message "[systemd] Configuration file does not exist yet"
      filename=50-$device.network
    else
      log_message "[systemd] Current contents of $filename file:"
      cat "$NETWORK_DIR/$filename" | log_output
    fi

    log_message "[systemd] New contents of $filename file:"
    {
      cat <<EOF
# Generated by Pure Protect on $(date -Is)
[Match]
Name=$device

[Network]
Address=$ip_and_prefix
EOF
      if [[ -n "${NIC_GWS[0]}" ]]; then
        cat <<EOF
Gateway=${NIC_GWS[0]}
EOF
      fi

      for dns in ${NIC_DNSS[$idx]}; do
        cat <<EOF
DNS=$dns
EOF
      done
    } > "$NETWORK_DIR/$filename"
    cat "$NETWORK_DIR/$filename" | log_output
    log_message ""
  done

  networkctl reload

  log_message "[systemd] Static network settings applied"
}

configure_network() {
  init_nic_data

  if [[ "$NETWORK_CONFIG_PRESENT" != "true" ]]; then
    return
  fi

  STACK=$(detect_network_stack)
  log_message "Detected networking stack: $STACK"

  case $STACK in
    netplan) configure_netplan ;;
    NetworkManager) configure_network_manager ;;
    ifconfig-rhel) configure_ifconfig_rhel ;;
    ifconfig-sles) configure_ifconfig_sles ;;
    systemd-networkd) configure_systemd_networkd ;;
    *)
      report_network_result 11 "Error: unsupported network management system."
      return
      ;;
  esac

  if [[ $NETWORK_ERROR_CODE -eq 0 ]]; then
    report_network_result 0 "Network configuration completed successfully"
  fi
}

# ===========================================================================================
# Customer Script Execution
# ===========================================================================================
CUSTOMER_SCRIPT_LOG_PATH="${INSTALL_DIR}/post-failover-${LOG_TIMESTAMP_SUFFIX}.log"

execute_customer_script() {
  local should_run
  should_run=$(get_guest_info "customer.shouldRun")

  if [[ "$should_run" != "true" ]]; then
    log_message "[Customer Script] No customer script will be executed in this run (shouldRun=$should_run)"
    return
  fi

  log_message "[Customer Script] Execution requested, checking for script at $CUSTOMER_SCRIPT_PATH"

  if [[ ! -f "$CUSTOMER_SCRIPT_PATH" ]]; then
    log_message "[Customer Script] Script not found at $CUSTOMER_SCRIPT_PATH"
    set_guest_info "customer.exitCode" "19"
    set_guest_info "customer.errorMessage" "Customer script not found at $CUSTOMER_SCRIPT_PATH"
    set_guest_info "customer.endTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"
    return
  fi

  log_message "[Customer Script] Script found, starting execution"
  log_message "[Customer Script] Output will be logged to $CUSTOMER_SCRIPT_LOG_PATH"

  # Record start timestamp
  set_guest_info "customer.startTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"

  # Execute customer script, capturing stdout and stderr separately
  local script_exit_code
  local stderr_path="${CUSTOMER_SCRIPT_LOG_PATH}.err"
  if /bin/bash "$CUSTOMER_SCRIPT_PATH" > "$CUSTOMER_SCRIPT_LOG_PATH" 2>"$stderr_path"; then
    script_exit_code=0
  else
    script_exit_code=$?
  fi

  # Capture stderr content if present
  local stderr_content=""
  if [[ -s "$stderr_path" ]]; then
    log_message "[Customer Script] Stderr output detected, appending to log"
    stderr_content=$(cat "$stderr_path")
    printf "\n--- STDERR ---\n" >> "$CUSTOMER_SCRIPT_LOG_PATH"
    cat "$stderr_path" >> "$CUSTOMER_SCRIPT_LOG_PATH"
  fi
  rm -f "$stderr_path"

  # Record end timestamp
  set_guest_info "customer.endTimestamp" "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")"

  # Report results
  if [[ $script_exit_code -eq 0 ]]; then
    log_message "[Customer Script] Execution completed successfully"
    set_guest_info "customer.exitCode" "0"
    # Report stderr as error message even on success
    if [[ -n "$stderr_content" ]]; then
      log_message "[Customer Script] Warning: stderr output detected despite successful exit code"
      set_guest_info "customer.errorMessage" "$stderr_content"
    fi
  else
    log_message "[Customer Script] Execution failed with exit code $script_exit_code"
    set_guest_info "customer.exitCode" "$script_exit_code"
    if [[ -n "$stderr_content" ]]; then
      set_guest_info "customer.errorMessage" "$stderr_content"
    else
      set_guest_info "customer.errorMessage" "Customer script failed with exit code $script_exit_code. Check log at $CUSTOMER_SCRIPT_LOG_PATH"
    fi
  fi
}


main() {
  log_message "Script version: $SCRIPT_VERSION"
  # `--uninstall` reverses installation: removes the systemd service / cron job, clears all
  # guest-info properties, and deletes the installed script and logs (the install directory is
  # preserved if it holds a customer script). Best-effort and root-only; it proceeds even
  # without vmtoolsd, where guest-info clearing is a silent no-op.
  if [[ "${1:-}" == "--uninstall" ]]; then
    check_root
    perform_uninstall
    exit 0
  fi

  remove_old_log_files
  check_root
  check_vmtoolsd
  set_guest_info "version" "$SCRIPT_VERSION"
  perform_installation
  report_customer_script_existence
  configure_network
  execute_customer_script
  complete_execution
}

main "$@"
