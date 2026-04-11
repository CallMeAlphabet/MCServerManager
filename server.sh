#!/usr/bin/env bash
# =============================================================================
#  LeafMC Server Manager — /opt/leafmc/server.sh
#
#  Dependencies:
#    tmux      — pacman -S tmux
#    mcrcon    — paru -S mcrcon
# =============================================================================

set -euo pipefail

LEAFMC_DIR="/opt/leafmc"
BACKUP_BASE="${LEAFMC_DIR}/backups"
TMUX_PREFIX="leafmc"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}[*]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${RESET} $*"; }
err()     { echo -e "${RED}${BOLD}[✗]${RESET} $*"; }
sep()     { echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    command -v tmux   &>/dev/null || missing+=("tmux (pacman -S tmux)")
    command -v mcrcon &>/dev/null || missing+=("mcrcon (paru -S mcrcon)")
    if [[ "${#missing[@]}" -gt 0 ]]; then
        warn "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo -e "    ${YELLOW}${dep}${RESET}"
        done
        echo
        warn "Some features will be unavailable until these are installed."
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue anyway...${RESET}")"
    fi
}

# ── Server config (.leafmc.conf) ──────────────────────────────────────────────
conf_path()  { echo "${1}/.leafmc.conf"; }

read_conf() {
    local dir="$1" key="$2"
    local conf
    conf=$(conf_path "$dir")
    if [[ -f "$conf" ]]; then
        grep -oP "(?<=^${key}=).+" "$conf" 2>/dev/null || true
    fi
}

write_conf() {
    local dir="$1" key="$2" value="$3"
    local conf
    conf=$(conf_path "$dir")
    if [[ -f "$conf" ]] && grep -q "^${key}=" "$conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$conf"
    else
        echo "${key}=${value}" >> "$conf"
    fi
}

# ── RCON helpers ──────────────────────────────────────────────────────────────
rcon_password() { read_conf "$1" "rcon_password"; }
rcon_port()     { read_conf "$1" "rcon_port"; }

rcon_send() {
    local dir="$1"; shift
    local pass port
    pass=$(rcon_password "$dir")
    port=$(rcon_port "$dir")
    if [[ -z "$pass" || -z "$port" ]]; then
        warn "RCON not configured for this server."
        return 1
    fi
    mcrcon -H localhost -P "$port" -p "$pass" "$@" 2>/dev/null
}

rcon_available() {
    local dir="$1"
    command -v mcrcon &>/dev/null && \
    [[ -n "$(rcon_password "$dir")" ]] && \
    [[ -n "$(rcon_port "$dir")" ]]
}

# ── tmux session helpers ──────────────────────────────────────────────────────
session_name() { echo "${TMUX_PREFIX}-$(basename "$1" | tr '.' '_')"; }

server_running() {
    local sess
    sess=$(session_name "$1")
    tmux has-session -t "$sess" 2>/dev/null
}

# ── Server state detection ────────────────────────────────────────────────────
server_state() {
    local dir="$1"
    local jar_count other_count
    jar_count=$(find "$dir" -maxdepth 1 -type f -name "*.jar" | wc -l)
    other_count=$(find "$dir" -maxdepth 1 -mindepth 1 | wc -l)
    if [[ "$jar_count" -eq 0 ]];                              then echo "empty"
    elif [[ "$jar_count" -eq 1 && "$other_count" -eq 1 ]];   then echo "fresh"
    else                                                            echo "initialized"
    fi
}

scan_servers() {
    ALL_SERVERS=()
    while IFS= read -r -d '' subdir; do
        local state
        state=$(server_state "$subdir")
        [[ "$state" != "empty" ]] && ALL_SERVERS+=("$subdir")
    done < <(find "$LEAFMC_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

get_ram() {
    local dir="$1"
    if [[ -f "${dir}/start.sh" ]]; then
        grep -oP '(?<=-Xmx)\d+' "${dir}/start.sh" 2>/dev/null || echo "?"
    else
        echo "not set"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    clear
    sep
    echo -e "  ${BOLD}${GREEN}LeafMC Server Manager${RESET}"
    echo -e "  ${DIM}${LEAFMC_DIR}${RESET}"
    sep
    echo
}

# =============================================================================
#  BACKUP
# =============================================================================
backup_server() {
    local dir="$1"
    local version
    version=$(basename "$dir")
    local backup_dir="${BACKUP_BASE}/${version}"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local archive="${backup_dir}/${version}_${timestamp}.tar.gz"

    echo
    info "Backing up ${BOLD}${version}${RESET}..."

    # If server is running and RCON available, pause autosave for a clean backup
    local rcon_used=false
    if server_running "$dir" && rcon_available "$dir"; then
        info "Server is live — pausing autosave for a clean backup..."
        rcon_send "$dir" "say [Backup] Starting backup, autosave paused." &>/dev/null || true
        rcon_send "$dir" "save-all" &>/dev/null || true
        sleep 2
        rcon_send "$dir" "save-off" &>/dev/null || true
        rcon_used=true
    elif server_running "$dir"; then
        warn "Server is running but RCON is not configured."
        warn "Backup may catch mid-write world files. Proceed anyway?"
        read -rp "$(echo -e "${BOLD}[y/N]: ${RESET}")" confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    fi

    # Exclude the backups directory itself and logs
    tar -czf "$archive" \
        --exclude="${BACKUP_BASE}" \
        --exclude="${dir}/logs" \
        -C "$(dirname "$dir")" \
        "$(basename "$dir")" 2>/dev/null || true

    # Re-enable autosave
    if [[ "$rcon_used" == true ]]; then
        rcon_send "$dir" "save-on" &>/dev/null || true
        rcon_send "$dir" "say [Backup] Backup complete, autosave resumed." &>/dev/null || true
    fi

    local size
    size=$(du -sh "$archive" 2>/dev/null | cut -f1)
    success "Backup saved: ${CYAN}$(basename "$archive")${RESET} (${size})"
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

list_backups() {
    local dir="$1"
    local version
    version=$(basename "$dir")
    local backup_dir="${BACKUP_BASE}/${version}"

    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
        echo
        warn "No backups found for ${version}."
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
        return
    fi

    mapfile -t BACKUPS < <(ls -t "${backup_dir}"/*.tar.gz 2>/dev/null)

    print_banner
    echo -e "  ${BOLD}Backups for ${version}:${RESET}"
    sep
    for i in "${!BACKUPS[@]}"; do
        local bname size
        bname=$(basename "${BACKUPS[$i]}")
        size=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
        echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${bname}  ${DIM}(${size})${RESET}"
    done
    echo
    sep
    echo -e "  ${BOLD}${CYAN}[r]${RESET}  Restore a backup"
    echo -e "  ${BOLD}${CYAN}[d]${RESET}  Delete a backup"
    echo -e "  ${BOLD}${CYAN}[b]${RESET}  Back"
    echo

    local choice
    read -rp "$(echo -e "${BOLD}Choose: ${RESET}")" choice

    case "$choice" in
        r|R)
            echo
            local idx
            read -rp "$(echo -e "${BOLD}Enter backup number to restore: ${RESET}")" idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#BACKUPS[@]} )); then
                local chosen="${BACKUPS[$((idx-1))]}"
                echo
                warn "This will OVERWRITE the current server files with the backup."
                warn "The current state will be lost. Are you sure?"
                local confirm
                read -rp "$(echo -e "${RED}${BOLD}Type 'yes' to confirm: ${RESET}")" confirm
                if [[ "$confirm" == "yes" ]]; then
                    if server_running "$dir"; then
                        err "Stop the server before restoring a backup."
                    else
                        info "Restoring ${BOLD}$(basename "$chosen")${RESET}..."
                        rm -rf "$dir"
                        tar -xzf "$chosen" -C "$(dirname "$dir")"
                        success "Restore complete."
                    fi
                else
                    warn "Restore cancelled."
                fi
            else
                warn "Invalid selection."
            fi
            ;;
        d|D)
            echo
            local idx
            read -rp "$(echo -e "${BOLD}Enter backup number to delete: ${RESET}")" idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#BACKUPS[@]} )); then
                local chosen="${BACKUPS[$((idx-1))]}"
                rm -f "$chosen"
                success "Deleted $(basename "$chosen")."
            else
                warn "Invalid selection."
            fi
            ;;
        b|B|"") return ;;
        *) warn "Invalid choice." ;;
    esac
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  MANAGE EXISTING SERVER
# =============================================================================
manage_server() {
    local dir="$1"
    local version
    version=$(basename "$dir")

    while true; do
        print_banner
        local state ram running_badge
        state=$(server_state "$dir")
        ram=$(get_ram "$dir")

        if server_running "$dir"; then
            running_badge="${GREEN}${BOLD}● RUNNING${RESET}"
        else
            running_badge="${DIM}○ stopped${RESET}"
        fi

        echo -e "  ${BOLD}Managing:${RESET} ${GREEN}${BOLD}${version}${RESET}  ${running_badge}"
        echo -e "  ${DIM}Path:  ${dir}${RESET}"
        [[ "$state" == "initialized" ]] && echo -e "  ${DIM}RAM:   ${ram}G${RESET}"
        echo
        sep
        echo -e "  ${BOLD}Options:${RESET}"
        sep

        local options=()

        if [[ "$state" == "fresh" ]]; then
            options+=("Run first-time setup")
        fi

        if [[ "$state" == "initialized" ]]; then
            if server_running "$dir"; then
                options+=("Attach to console")
                options+=("Send command to server")
                options+=("Stop server gracefully")
            else
                options+=("Start server")
            fi
            options+=("Backup server")
            options+=("View / restore backups")
            options+=("Edit server.properties")
            options+=("Change RAM allocation  (currently ${ram}G)")
        fi

        options+=("Rename server directory")
        options+=("Delete server")
        options+=("Back to main menu")

        for i in "${!options[@]}"; do
            local label="${options[$i]}"
            if [[ "$label" == "Change RAM allocation"* ]]; then
                echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  Change RAM allocation  ${DIM}(currently ${ram}G)${RESET}"
            elif [[ "$label" == "Attach to console" ]]; then
                echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${GREEN}${label}${RESET}"
            elif [[ "$label" == "Stop server gracefully" ]]; then
                echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${YELLOW}${label}${RESET}"
            elif [[ "$label" == "Delete server" ]]; then
                echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${RED}${label}${RESET}"
            else
                echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${label}"
            fi
        done
        echo

        local choice
        read -rp "$(echo -e "${BOLD}Choose an option: ${RESET}")" choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
            warn "Invalid selection."
            sleep 1
            continue
        fi

        local selected="${options[$((choice-1))]}"
        selected="${selected%%  (*}"

        case "$selected" in

            "Run first-time setup")
                run_first_time_setup "$dir"
                return
                ;;

            "Start server")
                local sess
                sess=$(session_name "$dir")
                echo
                info "Starting LeafMC ${version} in tmux session '${sess}'..."
                tmux new-session -d -s "$sess" -c "$dir" "bash ./start.sh"
                sleep 5
                if server_running "$dir"; then
                    success "Server started! Session: ${CYAN}${sess}${RESET}"
                    echo -e "  ${DIM}Attach with: tmux attach -t ${sess}${RESET}"
                    echo -e "  ${DIM}Detach with: Ctrl+B then D${RESET}"
                else
                    warn "Session may have exited immediately. Check logs in ${dir}/logs/"
                fi
                echo
                read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
                ;;

            "Attach to console")
                local sess
                sess=$(session_name "$dir")
                echo
                info "Attaching to ${BOLD}${sess}${RESET}..."
                echo -e "  ${DIM}Detach with Ctrl+B then D to return here.${RESET}"
                echo
                sleep 1
                tmux attach-session -t "$sess" || warn "Session not found."
                ;;

            "Send command to server")
                if ! rcon_available "$dir"; then
                    echo
                    warn "mcrcon is not installed or RCON is not configured."
                    warn "Install mcrcon with: paru -S mcrcon"
                else
                    echo
                    local cmd
                    read -rp "$(echo -e "${BOLD}Command to send: ${RESET}")" cmd
                    local result
                    result=$(rcon_send "$dir" "$cmd" 2>&1) || true
                    echo
                    if [[ -n "$result" ]]; then
                        echo -e "${DIM}Server response:${RESET}"
                        echo -e "  ${result}"
                    else
                        success "Command sent."
                    fi
                fi
                echo
                read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
                ;;

            "Stop server gracefully")
                echo
                if rcon_available "$dir"; then
                    info "Sending stop via RCON..."
                    rcon_send "$dir" "say Server is stopping in 5 seconds..." &>/dev/null || true
                    sleep 5
                    rcon_send "$dir" "stop" &>/dev/null || true
                    sleep 3
                    success "Stop command sent."
                else
                    local sess
                    sess=$(session_name "$dir")
                    info "Sending stop via tmux (RCON not available)..."
                    tmux send-keys -t "$sess" "stop" Enter 2>/dev/null || warn "Could not send stop command."
                    sleep 3
                    success "Stop command sent to tmux session."
                fi
                read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
                ;;

            "Backup server")
                backup_server "$dir"
                ;;

            "View / restore backups")
                list_backups "$dir"
                ;;

            "Edit server.properties")
                local props="${dir}/server.properties"
                if [[ -f "$props" ]]; then
                    nano "$props"
                    echo
                    success "server.properties saved."
                    if server_running "$dir"; then
                        warn "Restart the server to apply property changes."
                    fi
                else
                    warn "server.properties not found. Run first-time setup first."
                fi
                sleep 1
                ;;

            "Change RAM allocation")
                echo
                local new_ram
                while true; do
                    read -rp "$(echo -e "${BOLD}New RAM in GB (currently ${ram}G): ${RESET}")" new_ram
                    if [[ "$new_ram" =~ ^[0-9]+$ ]] && (( new_ram >= 1 )); then break
                    else warn "Please enter a whole number (e.g. 4)."; fi
                done
                local jar_name
                jar_name=$(basename "$(find "$dir" -maxdepth 1 -name "*.jar" | head -n1)")
                cat > "${dir}/start.sh" <<EOF
#!/usr/bin/env bash
# LeafMC ${version} — start script
# Generated by server.sh

cd "\$(dirname "\$0")"
java -Xmx${new_ram}G -Xms${new_ram}G -jar ${jar_name} nogui
EOF
                chmod +x "${dir}/start.sh"
                success "RAM updated to ${new_ram}G."
                if server_running "$dir"; then
                    warn "Restart the server to apply the new RAM setting."
                fi
                sleep 1
                ;;

            "Rename server directory")
                echo
                if server_running "$dir"; then
                    warn "Stop the server before renaming."
                    sleep 2
                    continue
                fi
                local new_name
                while true; do
                    read -rp "$(echo -e "${BOLD}New name for '${version}': ${RESET}")" new_name
                    new_name="${new_name// /-}"
                    if [[ -z "$new_name" ]]; then
                        warn "Name cannot be empty."
                    elif [[ -e "${LEAFMC_DIR}/${new_name}" ]]; then
                        warn "A directory named '${new_name}' already exists."
                    else
                        break
                    fi
                done
                local new_dir="${LEAFMC_DIR}/${new_name}"
                mv "$dir" "$new_dir"
                success "Renamed '${version}' → '${new_name}'"
                dir="$new_dir"
                version="$new_name"
                sleep 1
                ;;

            "Delete server")
                echo
                if server_running "$dir"; then
                    warn "Stop the server before deleting."
                    sleep 2
                    continue
                fi
                warn "This will permanently delete ${BOLD}${version}${RESET} and ALL its files."
                warn "World data, plugins, configs — everything."
                echo
                local confirm
                read -rp "$(echo -e "${RED}${BOLD}Type the server name to confirm: ${RESET}")" confirm
                if [[ "$confirm" == "$version" ]]; then
                    rm -rf "$dir"
                    success "Server '${version}' deleted."
                    sleep 1
                    return
                else
                    warn "Name didn't match. Deletion cancelled."
                    sleep 1
                fi
                ;;

            "Back to main menu")
                return
                ;;
        esac
    done
}

# =============================================================================
#  FIRST-TIME SETUP
# =============================================================================
run_first_time_setup() {
    local dir="$1"
    local version
    version=$(basename "$dir")
    local jar_name
    jar_name=$(basename "$(find "$dir" -maxdepth 1 -name "*.jar" | head -n1)")

    echo
    sep
    info "Running LeafMC ${version} for the first time..."
    echo -e "  ${YELLOW}(The server will stop after generating eula.txt)${RESET}"
    echo

    cd "$dir"
    java -Xmx2G -Xms2G -jar "$jar_name" nogui || true

    echo
    info "First run complete."

    # Accept EULA
    if [[ -f "${dir}/eula.txt" ]]; then
        sed -i 's/eula=false/eula=true/' "${dir}/eula.txt"
        success "EULA accepted."
    else
        warn "eula.txt not found — you may need to accept it manually."
    fi

    # Configure RCON in server.properties
    if [[ -f "${dir}/server.properties" ]] && command -v mcrcon &>/dev/null; then
        info "Configuring RCON..."
        local rcon_pass rcon_port_num
        rcon_pass=$(openssl rand -hex 12)
        rcon_port_num=25575

        sed -i "s/^enable-rcon=.*/enable-rcon=true/"         "${dir}/server.properties"
        sed -i "s/^rcon.port=.*/rcon.port=${rcon_port_num}/" "${dir}/server.properties"
        sed -i "s/^rcon.password=.*/rcon.password=${rcon_pass}/" "${dir}/server.properties"

        # Write to .leafmc.conf
        write_conf "$dir" "rcon_password" "$rcon_pass"
        write_conf "$dir" "rcon_port"     "$rcon_port_num"
        success "RCON configured (password stored in ${dir}/.leafmc.conf)."
    else
        warn "Skipping RCON setup (mcrcon not installed or server.properties missing)."
    fi

    echo
    sep
    local ram_gb
    while true; do
        read -rp "$(echo -e "${BOLD}How much RAM (in GB) to dedicate to this server? ${RESET}")" ram_gb
        if [[ "$ram_gb" =~ ^[0-9]+$ ]] && (( ram_gb >= 1 )); then break
        else warn "Please enter a whole number (e.g. 4)."; fi
    done

    cat > "${dir}/start.sh" <<EOF
#!/usr/bin/env bash
# LeafMC ${version} — start script
# Generated by server.sh

cd "\$(dirname "\$0")"
java -Xmx${ram_gb}G -Xms${ram_gb}G -jar ${jar_name} nogui
EOF
    chmod +x "${dir}/start.sh"

    echo
    success "start.sh created with ${ram_gb}G RAM."
    sep
    echo -e "  ${BOLD}${GREEN}Setup complete!${RESET}"
    echo -e "  Start your server from the main menu."
    sep
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to return to the main menu...${RESET}")"
}

# =============================================================================
#  ADD NEW SERVER
# =============================================================================
add_new_server() {
    print_banner
    echo -e "  ${BOLD}Add a new LeafMC server${RESET}"
    echo
    sep
    echo
    echo -e "  Download LeafMC from ${CYAN}https://www.leafmc.one/download${RESET}"
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to open the download page in Firefox...${RESET}")"
    firefox "https://www.leafmc.one/download" &>/dev/null &
    disown
    echo
    info "Firefox opened. Come back once the download finishes."
    echo

    local jar_src
    while true; do
        read -rp "$(echo -e "${BOLD}Enter the full path to the downloaded JAR: ${RESET}")" jar_src
        jar_src="${jar_src//\'/}"
        jar_src="${jar_src//\"/}"
        jar_src="${jar_src/#\~/$HOME}"
        if [[ -f "$jar_src" ]]; then break
        else warn "File not found: ${jar_src}"; echo; fi
    done

    local mc_version
    while true; do
        read -rp "$(echo -e "${BOLD}Enter the Minecraft version (e.g. 1.21.1): ${RESET}")" mc_version
        if [[ "$mc_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            if [[ -d "${LEAFMC_DIR}/${mc_version}" ]]; then
                warn "A server named '${mc_version}' already exists."
            else
                break
            fi
        else
            warn "Doesn't look like a valid version (expected e.g. 1.21.1)."
            echo
        fi
    done

    local dest_dir="${LEAFMC_DIR}/${mc_version}"
    mkdir -p "$dest_dir"
    mv "$jar_src" "${dest_dir}/leaf.jar"
    success "Moved JAR to ${CYAN}${dest_dir}/leaf.jar${RESET}"
    echo

    run_first_time_setup "$dest_dir"
}

# =============================================================================
#  MAIN
# =============================================================================
check_deps

while true; do
    print_banner
    scan_servers || true

    if [[ "${#ALL_SERVERS[@]}" -gt 0 ]]; then
        echo -e "  ${BOLD}Your servers:${RESET}"
        sep
        for i in "${!ALL_SERVERS[@]}"; do
            local_dir="${ALL_SERVERS[$i]}"
            ver=$(basename "$local_dir")
            state=$(server_state "$local_dir")
            ram=$(get_ram "$local_dir")

        run_dot=""
            if server_running "$local_dir"; then
                run_dot="${GREEN}●${RESET}"
            else
                run_dot="${DIM}○${RESET}"
            fi

            case "$state" in
                fresh)       badge="${YELLOW}needs setup${RESET}" ;;
                initialized) badge="${GREEN}ready${RESET}  ·  RAM: ${BOLD}${ram}G${RESET}" ;;
                *)           badge="${DIM}unknown${RESET}" ;;
            esac

            echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${run_dot}  ${BOLD}${ver}${RESET}  ${DIM}|${RESET}  ${badge}"
        done
        echo
        sep
        ADD_IDX=$(( ${#ALL_SERVERS[@]} + 1 ))
        QUIT_IDX=$(( ${#ALL_SERVERS[@]} + 2 ))
    else
        info "No servers found in ${LEAFMC_DIR}."
        echo
        sep
        ADD_IDX=1
        QUIT_IDX=2
    fi

    echo -e "  ${BOLD}${CYAN}[${ADD_IDX}]${RESET}  Add a new server"
    echo -e "  ${BOLD}${CYAN}[${QUIT_IDX}]${RESET}  Quit"
    echo

    read -rp "$(echo -e "${BOLD}Choose an option: ${RESET}")" main_choice

    if ! [[ "$main_choice" =~ ^[0-9]+$ ]]; then
        warn "Please enter a number."
        sleep 1
        continue
    fi

    if (( main_choice == QUIT_IDX )); then
        echo
        info "Bye!"
        echo
        exit 0
    elif (( main_choice == ADD_IDX )); then
        add_new_server
    elif [[ "${#ALL_SERVERS[@]}" -gt 0 ]] && (( main_choice >= 1 && main_choice <= ${#ALL_SERVERS[@]} )); then
        manage_server "${ALL_SERVERS[$((main_choice-1))]}"
    else
        warn "Invalid selection."
        sleep 1
    fi
done
