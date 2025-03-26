#!/bin/bash

# Variables
SCRIPT_NAME=$(basename "$0")
DB_PATH="/var/lib/$SCRIPT_NAME"

# Error codes
ERR_UNKNOWN_COMMAND=10
ERR_INTERFACE_NAME_REQUIRED=11
ERR_INTERFACE_NOT_EXIST=12
ERR_JQ_PROCESSING=13
ERR_FILE_NOT_FOUND=14
ERR_INVALID_TIMESTAMP=15
ERR_INVALID_BYTES=16
ERR_REMOVE_FAILED=17
ERR_ROOT_PRIVILEGE_REQUIRED=18
ERR_FILE_WRITE_FAILED=19
ERR_NO_INTERFACES_FOUND=20

# Function to calculate time difference
time_diff() {
  local ts=$1 now diff n r c=0
  [[ -z "$ts" ]] || [[ ! "$ts" =~ ^[0-9]+$ ]] && return ${ERR_INVALID_TIMESTAMP:-1}
  
  now=$(date +%s)
  diff=$((now - ts))
  ((diff == 0)) && echo "Just now" && return 0
  
  # Hardcoded values to avoid array lookups and string splitting
  n=$((diff / 2592000))
  if ((n > 0)); then
    r="$n month"
    ((n > 1)) && r+="s"
    diff=$((diff % 2592000))
    c=1
  fi
  
  n=$((diff / 86400))
  if ((n > 0 && c < 2)); then
    [[ -n "$r" ]] && r+=", "
    r+="$n day"
    ((n > 1)) && r+="s"
    diff=$((diff % 86400))
    ((c++))
  fi
  
  n=$((diff / 3600))
  if ((n > 0 && c < 2)); then
    [[ -n "$r" ]] && r+=", "
    r+="$n hour"
    ((n > 1)) && r+="s"
    diff=$((diff % 3600))
    ((c++))
  fi
  
  n=$((diff / 60))
  if ((n > 0 && c < 2)); then
    [[ -n "$r" ]] && r+=", "
    r+="$n minute"
    ((n > 1)) && r+="s"
    diff=$((diff % 60))
    ((c++))
  fi
  
  if ((diff > 0 && c < 2)); then
    [[ -n "$r" ]] && r+=", "
    r+="$diff second"
    ((diff > 1)) && r+="s"
  fi
  
  echo "$r ago"
  return 0
}

format_iec() {
  local b=$1
  [[ -z "$b" || "$b" =~ [^0-9] ]] && return ${ERR_INVALID_BYTES:-1}
  
  # Special case for bytes
  if ((b < 1024)); then
    echo "$b B"
    return 0
  fi
  
  # Direct calculation without arrays or loops
  if ((b < 1048576)); then  # Under MiB
    echo "$(awk "BEGIN {printf \"%.2f\", $b / 1024}") KiB"
  elif ((b < 1073741824)); then  # Under GiB
    echo "$(awk "BEGIN {printf \"%.2f\", $b / 1048576}") MiB"
  elif ((b < 1099511627776)); then  # Under TiB
    echo "$(awk "BEGIN {printf \"%.2f\", $b / 1073741824}") GiB"
  else  # TiB or larger
    echo "$(awk "BEGIN {printf \"%.2f\", $b / 1099511627776}") TiB"
  fi
  
  return 0
}

# Function to update WireGuard interface
update_interface() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED
  
  # Get WireGuard information in one call
  local wg_dump
  wg_dump=$(wg show "$interface_name" dump 2>&1) || return $ERR_INTERFACE_NOT_EXIST
 
  # Load or create JSON data
  local json_data
  local file_path="$DB_PATH/$interface_name.json"
  if [[ -f "$file_path" && -s "$file_path" ]]; then
    json_data=$(<"$file_path")
  else
    json_data='{"interface": {}, "peers": {}}'
  fi
  
  # Get current timestamp
  local ts_now=$(date +%s)
  
  # Process interface info
  local interface_public_key interface_listen_port
  read -r _ interface_public_key interface_listen_port _ <<< "$(head -n 1 <<< "$wg_dump")"
  
  # Update interface data
  json_data=$(jq --arg name "$interface_name" \
                 --arg pub_key "$interface_public_key" \
                 --arg listen_port "$interface_listen_port" \
                 --arg ts_now "$ts_now" \
                 '.interface.name=$name | .interface.public_key=$pub_key | .interface.listen_port=$listen_port |
                  (.interface.create_at //= $ts_now) | .interface.update_at=$ts_now' <<< "$json_data") || return $ERR_JQ_PROCESSING
  
  # Get peer data (line count > 1 means peers exist)
  local peer_data
  peer_data=$(tail -n +2 <<< "$wg_dump")
  [[ -z "$peer_data" ]] && { echo "$json_data" > "$file_path" || return $ERR_FILE_WRITE_FAILED; return 0; }
  
  # Process each peer
  local peer_public_key peer_endpoint peer_allowed_ips peer_latest_handshake peer_transfer_rx peer_transfer_tx peer_persistent_keepalive
  local total_rx total_tx prev_transfer_rx prev_transfer_tx
  while IFS=$'\t' read -r peer_public_key _ peer_endpoint peer_allowed_ips peer_latest_handshake peer_transfer_rx peer_transfer_tx peer_persistent_keepalive; do
    # Skip peers with no latest handshake
    #[[ -z "$peer_latest_handshake" || "$peer_latest_handshake" == "0" ]] && continue
    
    # Set default values for a new peer
    json_data=$(jq --arg key "$peer_public_key" \
                   '.peers[$key] //= {
                     "allowed_ips": "",
                     "transfer_rx": 0,
                     "transfer_tx": 0,
                     "total_rx": 0,
                     "total_tx": 0,
                     "persistent_keepalive": "off",
                     "endpoint": "(none)",
                     "latest_handshake": 0
                   }' <<< "$json_data") || return $ERR_JQ_PROCESSING
    
    # Get existing values
    read -r total_rx total_tx prev_transfer_rx prev_transfer_tx < <(jq -r "
      .peers[\"$peer_public_key\"] | \"\(.total_rx) \(.total_tx) \(.transfer_rx) \(.transfer_tx)\"
    " <<< "$json_data")
    
    # Update totals
    if [[ "$peer_transfer_rx" -lt "$prev_transfer_rx" || "$peer_transfer_tx" -lt "$prev_transfer_tx" ]]; then
      # Counter reset, add new values
      total_rx=$((total_rx + peer_transfer_rx))
      total_tx=$((total_tx + peer_transfer_tx))
    else
      # Add difference
      total_rx=$((total_rx + peer_transfer_rx - prev_transfer_rx))
      total_tx=$((total_tx + peer_transfer_tx - prev_transfer_tx))
    fi
    
    # Update peer data - using correct structure with parentheses for conditionals
    json_data=$(jq --arg peer "$peer_public_key" \
                   --arg allowed_ips "$peer_allowed_ips" \
                   --argjson transfer_rx "$peer_transfer_rx" \
                   --argjson transfer_tx "$peer_transfer_tx" \
                   --argjson total_rx "$total_rx" \
                   --argjson total_tx "$total_tx" \
                   --arg persistent_keepalive "$peer_persistent_keepalive" \
                   --arg endpoint "$peer_endpoint" \
                   --argjson latest_handshake "$peer_latest_handshake" \
                   '(.peers[$peer].allowed_ips=$allowed_ips |
                     .peers[$peer].transfer_rx=$transfer_rx |
                     .peers[$peer].transfer_tx=$transfer_tx |
                     .peers[$peer].total_rx=$total_rx |
                     .peers[$peer].total_tx=$total_tx |
                     .peers[$peer].persistent_keepalive=$persistent_keepalive) |
                    (if $latest_handshake != 0 then .peers[$peer].latest_handshake = $latest_handshake else . end) |
                    (if $endpoint != "(none)" then .peers[$peer].endpoint = $endpoint else . end)' <<< "$json_data") || return $ERR_JQ_PROCESSING
  done <<< "$peer_data"
  
  # Write updated data
  echo "$json_data" > "$file_path" || return $ERR_FILE_WRITE_FAILED
  return 0
}

show_interface() {
  local interface_name="$1"
  local format="${2:-plain}"  # Default to plain if no format specified
  
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED

  local file_path="$DB_PATH/$interface_name.json"
  [[ -f "$file_path" ]] || return $ERR_FILE_NOT_FOUND
  
  local json_data=$(<"$file_path")

  local name public_key listen_port create_at update_at peers
  read -r name public_key listen_port create_at update_at peers < <(jq -r '
    (.interface | "\(.name) \(.public_key) \(.listen_port) \(.create_at) \(.update_at) ") + 
    (.peers | to_entries | 
    [(. | map(select(.value.latest_handshake > 0))) | sort_by(.value.latest_handshake) | reverse | [.[].key]] + 
    # Then add peers with latest_handshake == 0 
    [(. | map(select(.value.latest_handshake == 0)) | [.[].key])] | 
    flatten | join(" ")) ' <<< "$json_data")
  
  # Initialize variables
  local total_interface_rx=0
  local total_interface_tx=0

  if [[ "$format" == "json" ]]; then
    # Generate initial JSON object for output
    local output_json=$(jq -n --arg name "$name" --arg public_key "$public_key" --arg listen_port "$listen_port" \
      --arg create_at "$(time_diff "$create_at")" --arg update_at "$(time_diff "$update_at")" '
      {
        "interface": {
          "name": $name,
          "public_key": $public_key,
          "listen_port": $listen_port,
          "create_at": $create_at,
          "update_at": $update_at
        },
        "peers": {}
      }')
    
    # Process peer data and calculate totals in the same loop
    for peer in $peers; do
      local endpoint allowed_ips latest_handshake total_rx total_tx
      read -r endpoint allowed_ips latest_handshake total_rx total_tx < <(
        jq -r ".peers[\"$peer\"] | \"\(.endpoint) \(.allowed_ips) \(.latest_handshake) \(.total_rx) \(.total_tx)\"" <<< "$json_data"
      )
      
      # Update interface totals
      total_interface_rx=$((total_interface_rx + total_rx))
      total_interface_tx=$((total_interface_tx + total_tx))
      
      # Append peer data to the output JSON object
      output_json=$(jq --arg peer "$peer" \
                       --arg allowed_ips "$allowed_ips" \
                       --arg endpoint "$endpoint" \
                       --arg handshake "$([ $latest_handshake -gt 0 ] && time_diff "$latest_handshake" || echo "")" \
                       --arg rx "$([ $total_rx -gt 0 ] && format_iec "$total_rx" || echo "")" \
                       --arg tx "$([ $total_tx -gt 0 ] && format_iec "$total_tx" || echo "")" '
                       .peers[$peer] = (
                         {
                           "allowed_ips": $allowed_ips,
                           "endpoint": $endpoint,
                           "latest_handshake": $handshake,
                           "total_rx": $rx,
                           "total_tx": $tx
                         } | with_entries(
                             select(
                               .value != null and
                               .value != "" and
                               .value != "(none)"
                             )
                           )
                       )' <<< "$output_json")
    done
    
    # Add interface totals after processing all peers
    output_json=$(jq --arg total_rx "$(format_iec $total_interface_rx)" \
                     --arg total_tx "$(format_iec $total_interface_tx)" '
                     .interface.total_rx = $total_rx | 
                     .interface.total_tx = $total_tx' <<< "$output_json")
      
    jq -r '.' <<< "$output_json"
  
  else  # Handle both plain and colorized formats
    # Define color codes based on format
    local c_intf_label=""
    local c_intf_value=""
    local c_label=""
    local c_value=""
    local c_peer_label=""
    local c_peer_value=""
    local c_reset=""
    
    if [[ "$format" == "colorized" ]]; then
      c_intf_label="\e[1;32m"
      c_intf_value="\e[32m"
      c_label="\e[1;37m"
      c_value="\e[37m"
      c_peer_label="\e[1;33m"
      c_peer_value="\e[33m"
      c_reset="\e[0m"
    fi

    # Prepare initial interface output - first part (before transfer line)
    local interface_output=""
    interface_output+="${c_intf_label}interface:${c_reset} ${c_intf_value}$name${c_reset}\n"
    interface_output+="  ${c_label}public key:${c_reset} ${c_value}$public_key${c_reset}\n"
    interface_output+="  ${c_label}listening port:${c_reset} ${c_value}$listen_port${c_reset}\n"
    interface_output+="  ${c_label}recorded since:${c_reset} ${c_value}$(time_diff $create_at)${c_reset}\n"
    interface_output+="  ${c_label}last updated:${c_reset} ${c_value}$(time_diff $update_at)${c_reset}"

    # Process peer data and calculate totals
    local peers_output=""
    for peer in $peers; do
      local endpoint allowed_ips latest_handshake total_rx total_tx
      read -r endpoint allowed_ips latest_handshake total_rx total_tx < <(
        jq -r ".peers[\"$peer\"] | \"\(.endpoint) \(.allowed_ips) \(.latest_handshake) \(.total_rx) \(.total_tx)\"" <<< "$json_data"
      )

      # Update interface totals
      total_interface_rx=$((total_interface_rx + total_rx))
      total_interface_tx=$((total_interface_tx + total_tx))

      # Add peer data to output
      peers_output+="\n\n${c_peer_label}peer:${c_reset} ${c_peer_value}$peer${c_reset}"
      [[ "$endpoint" != "(none)" ]] && peers_output+="\n  ${c_label}endpoint:${c_reset} ${c_value}$endpoint${c_reset}"
      peers_output+="\n  ${c_label}allowed ips:${c_reset} ${c_value}$allowed_ips${c_reset}"
      [[ "$latest_handshake" -ne 0 ]] && peers_output+="\n  ${c_label}latest handshake:${c_reset} ${c_value}$(time_diff $latest_handshake)${c_reset}"
      [[ $total_rx -ne 0 || $total_tx -ne 0 ]] && peers_output+="\n  ${c_label}transfer:${c_reset} ${c_value}$(format_iec $total_rx) received, $(format_iec $total_tx) sent${c_reset}"
    done

    # Create transfer line with final totals
    local transfer_line="\n  ${c_label}transfer:${c_reset} ${c_value}$(format_iec $total_interface_rx) received, $(format_iec $total_interface_tx) sent${c_reset}"
    
    echo -e "${interface_output}${transfer_line}${peers_output}"
  fi

  return 0
}

# Function to remove a WireGuard interface from the database
flush_interface() {
  local interface_name="$1"
  [[ -z "$interface_name" ]] && return $ERR_INTERFACE_NAME_REQUIRED

  local file_path="$DB_PATH/$interface_name.json"
  [[ ! -f "$file_path" ]] && return $ERR_FILE_NOT_FOUND

  rm "$file_path" || return $ERR_REMOVE_FAILED
  return 0
}

show_help() {
  cat <<EOF
Usage: $SCRIPT_NAME <cmd> [<args>]

Commands:
  show [<interface> | interfaces]  Show details of a specific WireGuard interface or list all interfaces.
                                     If 'interfaces' is provided, a list of all available interfaces will be displayed.
                                     If a specific interface name is provided, details of that interface will be shown.
                                     If no interface name is provided, details of all active interfaces will be shown.
  update [<interface>]             Update the configuration of a specific WireGuard interface.
                                     If a specific interface name is provided, that interface will be updated.
                                     If no interface name is provided, all active interfaces will be updated.
  flush <interface>                Remove the specified WireGuard interface from the database.
                                     The interface name is required for this command.
  help                             Show this help message with usage instructions.
EOF
}

handle_error() {
  local error_code=$1
  case $error_code in
    $ERR_UNKNOWN_COMMAND) ;; # echo "Error: Unknown command provided." >&2 
    $ERR_INTERFACE_NAME_REQUIRED) echo "Error: Interface name is required." >&2 ;;
    $ERR_INTERFACE_NOT_EXIST) echo "Error: Interface does not exist." >&2 ;;
    $ERR_JQ_PROCESSING) echo "Error: Failed to process JSON data with jq." >&2 ;;
    $ERR_FILE_NOT_FOUND) echo "Error: Interface does not exist." >&2 ;;
    $ERR_INVALID_TIMESTAMP) echo "Error: Invalid timestamp provided." >&2 ;;
    $ERR_INVALID_BYTES) echo "Error: Invalid byte value provided." >&2 ;;
    $ERR_REMOVE_FAILED) echo "Error: Failed to remove interface from database." >&2 ;;
    $ERR_ROOT_PRIVILEGE_REQUIRED) echo "Error: Root privileges are required." >&2 ;;
    $ERR_FILE_WRITE_FAILED) echo "Error: Failed to write to the file." >&2 ;;
    $ERR_NO_INTERFACES_FOUND) ;; # echo "Error: No WireGuard interfaces found." >&2
    *) echo "Error: An unknown error occurred." >&2 ;;
  esac
  exit $error_code
}

main() {
  local cmd="${1:-show}"
  local interface_name="${2:-all}"

  case "$cmd" in
    show)
      # Check user asked output with selected format(colorized, json), Default is colorized if supported
      local print_format=""
      [[ -t 1 ]] && print_format="colorized"
      if [ -n "$3" ]; then
        print_format="$3"
      fi
      
      if [[ $interface_name == "interfaces" ]]; then
        # Enable nullglob to ensure the pattern expands to nothing if no files match
        shopt -s nullglob
        interfaces=$(for file in "$DB_PATH"/*.json; do basename "$file" .json; done | tr '\n' ' ')
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        echo "$interfaces"
      elif [[ $interface_name == "all" ]]; then
        # Enable nullglob to ensure the pattern expands to nothing if no files match
        shopt -s nullglob
        interfaces=$(for file in "$DB_PATH"/*.json; do basename "$file" .json; done | tr '\n' ' ')
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        
        if [[ $print_format == "json" ]]; then
          # Initialize an empty array to hold all interface JSONs
          local combined_json='{"interfaces": []}'
          local interface_json=""
          # Process each interface and append its JSON to the array
          for iface in $interfaces; do
            interface_json=$(show_interface "$iface" "json") || handle_error $?
            if [[ -n "$interface_json" ]]; then
              # Append the interface JSON to our array
              combined_json=$(jq --argjson interface "$interface_json" '.interfaces += [$interface]' <<< "$combined_json")
            fi
          done
          # Output the final JSON
          jq -r '.' <<< "$combined_json"
        else
          # For both plain and colorized formats, process interfaces one by one
          local first=true
          for iface in $interfaces; do
            $first && first=false || echo "" # Adds a blank line before every interface except the first one
            show_interface "$iface" "$print_format"
            [ $? -eq 0 ] || handle_error $?
          done
        fi
      else
        # Show details for a single interface with the specified format
        show_interface "$interface_name" "$print_format" || handle_error $?
      fi
      ;;
    update)
      [ "$EUID" -eq 0 ] || handle_error $ERR_ROOT_PRIVILEGE_REQUIRED
      if [ "$interface_name" == "all" ]; then
        interfaces=$(wg show interfaces 2>/dev/null)
        [[ -z $interfaces ]] && handle_error $ERR_NO_INTERFACES_FOUND
        for iface in $interfaces; do
          { update_interface "$iface" && echo "Interface $iface updated at $(date '+%Y-%m-%d %H:%M:%S')" || handle_error $?; } # &
        done
        # Optionally, wait for all background jobs to finish.
        # wait
      else
        update_interface "$interface_name" && echo "Interface $interface_name updated at $(date '+%Y-%m-%d %H:%M:%S')" || handle_error $?
      fi
      ;;
      
    flush)
      [ "$EUID" -eq 0 ] || handle_error $ERR_ROOT_PRIVILEGE_REQUIRED
      [[ -z "$interface_name" || "$interface_name" == "all" ]] && handle_error $ERR_INTERFACE_NAME_REQUIRED
      flush_interface "$interface_name" && echo "Interface $interface_name flushed at $(date '+%Y-%m-%d %H:%M:%S')" || handle_error $?
      ;;
      
    help)
      show_help
      ;;
      
    *)
      echo "Usage: $SCRIPT_NAME <cmd> [<args>]"
      echo "For more information on available commands, use '$SCRIPT_NAME help'."
      handle_error $ERR_UNKNOWN_COMMAND
      ;;
  esac

  return 0
}

main "$@"
exit 0