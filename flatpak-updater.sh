#!/usr/bin/env bash

set -euo pipefail

exec 2>&1

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOSTNAME="${FLATPAK_HOSTNAME:-$(hostname -f)}"
readonly TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?Error: TELEGRAM_BOT_TOKEN environment variable is required}"
readonly TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?Error: TELEGRAM_CHAT_ID environment variable is required}"
readonly TELEGRAM_API_HOST="${TELEGRAM_API_HOST:-api.telegram.org}"
readonly TELEGRAM_API_ENDPOINT="https://${TELEGRAM_API_HOST}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"
readonly PROGRESS_INTERVAL=10

declare -a UPDATED_PACKAGES=()
declare -a FAILED_PACKAGES=()
declare -a AVAILABLE_UPDATES=()

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        ERROR)
            echo "[$timestamp] [ERROR] $message" >&2
            ;;
        WARN)
            [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO|WARN)$ ]] && echo "[$timestamp] [WARN] $message" >&2
            ;;
        INFO)
            [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO)$ ]] && echo "[$timestamp] [INFO] $message"
            ;;
        DEBUG)
            [[ "$LOG_LEVEL" == "DEBUG" ]] && echo "[$timestamp] [DEBUG] $message"
            ;;
    esac
}

send_telegram_message() {
    local message="$1"
    local url="${TELEGRAM_API_ENDPOINT}/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local response
    local http_code
    
    log DEBUG "Sending Telegram message to chat ID: $TELEGRAM_CHAT_ID"
    
    response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${message}\", \"parse_mode\": \"HTML\"}" \
        2>/dev/null) || {
        log ERROR "Failed to send Telegram message: curl command failed"
        return 1
    }
    
    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)
    
    if [[ "$http_code" -ne 200 ]]; then
        log ERROR "Failed to send Telegram message. HTTP code: $http_code, Response: $body"
        return 1
    fi
    
    log DEBUG "Telegram message sent successfully"
    return 0
}

check_dependencies() {
    local deps=("flatpak" "curl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log ERROR "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    log INFO "All dependencies are installed"
}

get_available_updates() {
    log INFO "Checking for Flatpak updates..."
    
    local temp_file
    temp_file=$(mktemp)
    
    log INFO "Running flatpak update check (this may take a moment)..."
    
    local update_output
    if ! update_output=$(echo "n" | timeout 30 flatpak update 2>&1); then
        local exit_code=$?
        log WARN "Flatpak update command exited with code: $exit_code"
    else
        local exit_code=0
    fi
    
    log DEBUG "Flatpak update check exit code: $exit_code"
    
    echo "$update_output" > "$temp_file"
    
    log DEBUG "Full update output saved to: $temp_file"
    log INFO "Parsing update output..."
    
    if echo "$update_output" | grep -q "Nothing to do"; then
        log INFO "No updates available"
        rm -f "$temp_file"
        return 0
    fi
    
    while IFS= read -r line; do
        log DEBUG "Processing line: $line"
        
        if echo "$line" | grep -q "Proceed with these changes"; then
            log DEBUG "Reached prompt, stopping parse"
            break
        fi
        
        if [[ "$line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+([-a-zA-Z0-9._]+)[[:space:]]+([-a-zA-Z0-9._]+)[[:space:]]+u[[:space:]]+ ]]; then
            local app_id="${BASH_REMATCH[1]}"
            log DEBUG "Found potential update: $app_id"
            if [[ -n "$app_id" ]]; then
                AVAILABLE_UPDATES+=("$app_id")
                log INFO "Update available for: $app_id"
            fi
        fi
    done < "$temp_file"
    
    if [[ ${#AVAILABLE_UPDATES[@]} -eq 0 ]] && [[ -s "$temp_file" ]]; then
        log WARN "No updates parsed but output exists. Check $temp_file for details"
    else
        rm -f "$temp_file"
    fi
    
    log INFO "Found ${#AVAILABLE_UPDATES[@]} update(s) available"
    return 0
}

monitor_update_progress() {
    local pid="$1"
    local package="$2"
    local start_time
    start_time=$(date +%s)
    local last_progress_time=$start_time
    local last_rx_bytes=0
    local interface
    interface=$(ip route | grep '^default' | head -1 | awk '{print $5}')
    
    while kill -0 "$pid" 2>/dev/null; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $((current_time - last_progress_time)) -ge $PROGRESS_INTERVAL ]]; then
            local rate="N/A"
            
            if [[ -n "$interface" && -f "/sys/class/net/$interface/statistics/rx_bytes" ]]; then
                local current_rx_bytes
                current_rx_bytes=$(cat "/sys/class/net/$interface/statistics/rx_bytes" 2>/dev/null || echo "0")
                
                if [[ "$last_rx_bytes" -gt 0 ]]; then
                    local bytes_diff=$((current_rx_bytes - last_rx_bytes))
                    local time_diff=$((current_time - last_progress_time))
                    if [[ "$time_diff" -gt 0 && "$bytes_diff" -gt 0 ]]; then
                        local bytes_per_sec=$((bytes_diff / time_diff))
                        rate=$(numfmt --to=iec-i --suffix=B/s "$bytes_per_sec" 2>/dev/null || echo "N/A")
                    fi
                fi
                
                last_rx_bytes=$current_rx_bytes
            fi
            
            log INFO "Updating $package... (elapsed: ${elapsed}s, rate: $rate)"
            last_progress_time=$current_time
        fi
        
        sleep 1
    done
}

update_package() {
    local package="$1"
    local log_file
    log_file=$(mktemp "/tmp/flatpak-update-${package//\//_}-XXXXXX.log")
    
    log INFO "Starting update for: $package"
    
    (
        flatpak update -y "$package" 2>&1 | while IFS= read -r line; do
            echo "$line" >> "$log_file"
            
            if echo "$line" | grep -qE "(downloading|Installing|Updating|[0-9]+%|[0-9]+\.[0-9]+ [kMG]B|Receiving)"; then
                log INFO "$package: $line"
            fi
        done
        echo $? > "${log_file}.exitcode"
    ) &
    
    local update_pid=$!
    
    local start_time
    start_time=$(date +%s)
    local last_report_time=$start_time
    
    while kill -0 "$update_pid" 2>/dev/null; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $((current_time - last_report_time)) -ge $PROGRESS_INTERVAL ]]; then
            log INFO "Updating $package... (elapsed: ${elapsed}s)"
            last_report_time=$current_time
        fi
        
        sleep 2
    done
    
    wait "$update_pid"
    
    local exit_code=1
    if [[ -f "${log_file}.exitcode" ]]; then
        exit_code=$(cat "${log_file}.exitcode")
        rm -f "${log_file}.exitcode"
    fi
    
    if [[ "$exit_code" -eq 0 ]]; then
        UPDATED_PACKAGES+=("$package")
        log INFO "Successfully updated: $package"
        rm -f "$log_file"
        return 0
    else
        FAILED_PACKAGES+=("$package")
        log ERROR "Failed to update: $package (exit code: $exit_code)"
        
        if [[ -f "$log_file" ]]; then
            log DEBUG "Error details: $(tail -n 3 "$log_file")"
        fi
        return 1
    fi
}

perform_updates() {
    if [[ ${#AVAILABLE_UPDATES[@]} -eq 0 ]]; then
        log INFO "No packages to update"
        return 0
    fi
    
    log INFO "Starting update process for ${#AVAILABLE_UPDATES[@]} package(s)"
    
    for package in "${AVAILABLE_UPDATES[@]}"; do
        update_package "$package" || true
    done
    
    log INFO "Update process completed"
    log INFO "Successfully updated: ${#UPDATED_PACKAGES[@]} package(s)"
    log INFO "Failed to update: ${#FAILED_PACKAGES[@]} package(s)"
}

format_telegram_message() {
    local message="<b>🖥️ Flatpak Update Report</b>\n"
    message+="<b>Host:</b> <code>${HOSTNAME}</code>\n"
    message+="<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    
    if [[ ${#AVAILABLE_UPDATES[@]} -eq 0 ]]; then
        message+="✅ <b>Status:</b> No updates available\n"
    else
        message+="📦 <b>Total Updates:</b> ${#AVAILABLE_UPDATES[@]}\n"
        
        if [[ ${#UPDATED_PACKAGES[@]} -gt 0 ]]; then
            message+="\n✅ <b>Successfully Updated (${#UPDATED_PACKAGES[@]}):</b>\n"
            for pkg in "${UPDATED_PACKAGES[@]}"; do
                message+="  • <code>$pkg</code>\n"
            done
        fi
        
        if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
            message+="\n❌ <b>Failed Updates (${#FAILED_PACKAGES[@]}):</b>\n"
            for pkg in "${FAILED_PACKAGES[@]}"; do
                message+="  • <code>$pkg</code>\n"
            done
        fi
        
        local success_rate=0
        if [[ ${#AVAILABLE_UPDATES[@]} -gt 0 ]]; then
            success_rate=$(( (${#UPDATED_PACKAGES[@]} * 100) / ${#AVAILABLE_UPDATES[@]} ))
        fi
        message+="\n📊 <b>Success Rate:</b> ${success_rate}%"
    fi
    
    echo "$message"
}

cleanup() {
    local exit_code=$?
    log DEBUG "Cleaning up temporary files..."
    rm -f /tmp/flatpak-update-*.log 2>/dev/null || true
    exit "$exit_code"
}

main() {
    trap cleanup EXIT INT TERM
    
    log INFO "Starting Flatpak updater on host: $HOSTNAME"
    log INFO "Telegram API host: $TELEGRAM_API_HOST"
    
    log INFO "Checking dependencies..."
    check_dependencies
    
    log INFO "Starting update check..."
    if ! get_available_updates; then
        log ERROR "get_available_updates function failed"
        local error_msg="<b>⚠️ Flatpak Update Error</b>\n"
        error_msg+="<b>Host:</b> <code>${HOSTNAME}</code>\n"
        error_msg+="<b>Error:</b> Failed to check for updates\n"
        error_msg+="<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')"
        
        send_telegram_message "$error_msg"
        exit 1
    fi
    
    perform_updates
    
    local telegram_message
    telegram_message=$(format_telegram_message)
    
    if ! send_telegram_message "$telegram_message"; then
        log ERROR "Failed to send Telegram notification"
        exit 1
    fi
    
    log INFO "Update report sent to Telegram successfully"
    
    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi