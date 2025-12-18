#!/bin/bash

# --- Configuration ---
PRIMARY_VM_PATTERN="netBridge1-service" # The base name for running VMs
TEMPLATE_VM="netBridge1"                # The shut-off "golden image" template

CPU_THRESHOLD=70 # Trigger scaling when CPU is over this %
MAX_VMS=2        # The maximum number of service VMs to run
NGINX_CONF="/etc/nginx/conf.d/load_balancer.conf"

# --- NEW: Cleanup Function ---
# This function is called when the script is interrupted (Ctrl+C).
cleanup() {
  echo -e "\n\n Caught interrupt signal. Cleaning up all service VMs..."

  # Find all VMs matching the pattern (running or shut off)
  ALL_SERVICE_VMS=$(sudo virsh list --all --name | grep "$PRIMARY_VM_PATTERN")

  if [ -n "$ALL_SERVICE_VMS" ]; then
    echo "Found the following VMs to delete:"
    echo "$ALL_SERVICE_VMS"

    for vm in $ALL_SERVICE_VMS; do
      echo "Deleting VM: $vm..."
      # Destroy (force power-off) if it's running
      if sudo virsh dominfo "$vm" | grep -q "State: *running"; then
        sudo virsh destroy "$vm" --graceful >/dev/null 2>&1
      fi
      # Undefine (delete config) and remove its storage disk
      sudo virsh undefine "$vm" --remove-all-storage >/dev/null 2>&1
    done
    echo "All service VMs have been deleted."
  else
    echo "No service VMs found to clean up."
  fi

  # Reset Nginx config to a safe default
  echo "Resetting Nginx configuration..."
  sudo sh -c "echo '
# This file is auto-managed. No backends are currently active.
server {
    listen 80;
    location / {
        return 503; # Service Unavailable
    }
}' > $NGINX_CONF"
  sudo nginx -t && sudo systemctl reload nginx >/dev/null 2>&1

  echo "Cleanup complete. Exiting."
  exit 0
}

# --- NEW: Trap Command ---
# This line tells the script to run the 'cleanup' function when Ctrl+C is pressed.
trap cleanup INT

# --- Function to update Nginx Config ---
update_nginx_config() {
  # (This function is unchanged from the previous version)
  echo "Updating Nginx config..."
  TMP_CONF=$(mktemp)
  echo "upstream backend {" >"$TMP_CONF"
  LIVE_VMS=$(sudo virsh list --name --state-running | grep "$PRIMARY_VM_PATTERN")
  if [ -z "$LIVE_VMS" ]; then echo "Warning: No live VMs found to add to Nginx."; fi
  for vm in $LIVE_VMS; do
    IP=$(sudo virsh domifaddr "$vm" | grep -oE '[0-9]+\.[0-g]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$IP" ]; then
      echo "Found $vm at $IP"
      echo "    server $IP;" >>"$TMP_CONF"
    fi
  done
  cat >>"$TMP_CONF" <<EOF
}
server {
    listen 80;
    location / {
        proxy_pass http://backend;
    }
}
EOF
  sudo mv "$TMP_CONF" "$NGINX_CONF"
  if sudo nginx -t; then
    sudo systemctl reload nginx
    echo "Nginx reloaded successfully."
  else
    echo "Nginx config error! Reload failed."
  fi
}

# --- Main Loop ---
echo "🚀 Starting VM monitoring and scaling script (with auto-cleanup)..."
echo "Press Ctrl+C to stop and clean up all created VMs."
while true; do
  FIRST_VM=$(sudo virsh list --name --state-running | grep "$PRIMARY_VM_PATTERN" | head -n 1)
  if [ -z "$FIRST_VM" ]; then
    echo "No running service VMs found to monitor. Waiting..."
    sleep 15
    continue
  fi
  echo "--- $(date) ---"
  echo "Monitoring primary VM: $FIRST_VM"
  get_cpu_nanoseconds() {
    sudo virsh domstats "$1" --cpu-total | awk -F'=' '/cpu.time/ {print $2}'
  }
  cpu_time_start=$(get_cpu_nanoseconds "$FIRST_VM")
  sleep 5
  cpu_time_end=$(get_cpu_nanoseconds "$FIRST_VM")
  if [ -z "$cpu_time_start" ]; then
    echo "Could not get CPU stats for $FIRST_VM."
    sleep 10
    continue
  fi
  cpu_usage=$(echo "($cpu_time_end - $cpu_time_start) / 50000000" | bc)
  echo "Current CPU usage for $FIRST_VM: $cpu_usage%"
  if [ "$cpu_usage" -gt "$CPU_THRESHOLD" ]; then
    echo "High load detected!"
    total_vms=$(sudo virsh list --all --name | grep -c "$PRIMARY_VM_PATTERN")
    if [ "$total_vms" -lt "$MAX_VMS" ]; then
      NEW_VM_NAME="${PRIMARY_VM_PATTERN}-$(date +%s)"
      echo "Scaling up... Creating new VM: $NEW_VM_NAME from template $TEMPLATE_VM"
      sudo virt-clone --original "$TEMPLATE_VM" --name "$NEW_VM_NAME" --auto-clone
      sudo virsh start "$NEW_VM_NAME"
      echo "Waiting for new VM to boot..."
      sleep 20
      update_nginx_config
    else
      echo "Max VM limit of $MAX_VMS reached. Cannot scale further."
    fi
  fi
  sleep 10
done
