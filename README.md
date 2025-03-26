# wgstat - WireGuard Traffic Statistics Persistence

## Introduction
`wgstat` is a bash script designed to persist WireGuard traffic statistics across interface resets. WireGuard's built-in traffic counters are stored in memory and are reset whenever an interface is brought down or the system is rebooted. This tool captures and stores cumulative traffic data, ensuring that historical usage statistics are preserved.

## Features
- Persist WireGuard traffic statistics even after an interface reset
- Track total data received and transmitted per peer
- Display WireGuard interface and peer details in multiple formats (plain, colorized, JSON)
- Automatically update traffic statistics
- Option to remove WireGuard interfaces from the database

## Requirements
- Linux-based OS (Debian, Ubuntu, CentOS, or similar)
- Root (administrator) privileges to install and update
- `curl` or `wget` to download the scripts
- `jq` to process JSON data

## Installation
To install `wgstat`, run the following command:
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/snaeim/wgstat/refs/heads/main/installer.sh)"
```
This command will:
1. Download and install the main wgstat script to `/usr/local/bin/`
2. Set up a systemd timer to automatically update WireGuard traffic statistics at specified intervals
3. Create the necessary database directory at `/var/lib/wgstat`

## Usage

### Show Interface Data
Display the statistics for a specific WireGuard interface:
```bash
wgstat show <interface> [format]
```

Example:
```bash
wgstat show wg0
wgstat show wg0 json
```

### View All Interfaces
To view all interfaces:
```bash
wgstat show
```
or with a specific format:
```bash
wgstat show all [format]
```

Example:
```bash
wgstat show all json
```

### List Available Interfaces
To get a list of all available interfaces:
```bash
wgstat show interfaces
```

### Output Formats
You can specify the output format as an additional parameter after the interface name:
- `plain`: Plain text format
- `colorized`: Text with ANSI color codes (default when output is to a terminal)
- `json`: JSON-formatted output for programmatic use

Examples:
```bash
wgstat show wg0 json
wgstat show all json
wgstat show wg0 plain
```

### Update Interface Data
To manually update the statistics for a specific interface:
```bash
wgstat update <interface>
```

Example:
```bash
wgstat update wg0
```

To update all interfaces:
```bash
wgstat update
```
or
```bash
wgstat update all
```

### Flush Interface Data
To remove a specific WireGuard interface from the database:
```bash
wgstat flush <interface>
```

Example:
```bash
wgstat flush wg0
```

## Uninstall
To uninstall wgstat, run the following command:
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/snaeim/wgstat/refs/heads/main/installer.sh)"
```
This command will:
1. Remove the main wgstat script
2. Remove the systemd timer that was set up during installation
3. Prompt you to delete the database directory located at `/var/lib/wgstat`