#!/bin/bash

# Constants
SCRIPT_NAME="wgstat"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
DB_PATH="/var/lib/$SCRIPT_NAME"
SCRIPT_URL="https://raw.githubusercontent.com/snaeim/$SCRIPT_NAME/refs/heads/main/$SCRIPT_NAME.sh"
SYSTEMD_SERVICE="/etc/systemd/system/${SCRIPT_NAME}.service"
SYSTEMD_TIMER="/etc/systemd/system/${SCRIPT_NAME}.timer"

# Function to check if the script is being run with sudo
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run with sudo."
        exit 1
    fi
}

# Function to display a confirmation prompt
confirm() {
    local prompt="$1"
    while true; do
        read -p "$prompt (Y/n): " choice
        case "$choice" in
        [Yy] | "") return 0 ;; # Accept empty input as "yes"
        [Nn]) return 1 ;;
        *) echo "Invalid input. Please enter y, n, or press Enter for yes." ;;
        esac
    done
}

# Function to install the script and systemd timer/service
install_script() {
    # Download the script from the URL
    if ! curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"; then
        echo "Error: Failed to download the script."
        exit 1
    fi
    echo "$SCRIPT_NAME script downloaded to $SCRIPT_PATH."

    # Set the script as executable
    chmod +x "$SCRIPT_PATH"
    echo "Set execute permission for $SCRIPT_PATH."

    # Create necessary directories for the database
    if [ ! -d "$DB_PATH" ]; then
        mkdir -p "$DB_PATH"
        echo "Created database directory: $DB_PATH."
        chmod 755 "$DB_PATH"
        echo "Set permissions on $DB_PATH to drwxr-xr-x."
    else
        echo "Directory already exists: $DB_PATH."
    fi

    # Ask for systemd timer interval in seconds (between 10 and 600)
    local interval_sec
    while true; do
        read -p "Enter the interval to update stats (30-300 seconds, default: 60): " interval
        interval=${interval:-60} # Default to 60s if empty
        if [[ "$interval" =~ ^[0-9]+$ ]] && ((interval >= 30 && interval <= 300)); then
            break
        else
            echo "Invalid input. Interval must be between 30 and 300 seconds."
        fi
    done

    # Create the systemd service unit file inline with logging to journal
    cat <<EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=$SCRIPT_NAME Service

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH update all
StandardOutput=journal
StandardError=journal
EOF

    # Create the systemd timer unit file inline with AccuracySec set to 1 second
    cat <<EOF > "$SYSTEMD_TIMER"
[Unit]
Description=$SCRIPT_NAME Timer

[Timer]
OnUnitActiveSec=${interval}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    # Reload systemd, enable and start the timer
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now "${SCRIPT_NAME}.timer" >/dev/null 2>&1
    systemctl start "${SCRIPT_NAME}.service" >/dev/null 2>&1
    echo "$SCRIPT_NAME installed successfully and will run every ${interval} seconds!"

    # Optionally, source the downloaded script to finalize installation if needed
    # source "$SCRIPT_PATH" >/dev/null || echo "Something went wrong!"
}

# Function to uninstall the script and systemd timer/service
uninstall_script() {
    # Remove script from /usr/local/bin
    if [ -f "$SCRIPT_PATH" ]; then
        rm "$SCRIPT_PATH"
        echo "Removed script from $SCRIPT_PATH."
    else
        echo "Script not found at $SCRIPT_PATH."
    fi

    # Stop and disable the timer if enabled
    if systemctl is-enabled "${SCRIPT_NAME}.timer" &>/dev/null; then
        systemctl stop "${SCRIPT_NAME}.timer" >/dev/null 2>&1
        systemctl disable "${SCRIPT_NAME}.timer" >/dev/null 2>&1
    fi

    # Remove the systemd unit files if they exist
    [ -f "$SYSTEMD_SERVICE" ] && rm -f "$SYSTEMD_SERVICE" && echo "Removed systemd service: $SYSTEMD_SERVICE."
    [ -f "$SYSTEMD_TIMER" ] && rm -f "$SYSTEMD_TIMER" && echo "Removed systemd timer: $SYSTEMD_TIMER."

    systemctl daemon-reload

    # Ask if the user wants to keep the database path
    if confirm "Do you want to keep the database path ($DB_PATH)?"; then
        echo "Database directory kept: $DB_PATH."
    else
        rm -rf "$DB_PATH"
        echo "Removed database directory: $DB_PATH."
    fi

    echo "$SCRIPT_NAME uninstalled."
}

# Main script logic to check if already installed
check_root

if [ -f "$SCRIPT_PATH" ]; then
    echo "$SCRIPT_NAME is already installed."
    if confirm "Do you want to uninstall the script?"; then
        uninstall_script
    fi
else
    echo "$SCRIPT_NAME is not installed."
    if confirm "Do you want to install the script?"; then
        install_script
    fi
fi
