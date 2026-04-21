#!/usr/bin/env bash
# =============================================================================
#  MCServerManager — /opt/mcservers/server.sh
#
#  Supports: LeafMC, Paper, Purpur, Spigot, Fabric, Vanilla
#
#  Dependencies:
#    tmux      — pacman -S tmux  |  apt install tmux
#    mcrcon    — paru -S mcrcon  |  https://github.com/Tiiffi/mcrcon
#    curl      — pacman -S curl  |  apt install curl
#    openssl   — pacman -S openssl | apt install openssl
# =============================================================================

set -euo pipefail

SERVERS_DIR="/opt/mcservers"
BACKUP_BASE="${SERVERS_DIR}/backups"
LOG_BASE="${SERVERS_DIR}/LOGS"
TMUX_PREFIX="mcserver"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

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

# Interactive flag: false when called from cron so prompts are skipped.
_INTERACTIVE=true
[[ ! -t 0 ]] && _INTERACTIVE=false

pause() {
    $(_INTERACTIVE) && read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")" || true
}

# =============================================================================
#  CLI MODE — before check_deps so cron doesn't get blocked by prompts
# =============================================================================
if [[ "${1:-}" == "--backup" && -n "${2:-}" ]]; then
    _CLI_NAME="$2"
    _CLI_DIR="${SERVERS_DIR}/${_CLI_NAME}"
    _CLI_BACKUP=1
    _INTERACTIVE=false
else
    _CLI_BACKUP=0
fi

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    command -v tmux    &>/dev/null || missing+=("tmux")
    command -v mcrcon  &>/dev/null || missing+=("mcrcon")
    command -v curl    &>/dev/null || missing+=("curl")
    command -v openssl &>/dev/null || missing+=("openssl")
    if [[ "${#missing[@]}" -gt 0 ]]; then
        warn "Missing dependencies: ${missing[*]}"
        echo
        warn "Some features will not work until these are installed."
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue anyway...${RESET}")"
    fi
}

# =============================================================================
#  SERVER METADATA  (/opt/mcservers/NAME/ServerManager/)
# =============================================================================
sm_dir()  { echo "${1}/ServerManager"; }
sm_file() { echo "${1}/ServerManager/${2}"; }

read_meta() {
    local dir="$1" key="$2"
    local f
    f=$(sm_file "$dir" "$key")
    [[ -f "$f" ]] && cat "$f" 2>/dev/null || echo ""
}

write_meta() {
    local dir="$1" key="$2" value="$3"
    mkdir -p "$(sm_dir "$dir")"
    printf '%s\n' "$value" > "$(sm_file "$dir" "$key")"
}

server_name()    { basename "$1"; }
server_type()    { read_meta "$1" "type"; }
server_version() { read_meta "$1" "version"; }
server_notes()   { read_meta "$1" "notes"; }

# ── RCON config (.mcserver.conf) ─────────────────────────────────────────────
conf_path() { echo "${1}/.mcserver.conf"; }

read_conf() {
    local dir="$1" key="$2"
    local conf
    conf=$(conf_path "$dir")
    [[ -f "$conf" ]] && grep -oP "(?<=^${key}=).+" "$conf" 2>/dev/null || true
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
    command -v mcrcon &>/dev/null && \
    [[ -n "$(rcon_password "$1")" ]] && \
    [[ -n "$(rcon_port "$1")" ]]
}

# =============================================================================
#  JAVA VERSION CHECK
# =============================================================================
# Returns the major version of whichever `java` is on PATH (e.g. 21, 17, 8).
get_java_major() {
    local raw
    raw=$(java -version 2>&1 | head -1 | grep -oP '(?<=version ")[^"]+')
    # Handles "1.8.0_xxx" (Java 8) and "17.0.x" / "21.0.x" style
    if [[ "$raw" == 1.* ]]; then
        echo "${raw#1.}" | cut -d. -f1
    else
        echo "$raw" | cut -d. -f1
    fi
}

# Minimum Java major version required for a given MC version string.
min_java_for_mc() {
    local mc="$1"
    local major minor
    major=$(echo "$mc" | cut -d. -f1)
    minor=$(echo "$mc" | cut -d. -f2)
    # 1.20.5+  → Java 21
    # 1.17–1.20.4 → Java 17
    # older       → Java 8
    if (( minor >= 20 )); then
        local patch
        patch=$(echo "$mc" | cut -d. -f3)
        patch="${patch:-0}"
        if (( minor > 20 || patch >= 5 )); then
            echo 21; return
        fi
    fi
    if (( minor >= 17 )); then
        echo 17; return
    fi
    echo 8
}

check_java_for_server() {
    local dir="$1"
    local mc_ver
    mc_ver=$(server_version "$dir")
    [[ -z "$mc_ver" ]] && return

    local required actual
    required=$(min_java_for_mc "$mc_ver")
    actual=$(get_java_major 2>/dev/null) || { warn "Could not determine Java version."; return; }

    if (( actual < required )); then
        echo
        warn "Java version mismatch!"
        warn "Minecraft ${mc_ver} requires Java ${required}+, but you have Java ${actual}."
        warn "The server may crash on startup until Java is updated."
        echo
    fi
}

# =============================================================================
#  PORT CONFLICT CHECK
# =============================================================================
get_server_port() {
    local dir="$1"
    local props="${dir}/server.properties"
    [[ -f "$props" ]] && grep -oP '(?<=^server-port=)\d+' "$props" 2>/dev/null || echo "25565"
}

check_port_conflict() {
    local dir="$1"
    local port
    port=$(get_server_port "$dir")

    # Try ss first, then netstat, then lsof
    local in_use=false
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | grep -q ":${port} " && in_use=true
    elif command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | grep -q ":${port} " && in_use=true
    elif command -v lsof &>/dev/null; then
        lsof -i ":${port}" -sTCP:LISTEN &>/dev/null && in_use=true
    fi

    if $in_use; then
        warn "Port ${port} is already in use on this machine."
        warn "Another server may already be running on this port."
        warn "Edit server.properties to change the port, or stop the conflicting process."
        echo
        local ans
        read -rp "$(echo -e "${BOLD}Start anyway? [y/N]: ${RESET}")" ans
        ans="${ans,,}"
        [[ "$ans" != "y" ]] && return 1
    fi
    return 0
}

# =============================================================================
#  TMUX / PROCESS HELPERS
# =============================================================================
session_name() { echo "${TMUX_PREFIX}-$(basename "$1" | tr ' .' '_')"; }

server_running() {
    local sess
    sess=$(session_name "$1")
    tmux has-session -t "$sess" 2>/dev/null
}

get_server_pid() {
    pgrep -f "java.*${1}" 2>/dev/null | head -1 || true
}

get_resource_usage() {
    local pid="$1"
    [[ -z "$pid" ]] && { echo "? ?"; return; }
    # Verify the PID still exists before calling ps
    kill -0 "$pid" 2>/dev/null || { echo "? ?"; return; }
    local cpu mem_kb mem_mb
    cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    [[ -z "$cpu" ]] && { echo "? ?"; return; }
    mem_kb=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
    mem_mb=$(( ${mem_kb:-0} / 1024 ))
    echo "$cpu $mem_mb"
}

# =============================================================================
#  SERVER STATE DETECTION
# =============================================================================
server_state() {
    local dir="$1"
    local jar_count
    jar_count=$(find "$dir" -maxdepth 1 -type f -name "*.jar" 2>/dev/null | wc -l)
    if [[ "$jar_count" -eq 0 ]]; then
        echo "empty"
    elif [[ -d "$(sm_dir "$dir")" && -f "${dir}/start.sh" ]]; then
        echo "initialized"
    else
        echo "fresh"
    fi
}

scan_servers() {
    ALL_SERVERS=()
    while IFS= read -r -d '' subdir; do
        local state
        state=$(server_state "$subdir")
        [[ "$state" != "empty" ]] && ALL_SERVERS+=("$subdir")
    done < <(find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d \
        ! -name "backups" ! -name "LOGS" -print0 2>/dev/null | sort -z)
}

get_ram() {
    local dir="$1"
    [[ -f "${dir}/start.sh" ]] && \
        grep -oP '(?<=-Xmx)\d+' "${dir}/start.sh" 2>/dev/null || echo "?"
}

# =============================================================================
#  DOWNLOAD PAGES + BROWSER
# =============================================================================
download_url() {
    local type="$1" version="${2:-}"
    local vanilla_slug="${version//./-}"
    case "$type" in
        leafmc)  echo "https://www.leafmc.one/download" ;;
        paper)   echo "https://fill-ui.papermc.io/projects/paper" ;;
        purpur)  echo "https://purpurmc.org/download/purpur/${version}" ;;
        spigot)  echo "https://www.spigotmc.org/wiki/buildtools/" ;;
        fabric)  echo "https://fabricmc.net/use/server/" ;;
        vanilla) echo "https://www.minecraft.net/en-us/article/minecraft-java-edition-${vanilla_slug}" ;;
        *)       echo "" ;;
    esac
}

open_url() {
    local url="$1"
    if command -v xdg-open &>/dev/null; then
        xdg-open "$url" &>/dev/null & disown
        return 0
    fi
    local browsers=(firefox chromium chromium-browser google-chrome google-chrome-stable
                    brave-browser microsoft-edge opera vivaldi)
    for b in "${browsers[@]}"; do
        if command -v "$b" &>/dev/null; then
            "$b" "$url" &>/dev/null & disown
            return 0
        fi
    done
    echo -e "  ${YELLOW}No browser found. Open this URL manually:${RESET}"
    echo -e "  ${BOLD}${CYAN}${url}${RESET}"
    return 1
}

maybe_open_url() {
    local url="$1"
    echo -e "  ${DIM}Download page: ${CYAN}${url}${RESET}"
    echo
    local ans
    read -rp "$(echo -e "${BOLD}Open in browser? [Y/n]: ${RESET}")" ans
    ans="${ans,,}"
    if [[ "$ans" != "n" ]]; then
        open_url "$url" && echo -e "  ${DIM}Browser opened. Come back once the download finishes.${RESET}"
    fi
}

# =============================================================================
#  CRASH WATCHER GENERATION
#
#  The watcher runs inside the tmux session as the main process. start.sh runs
#  in its foreground, so `tmux attach` shows the live MC console as expected.
#
#  Clean exit detection:
#   - ServerManager/stopping flag set (menu-triggered stop) → exit cleanly
#   - start.sh exits with code 0 (MC `stop` command typed in console) → exit cleanly
#   - Any other non-zero exit → crash: log, wait 5s, restart
#     After MAX_CRASHES in WINDOW seconds, give up.
# =============================================================================
generate_watcher() {
    local dir="$1"
    mkdir -p "$(sm_dir "$dir")"

    cat > "$(sm_file "$dir" "watcher.sh")" <<'WATCHER_EOF'
#!/usr/bin/env bash
# Auto-generated by MCServerManager — do not edit manually.
SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_NAME="$(basename "$SERVER_DIR")"
LOG_BASE="/opt/mcservers/LOGS"
MAX_CRASHES=3
WINDOW=600   # 10 minutes in seconds

declare -a CRASH_TIMES=()
mkdir -p "$LOG_BASE"

_log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "${LOG_BASE}/$(date +%Y-%m-%d).log"
}

while true; do
    # Intentional stop requested before (re)start?
    if [[ -f "${SERVER_DIR}/ServerManager/stopping" ]]; then
        rm -f "${SERVER_DIR}/ServerManager/stopping"
        exit 0
    fi

    cd "$SERVER_DIR"
    START_TIME=$(date +%s)
    bash ./start.sh
    EXIT_CODE=$?
    END_TIME=$(date +%s)

    # Clean exit: stopping flag (menu) OR exit code 0 (console `stop` command)
    if [[ -f "${SERVER_DIR}/ServerManager/stopping" ]]; then
        rm -f "${SERVER_DIR}/ServerManager/stopping"
        exit 0
    fi
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        exit 0
    fi

    # ── Crash handling ────────────────────────────────────────────────────────
    NOW=$(date +%s)
    DURATION=$(( END_TIME - START_TIME ))

    _log "════════════════════════════════════════"
    _log "CRASH: ${SERVER_NAME}"
    _log "Ran for: ${DURATION}s  |  Exit code: ${EXIT_CODE}"

    NEW_TIMES=()
    for t in "${CRASH_TIMES[@]}"; do
        (( NOW - t < WINDOW )) && NEW_TIMES+=("$t")
    done
    CRASH_TIMES=("${NEW_TIMES[@]}" "$NOW")

    if (( ${#CRASH_TIMES[@]} >= MAX_CRASHES )); then
        _log "TOO MANY CRASHES — ${MAX_CRASHES} in $(( WINDOW / 60 )) min. Giving up."
        _log "Manual intervention required for: ${SERVER_NAME}"
        _log "════════════════════════════════════════"
        echo ""
        echo "!!! ${SERVER_NAME}: ${MAX_CRASHES} crashes in $(( WINDOW / 60 )) min — not restarting. !!!"
        echo "Check logs: ${LOG_BASE}/$(date +%Y-%m-%d).log"
        exit 1
    fi

    _log "Restarting ${SERVER_NAME} (crash ${#CRASH_TIMES[@]}/${MAX_CRASHES})..."
    _log "════════════════════════════════════════"
    echo ""
    echo ">>> ${SERVER_NAME} crashed (exit ${EXIT_CODE}). Restarting in 5s... (${#CRASH_TIMES[@]}/${MAX_CRASHES} in $(( WINDOW / 60 ))min window)"
    sleep 5
done
WATCHER_EOF

    chmod +x "$(sm_file "$dir" "watcher.sh")"
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    clear
    sep
    echo -e "  ${BOLD}${GREEN}MCServerManager${RESET}"
    echo -e "  ${DIM}${SERVERS_DIR}${RESET}"
    sep
    echo
}

# =============================================================================
#  BACKUP
# =============================================================================
backup_server() {
    local dir="$1"
    local name
    name=$(server_name "$dir")
    local backup_dir="${BACKUP_BASE}/${name}"
    mkdir -p "$backup_dir"

    local timestamp archive
    timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    archive="${backup_dir}/${name}_${timestamp}.tar.gz"

    echo
    info "Backing up ${BOLD}${name}${RESET}..."

    local rcon_used=false
    if server_running "$dir" && rcon_available "$dir"; then
        info "Server is live — pausing autosave for a clean backup..."
        rcon_send "$dir" "say [Backup] Starting backup, autosave paused." &>/dev/null || true
        rcon_send "$dir" "save-all" &>/dev/null || true
        sleep 2
        rcon_send "$dir" "save-off" &>/dev/null || true
        rcon_used=true
    elif server_running "$dir"; then
        if [[ "$_INTERACTIVE" == true ]]; then
            warn "Server is running but RCON is not configured."
            warn "Backup may catch mid-write world files. Proceed anyway?"
            local confirm
            read -rp "$(echo -e "${BOLD}[y/N]: ${RESET}")" confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
        fi
        # In cron mode, proceed anyway — best-effort backup
    fi

    tar -czf "$archive" \
        --exclude="${BACKUP_BASE}" \
        --exclude="${dir}/logs" \
        -C "$(dirname "$dir")" \
        "$(basename "$dir")" 2>/dev/null || true

    if [[ "$rcon_used" == true ]]; then
        rcon_send "$dir" "save-on" &>/dev/null || true
        rcon_send "$dir" "say [Backup] Backup complete, autosave resumed." &>/dev/null || true
    fi

    # ── Prune old backups ─────────────────────────────────────────────────────
    local keep
    keep=$(read_meta "$dir" "backup_keep")
    keep="${keep:-5}"
    if [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )); then
        local count
        count=$(ls -t "${backup_dir}"/*.tar.gz 2>/dev/null | wc -l)
        if (( count > keep )); then
            ls -t "${backup_dir}"/*.tar.gz | tail -n "+$(( keep + 1 ))" | xargs rm -f
            info "Pruned old backups (keeping last ${keep})."
        fi
    fi

    local size
    size=$(du -sh "$archive" 2>/dev/null | cut -f1)
    success "Backup saved: ${CYAN}$(basename "$archive")${RESET} (${size})"
    echo
    [[ "$_INTERACTIVE" == true ]] && read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")" || true
}

schedule_backup() {
    local dir="$1"
    local name
    name=$(server_name "$dir")

    print_banner
    echo -e "  ${BOLD}Schedule automatic backups — ${name}${RESET}"
    echo
    sep
    echo -e "  ${BOLD}${CYAN}[1]${RESET}  Every 6 hours"
    echo -e "  ${BOLD}${CYAN}[2]${RESET}  Every 12 hours"
    echo -e "  ${BOLD}${CYAN}[3]${RESET}  Daily at 3 AM"
    echo -e "  ${BOLD}${CYAN}[4]${RESET}  Weekly (Sunday at 3 AM)"
    echo -e "  ${BOLD}${CYAN}[5]${RESET}  Remove scheduled backup for this server"
    echo -e "  ${BOLD}${CYAN}[b]${RESET}  Back"
    echo

    local choice
    read -rp "$(echo -e "${BOLD}Choose: ${RESET}")" choice

    local cron_expr=""
    case "$choice" in
        1) cron_expr="0 */6 * * *" ;;
        2) cron_expr="0 */12 * * *" ;;
        3) cron_expr="0 3 * * *" ;;
        4) cron_expr="0 3 * * 0" ;;
        5)
            crontab -l 2>/dev/null | grep -v "# mcserver-backup-${name}$" | crontab - 2>/dev/null || true
            success "Scheduled backup removed for '${name}'."
            sleep 1; return
            ;;
        b|B|"") return ;;
        *) warn "Invalid choice."; sleep 1; return ;;
    esac

    local cron_cmd="${cron_expr} bash ${SCRIPT_PATH} --backup ${name} # mcserver-backup-${name}"
    ( crontab -l 2>/dev/null | grep -v "# mcserver-backup-${name}$"; echo "$cron_cmd" ) | crontab -
    success "Backup scheduled: ${DIM}${cron_expr}${RESET}"
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

list_backups() {
    local dir="$1"
    local name
    name=$(server_name "$dir")
    local backup_dir="${BACKUP_BASE}/${name}"

    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
        echo; warn "No backups found for '${name}'."; echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
        return
    fi

    mapfile -t BACKUPS < <(ls -t "${backup_dir}"/*.tar.gz 2>/dev/null)
    local keep
    keep=$(read_meta "$dir" "backup_keep")
    keep="${keep:-5}"

    print_banner
    echo -e "  ${BOLD}Backups for ${name}:${RESET}"
    sep
    for i in "${!BACKUPS[@]}"; do
        local bname bsize
        bname=$(basename "${BACKUPS[$i]}")
        bsize=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
        echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${bname}  ${DIM}(${bsize})${RESET}"
    done
    echo
    sep
    echo -e "  ${BOLD}${CYAN}[r]${RESET}  Restore a backup"
    echo -e "  ${BOLD}${CYAN}[d]${RESET}  Delete a backup"
    echo -e "  ${BOLD}${CYAN}[k]${RESET}  Change retention  ${DIM}(currently keeping ${keep})${RESET}"
    echo -e "  ${BOLD}${CYAN}[s]${RESET}  Schedule automatic backups"
    echo -e "  ${BOLD}${CYAN}[b]${RESET}  Back"
    echo

    local choice
    read -rp "$(echo -e "${BOLD}Choose: ${RESET}")" choice
    echo

    case "$choice" in
        r|R)
            local idx
            read -rp "$(echo -e "${BOLD}Backup number to restore: ${RESET}")" idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#BACKUPS[@]} )); then
                local chosen="${BACKUPS[$((idx-1))]}"
                echo
                warn "This will OVERWRITE the current server with the backup."
                warn "World data, plugins, and configs will be replaced."
                local confirm
                read -rp "$(echo -e "${RED}${BOLD}Type 'yes' to confirm: ${RESET}")" confirm
                if [[ "$confirm" == "yes" ]]; then
                    if server_running "$dir"; then
                        err "Stop the server before restoring a backup."
                    else
                        info "Restoring $(basename "$chosen")..."
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
            local idx
            read -rp "$(echo -e "${BOLD}Backup number to delete: ${RESET}")" idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#BACKUPS[@]} )); then
                rm -f "${BACKUPS[$((idx-1))]}"
                success "Deleted $(basename "${BACKUPS[$((idx-1))]}")."
            else
                warn "Invalid selection."
            fi
            ;;
        k|K)
            local new_keep
            read -rp "$(echo -e "${BOLD}How many backups to keep (currently ${keep}): ${RESET}")" new_keep
            if [[ "$new_keep" =~ ^[0-9]+$ ]] && (( new_keep >= 1 )); then
                write_meta "$dir" "backup_keep" "$new_keep"
                success "Retention set to ${new_keep} backups."
            else
                warn "Invalid number."
            fi
            ;;
        s|S) schedule_backup "$dir" ;;
        b|B|"") return ;;
        *) warn "Invalid choice." ;;
    esac

    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  RESOURCE MONITOR
# =============================================================================
resource_monitor() {
    local dir="$1"
    local name ram
    name=$(server_name "$dir")
    ram=$(get_ram "$dir")

    echo
    info "Monitoring ${BOLD}${name}${RESET} — press Ctrl+C to exit"
    echo
    printf "  %-10s  %-22s  %s\n" "CPU %" "RAM used / allocated" "RAM %"
    sep

    local last_pid=""
    while true; do
        if ! server_running "$dir"; then
            echo; warn "Server stopped."; break
        fi

        local pid
        pid=$(get_server_pid "$dir")

        if [[ -z "$pid" ]]; then
            printf "\r  ${DIM}Waiting for Java process...${RESET}                         "
            last_pid=""
        else
            # PID changed (restart) — reset last_pid so we don't show stale data
            [[ "$pid" != "$last_pid" ]] && last_pid="$pid"

            local usage cpu mem_mb ram_mb mem_pct
            usage=$(get_resource_usage "$pid")
            cpu=$(echo "$usage" | cut -d' ' -f1)
            mem_mb=$(echo "$usage" | cut -d' ' -f2)

            if [[ "$cpu" == "?" ]]; then
                # PID disappeared between get_server_pid and get_resource_usage
                printf "\r  ${DIM}Process restarting...${RESET}                              "
            else
                ram_mb=$(( ${ram:-0} * 1024 ))
                if [[ "$ram_mb" -gt 0 && "$mem_mb" =~ ^[0-9]+$ ]]; then
                    mem_pct=$(( mem_mb * 100 / ram_mb ))
                else
                    mem_pct="?"
                fi
                printf "\r  %-10s  %-22s  %s%%        " \
                    "${cpu}%" \
                    "${mem_mb}MB / ${ram}G" \
                    "$mem_pct"
            fi
        fi
        sleep 2
    done

    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  CONSOLE LOG TAIL  (non-intrusive — no tmux attach needed)
# =============================================================================
view_console_tail() {
    local dir="$1"
    local name
    name=$(server_name "$dir")
    local sess
    sess=$(session_name "$dir")

    if ! server_running "$dir"; then
        warn "Server is not running."
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
        return
    fi

    print_banner
    echo -e "  ${BOLD}Console output — ${name}${RESET}  ${DIM}(last 40 lines)${RESET}"
    sep
    echo
    # capture-pane -p dumps the visible pane content; -J joins wrapped lines
    tmux capture-pane -p -J -t "$sess" -S -40 2>/dev/null || warn "Could not capture pane output."
    echo
    sep
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  CRASH LOGS
# =============================================================================
view_crash_logs() {
    print_banner
    echo -e "  ${BOLD}Crash Logs${RESET}"
    echo -e "  ${DIM}${LOG_BASE}${RESET}"
    echo
    sep

    mkdir -p "$LOG_BASE"
    mapfile -t LOGS < <(ls -t "${LOG_BASE}"/*.log 2>/dev/null)

    if [[ "${#LOGS[@]}" -eq 0 ]]; then
        echo
        success "No crash logs found — servers have been well-behaved!"
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
        return
    fi

    for i in "${!LOGS[@]}"; do
        local lname lsize
        lname=$(basename "${LOGS[$i]}")
        lsize=$(du -sh "${LOGS[$i]}" 2>/dev/null | cut -f1)
        echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${lname}  ${DIM}(${lsize})${RESET}"
    done
    echo
    sep
    echo -e "  ${BOLD}${CYAN}[b]${RESET}  Back"
    echo

    local choice
    read -rp "$(echo -e "${BOLD}Choose a log to view: ${RESET}")" choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#LOGS[@]} )); then
        echo
        sep
        cat "${LOGS[$((choice-1))]}"
        sep
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
    fi
}

# =============================================================================
#  DUPLICATE SERVER
# =============================================================================
duplicate_server() {
    local src_dir="$1"
    local src_name
    src_name=$(server_name "$src_dir")

    print_banner
    echo -e "  ${BOLD}Duplicate server — ${src_name}${RESET}"
    echo
    sep
    echo

    local new_name
    while true; do
        read -rp "$(echo -e "${BOLD}New server name: ${RESET}")" new_name
        new_name="${new_name// /-}"
        if [[ -z "$new_name" ]]; then
            warn "Name cannot be empty."
        elif [[ -e "${SERVERS_DIR}/${new_name}" ]]; then
            warn "A server named '${new_name}' already exists."
        else
            break
        fi
        echo
    done

    echo
    local ans
    read -rp "$(echo -e "${BOLD}Copy world data too? [y/N]: ${RESET}")" ans
    ans="${ans,,}"
    local copy_world=false
    [[ "$ans" == "y" ]] && copy_world=true

    local dest_dir="${SERVERS_DIR}/${new_name}"
    info "Duplicating ${src_name} → ${new_name}..."

    if $copy_world; then
        cp -r "$src_dir" "$dest_dir"
    else
        # Copy everything except world folders (world, world_nether, world_the_end, and any custom ones)
        mkdir -p "$dest_dir"
        rsync -a \
            --exclude="world/" \
            --exclude="world_nether/" \
            --exclude="world_the_end/" \
            --exclude="*.log" \
            --exclude="logs/" \
            "$src_dir/" "$dest_dir/" 2>/dev/null || \
        # rsync fallback: use cp with manual world exclusion
        ( cp -r "$src_dir/." "$dest_dir/"
          rm -rf "${dest_dir}/world" "${dest_dir}/world_nether" "${dest_dir}/world_the_end" 2>/dev/null
          true )
    fi

    # Regenerate the watcher (it has the path embedded)
    generate_watcher "$dest_dir"

    success "Duplicated to ${CYAN}${dest_dir}${RESET}"
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  BROADCAST TO ALL RUNNING SERVERS
# =============================================================================
broadcast_all() {
    print_banner
    echo -e "  ${BOLD}Broadcast to all running servers${RESET}"
    echo
    sep
    echo

    local running=()
    for dir in "${ALL_SERVERS[@]}"; do
        server_running "$dir" && running+=("$dir")
    done

    if [[ "${#running[@]}" -eq 0 ]]; then
        warn "No servers are currently running."
        echo
        read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
        return
    fi

    echo -e "  Running servers: $(for d in "${running[@]}"; do echo -n "$(server_name "$d") "; done)"
    echo
    local cmd
    read -rp "$(echo -e "${BOLD}Command to broadcast: ${RESET}")" cmd
    echo

    for dir in "${running[@]}"; do
        local name
        name=$(server_name "$dir")
        if rcon_available "$dir"; then
            rcon_send "$dir" "$cmd" &>/dev/null && success "Sent to ${name}" || warn "Failed: ${name}"
        else
            local sess
            sess=$(session_name "$dir")
            tmux send-keys -t "$sess" "$cmd" Enter 2>/dev/null && success "Sent to ${name} (tmux)" || warn "Failed: ${name}"
        fi
    done

    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  MANAGE EXISTING SERVER
# =============================================================================
manage_server() {
    local dir="$1"

    while true; do
        print_banner

        local name type version state ram running_badge notes
        name=$(server_name "$dir")
        type=$(server_type "$dir")
        version=$(server_version "$dir")
        state=$(server_state "$dir")
        ram=$(get_ram "$dir")
        notes=$(server_notes "$dir")
        [[ -z "$type" ]]    && type="unknown"
        [[ -z "$version" ]] && version="unknown"

        if server_running "$dir"; then
            running_badge="${GREEN}${BOLD}● RUNNING${RESET}"
        else
            running_badge="${DIM}○ stopped${RESET}"
        fi

        echo -e "  ${BOLD}Managing:${RESET} ${GREEN}${BOLD}${name}${RESET}  ${running_badge}"
        echo -e "  ${DIM}Type: ${type}  |  Version: ${version}  |  Path: ${dir}${RESET}"
        [[ "$state" == "initialized" ]] && echo -e "  ${DIM}RAM: ${ram}G${RESET}"
        [[ -n "$notes" ]] && echo -e "  ${DIM}Notes: ${notes}${RESET}"
        echo
        sep

        local options=()

        if [[ "$state" == "fresh" ]]; then
            options+=("Run first-time setup")
        fi

        if [[ "$state" == "initialized" ]]; then
            if server_running "$dir"; then
                options+=("Attach to console")
                options+=("View console output")
                options+=("Send command to server")
                options+=("Resource monitor")
                options+=("Stop server gracefully")
                options+=("Force stop")
            else
                options+=("Start server")
            fi
            options+=("Backup server")
            options+=("View / restore / schedule backups")
            options+=("Edit server.properties")
            options+=("Change RAM allocation")
            options+=("Duplicate server")
        fi

        options+=("Edit notes")
        options+=("Rename server")
        options+=("Delete server")
        options+=("Back to main menu")

        for i in "${!options[@]}"; do
            local label="${options[$i]}"
            case "$label" in
                "Attach to console"|"View console output")
                    echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${GREEN}${label}${RESET}" ;;
                "Stop server gracefully")
                    echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${YELLOW}${label}${RESET}" ;;
                "Force stop")
                    echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${RED}${label}${RESET}" ;;
                "Delete server")
                    echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${RED}${label}${RESET}" ;;
                "Change RAM allocation")
                    echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  Change RAM allocation  ${DIM}(currently ${ram}G)${RESET}" ;;
                *)
                    echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${label}" ;;
            esac
        done
        echo

        local choice
        read -rp "$(echo -e "${BOLD}Choose: ${RESET}")" choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
            warn "Invalid selection."; sleep 1; continue
        fi

        local selected="${options[$((choice-1))]}"

        case "$selected" in

            "Run first-time setup")
                run_first_time_setup "$dir"; return ;;

            "Start server")
                local sess watcher
                sess=$(session_name "$dir")
                watcher=$(sm_file "$dir" "watcher.sh")
                [[ ! -f "$watcher" ]] && generate_watcher "$dir"
                echo
                check_java_for_server "$dir"
                check_port_conflict "$dir" || { sleep 1; continue; }
                info "Starting ${name} in tmux session '${sess}'..."
                tmux new-session -d -s "$sess" -c "$dir" "bash ${watcher}"
                sleep 3
                if server_running "$dir"; then
                    success "Server started!"
                    echo -e "  ${DIM}Attach:  tmux attach -t ${sess}${RESET}"
                    echo -e "  ${DIM}Detach:  Ctrl+B then D${RESET}"
                else
                    warn "Session exited immediately. Check ${dir}/logs/ for errors."
                fi
                echo
                read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
                ;;

            "Attach to console")
                local sess
                sess=$(session_name "$dir")
                echo
                info "Attaching to ${BOLD}${sess}${RESET}..."
                echo -e "  ${DIM}Detach with Ctrl+B then D.${RESET}"
                sleep 1
                tmux attach-session -t "$sess" || warn "Session not found."
                ;;

            "View console output")
                view_console_tail "$dir" ;;

            "Send command to server")
                echo
                if ! rcon_available "$dir"; then
                    warn "mcrcon not installed or RCON not configured for this server."
                else
                    local cmd result
                    read -rp "$(echo -e "${BOLD}Command to send: ${RESET}")" cmd
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

            "Resource monitor")
                resource_monitor "$dir" ;;

            "Stop server gracefully")
                echo
                touch "$(sm_file "$dir" "stopping")"
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
                    success "Stop command sent."
                fi
                read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
                ;;

            "Force stop")
                echo
                warn "This will immediately kill the server process without a clean shutdown."
                warn "Unsaved world data may be lost."
                local fconfirm
                read -rp "$(echo -e "${BOLD}Type 'yes' to confirm force stop: ${RESET}")" fconfirm
                if [[ "$fconfirm" == "yes" ]]; then
                    touch "$(sm_file "$dir" "stopping")"
                    local sess fpid
                    sess=$(session_name "$dir")
                    fpid=$(get_server_pid "$dir")
                    [[ -n "$fpid" ]] && kill -9 "$fpid" 2>/dev/null || true
                    sleep 1
                    tmux kill-session -t "$sess" 2>/dev/null || true
                    success "Server force-stopped."
                else
                    warn "Cancelled."
                fi
                echo
                read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
                ;;

            "Backup server")
                backup_server "$dir" ;;

            "View / restore / schedule backups")
                list_backups "$dir" ;;

            "Edit server.properties")
                local props="${dir}/server.properties"
                if [[ -f "$props" ]]; then
                    nano "$props"
                    echo; success "server.properties saved."
                    server_running "$dir" && warn "Restart the server to apply changes."
                else
                    warn "server.properties not found. Run first-time setup first."
                fi
                sleep 1
                ;;

            "Change RAM allocation")
                echo
                local new_ram jar_name
                while true; do
                    read -rp "$(echo -e "${BOLD}New RAM in GB (currently ${ram}G): ${RESET}")" new_ram
                    [[ "$new_ram" =~ ^[0-9]+$ ]] && (( new_ram >= 1 )) && break
                    warn "Please enter a whole number (e.g. 4)."
                done
                jar_name=$(basename "$(find "$dir" -maxdepth 1 -name "*.jar" | head -n1)")
                cat > "${dir}/start.sh" <<EOF
#!/usr/bin/env bash
# MCServerManager — start script for ${name}
cd "\$(dirname "\$0")"
java -Xmx${new_ram}G -Xms${new_ram}G -jar ${jar_name} nogui
EOF
                chmod +x "${dir}/start.sh"
                success "RAM updated to ${new_ram}G."
                server_running "$dir" && warn "Restart the server to apply."
                sleep 1
                ;;

            "Duplicate server")
                duplicate_server "$dir" ;;

            "Edit notes")
                echo
                local cur_notes new_notes
                cur_notes=$(server_notes "$dir")
                [[ -n "$cur_notes" ]] && echo -e "  ${DIM}Current: ${cur_notes}${RESET}" && echo
                read -rp "$(echo -e "${BOLD}Notes (leave blank to clear): ${RESET}")" new_notes
                write_meta "$dir" "notes" "$new_notes"
                success "Notes saved."
                sleep 1
                ;;

            "Rename server")
                echo
                if server_running "$dir"; then
                    warn "Stop the server before renaming."; sleep 2; continue
                fi
                local new_name
                while true; do
                    read -rp "$(echo -e "${BOLD}New name for '${name}': ${RESET}")" new_name
                    new_name="${new_name// /-}"
                    if [[ -z "$new_name" ]]; then
                        warn "Name cannot be empty."
                    elif [[ -e "${SERVERS_DIR}/${new_name}" ]]; then
                        warn "A directory named '${new_name}' already exists."
                    else
                        break
                    fi
                done
                local new_dir="${SERVERS_DIR}/${new_name}"
                mv "$dir" "$new_dir"
                generate_watcher "$new_dir"
                success "Renamed '${name}' → '${new_name}'"
                dir="$new_dir"
                sleep 1
                ;;

            "Delete server")
                echo
                if server_running "$dir"; then
                    warn "Stop the server before deleting."; sleep 2; continue
                fi
                warn "This will permanently delete ${BOLD}${name}${RESET} and ALL its files."
                warn "World data, plugins, configs — everything."
                echo
                local confirm
                read -rp "$(echo -e "${RED}${BOLD}Type the server name to confirm: ${RESET}")" confirm
                if [[ "$confirm" == "$name" ]]; then
                    rm -rf "$dir"
                    success "Server '${name}' deleted."
                    sleep 1; return
                else
                    warn "Name didn't match. Deletion cancelled."
                    sleep 1
                fi
                ;;

            "Back to main menu") return ;;
        esac
    done
}

# =============================================================================
#  FIRST-TIME SETUP
# =============================================================================
run_first_time_setup() {
    local dir="$1"
    local name type jar_name
    name=$(server_name "$dir")
    type=$(server_type "$dir")
    [[ -z "$type" ]] && type="unknown"
    jar_name=$(basename "$(find "$dir" -maxdepth 1 -name "*.jar" | head -n1)")

    echo
    sep
    info "Running first-time setup for ${BOLD}${name}${RESET} (${type})..."

    # Java version check before first run
    check_java_for_server "$dir"

    echo -e "  ${YELLOW}(The server will stop after generating eula.txt)${RESET}"
    echo

    cd "$dir"
    java -Xmx2G -Xms2G -jar "$jar_name" nogui || true
    echo
    info "First run complete."

    # ── Accept EULA ───────────────────────────────────────────────────────────
    if [[ -f "${dir}/eula.txt" ]]; then
        sed -i 's/eula=false/eula=true/' "${dir}/eula.txt"
        success "EULA accepted."
    else
        warn "eula.txt not found — you may need to accept it manually."
    fi

    # ── Configure RCON ────────────────────────────────────────────────────────
    if [[ -f "${dir}/server.properties" ]] && command -v mcrcon &>/dev/null; then
        info "Configuring RCON..."
        local rcon_pass rcon_port_num
        rcon_pass=$(openssl rand -hex 12)
        rcon_port_num=25575
        sed -i "s/^enable-rcon=.*/enable-rcon=true/"             "${dir}/server.properties"
        sed -i "s/^rcon.port=.*/rcon.port=${rcon_port_num}/"     "${dir}/server.properties"
        sed -i "s/^rcon.password=.*/rcon.password=${rcon_pass}/" "${dir}/server.properties"
        write_conf "$dir" "rcon_password" "$rcon_pass"
        write_conf "$dir" "rcon_port"     "$rcon_port_num"
        success "RCON configured (password stored in ${dir}/.mcserver.conf)."
    else
        warn "Skipping RCON setup (mcrcon not installed or server.properties not found)."
    fi

    # ── RAM allocation ────────────────────────────────────────────────────────
    echo
    sep
    local ram_gb
    while true; do
        read -rp "$(echo -e "${BOLD}How much RAM (in GB) to dedicate to this server? ${RESET}")" ram_gb
        [[ "$ram_gb" =~ ^[0-9]+$ ]] && (( ram_gb >= 1 )) && break
        warn "Please enter a whole number (e.g. 4)."
    done

    cat > "${dir}/start.sh" <<EOF
#!/usr/bin/env bash
# MCServerManager — start script for ${name}
cd "\$(dirname "\$0")"
java -Xmx${ram_gb}G -Xms${ram_gb}G -jar ${jar_name} nogui
EOF
    chmod +x "${dir}/start.sh"

    generate_watcher "$dir"

    [[ -z "$(read_meta "$dir" "backup_keep")" ]] && write_meta "$dir" "backup_keep" "5"

    echo
    success "start.sh created with ${ram_gb}G RAM."
    sep
    echo -e "  ${BOLD}${GREEN}Setup complete for ${name}!${RESET}"
    echo -e "  Start the server from the main menu."
    sep
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to return to the main menu...${RESET}")"
}

# =============================================================================
#  ADD NEW SERVER
# =============================================================================
add_new_server() {
    print_banner
    echo -e "  ${BOLD}Add a new server${RESET}"
    echo
    sep
    echo

    # ── Server name ───────────────────────────────────────────────────────────
    local srv_name
    while true; do
        read -rp "$(echo -e "${BOLD}Server name (e.g. survival, creative, lobby): ${RESET}")" srv_name
        srv_name="${srv_name// /-}"
        if [[ -z "$srv_name" ]]; then
            warn "Name cannot be empty."
        elif [[ -e "${SERVERS_DIR}/${srv_name}" ]]; then
            warn "A server named '${srv_name}' already exists."
        else
            break
        fi
        echo
    done

    # ── Minecraft version ─────────────────────────────────────────────────────
    echo
    local srv_version
    while true; do
        read -rp "$(echo -e "${BOLD}Minecraft version (e.g. 1.21.4): ${RESET}")" srv_version
        [[ "$srv_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && break
        warn "Doesn't look like a valid version (expected e.g. 1.21.4)."
        echo
    done

    # ── Server software ───────────────────────────────────────────────────────
    echo
    sep
    echo -e "  ${BOLD}Server software:${RESET}"
    sep
    echo -e "  ${BOLD}${CYAN}[1]${RESET}  LeafMC   ${DIM}— optimised fork of Paper${RESET}"
    echo -e "  ${BOLD}${CYAN}[2]${RESET}  Paper    ${DIM}— most popular high-performance fork${RESET}"
    echo -e "  ${BOLD}${CYAN}[3]${RESET}  Purpur   ${DIM}— Paper fork with extra configurability${RESET}"
    echo -e "  ${BOLD}${CYAN}[4]${RESET}  Spigot   ${DIM}— classic, requires BuildTools${RESET}"
    echo -e "  ${BOLD}${CYAN}[5]${RESET}  Fabric   ${DIM}— lightweight mod loader${RESET}"
    echo -e "  ${BOLD}${CYAN}[6]${RESET}  Vanilla  ${DIM}— official Mojang server${RESET}"
    echo

    local type_choice srv_type
    while true; do
        read -rp "$(echo -e "${BOLD}Choose [1–6]: ${RESET}")" type_choice
        case "$type_choice" in
            1) srv_type="leafmc";  break ;;
            2) srv_type="paper";   break ;;
            3) srv_type="purpur";  break ;;
            4) srv_type="spigot";  break ;;
            5) srv_type="fabric";  break ;;
            6) srv_type="vanilla"; break ;;
            *) warn "Please pick 1–6." ;;
        esac
    done

    # ── Open download page ────────────────────────────────────────────────────
    local dest_dir="${SERVERS_DIR}/${srv_name}"
    mkdir -p "$dest_dir"
    mkdir -p "$(sm_dir "$dest_dir")"

    echo
    local url
    url=$(download_url "$srv_type" "$srv_version")
    maybe_open_url "$url"
    echo

    local jar_src
    while true; do
        read -rp "$(echo -e "${BOLD}Full path to the downloaded JAR: ${RESET}")" jar_src
        jar_src="${jar_src//\'/}"
        jar_src="${jar_src//\"/}"
        jar_src="${jar_src/#\~/$HOME}"
        [[ -f "$jar_src" ]] && break
        warn "File not found: ${jar_src}"
        echo
    done

    mv "$jar_src" "${dest_dir}/server.jar"
    success "JAR moved to ${CYAN}${dest_dir}/server.jar${RESET}"

    write_meta "$dest_dir" "type"        "$srv_type"
    write_meta "$dest_dir" "version"     "$srv_version"
    write_meta "$dest_dir" "backup_keep" "5"

    echo
    run_first_time_setup "$dest_dir"
}

# =============================================================================
#  BULK ACTIONS
# =============================================================================
start_all_servers() {
    echo
    local started=0
    for dir in "${ALL_SERVERS[@]}"; do
        if ! server_running "$dir" && [[ "$(server_state "$dir")" == "initialized" ]]; then
            local name sess watcher
            name=$(server_name "$dir")
            sess=$(session_name "$dir")
            watcher=$(sm_file "$dir" "watcher.sh")
            [[ ! -f "$watcher" ]] && generate_watcher "$dir"
            check_java_for_server "$dir"
            check_port_conflict "$dir" || { warn "Skipping ${name} due to port conflict."; continue; }
            tmux new-session -d -s "$sess" -c "$dir" "bash ${watcher}"
            success "Started: ${name}"
            (( started++ )) || true
        fi
    done
    [[ "$started" -eq 0 ]] && info "No stopped initialized servers found."
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

stop_all_servers() {
    echo
    local stopped=0
    for dir in "${ALL_SERVERS[@]}"; do
        if server_running "$dir"; then
            local name sess
            name=$(server_name "$dir")
            sess=$(session_name "$dir")
            touch "$(sm_file "$dir" "stopping")"
            if rcon_available "$dir"; then
                rcon_send "$dir" "stop" &>/dev/null || true
            else
                tmux send-keys -t "$sess" "stop" Enter 2>/dev/null || true
            fi
            success "Stop sent to: ${name}"
            (( stopped++ )) || true
        fi
    done
    [[ "$stopped" -eq 0 ]] && info "No servers are currently running."
    echo
    read -rp "$(echo -e "${BOLD}Press Enter to continue...${RESET}")"
}

# =============================================================================
#  CLI BACKUP MODE (called by cron: server.sh --backup <name>)
# =============================================================================
if [[ "$_CLI_BACKUP" -eq 1 ]]; then
    if [[ ! -d "$_CLI_DIR" ]]; then
        echo "Server '${_CLI_NAME}' not found at ${_CLI_DIR}." >&2
        exit 1
    fi
    backup_server "$_CLI_DIR"
    exit 0
fi

# =============================================================================
#  MAIN LOOP
# =============================================================================
check_deps
mkdir -p "$SERVERS_DIR" "$BACKUP_BASE" "$LOG_BASE"

ALL_SERVERS=()

while true; do
    print_banner
    scan_servers || true

    if [[ "${#ALL_SERVERS[@]}" -gt 0 ]]; then
        echo -e "  ${BOLD}Your servers:${RESET}"
        sep
        for i in "${!ALL_SERVERS[@]}"; do
            _dir="${ALL_SERVERS[$i]}"
            _name=$(server_name "$_dir")
            _type=$(server_type "$_dir")
            _version=$(server_version "$_dir")
            _state=$(server_state "$_dir")
            _ram=$(get_ram "$_dir")
            _notes=$(server_notes "$_dir")
            [[ -z "$_type" ]]    && _type="?"
            [[ -z "$_version" ]] && _version="?"

            if server_running "$_dir"; then
                _dot="${GREEN}●${RESET}"
            else
                _dot="${DIM}○${RESET}"
            fi

            case "$_state" in
                fresh)       _badge="${YELLOW}needs setup${RESET}" ;;
                initialized) _badge="${GREEN}ready${RESET}  ·  ${_type} ${_version}  ·  RAM: ${BOLD}${_ram}G${RESET}" ;;
                *)           _badge="${DIM}unknown${RESET}" ;;
            esac

            _notes_str=""
            [[ -n "$_notes" ]] && _notes_str="  ${DIM}${_notes}${RESET}"

            echo -e "  ${BOLD}${CYAN}[$((i+1))]${RESET}  ${_dot}  ${BOLD}${_name}${RESET}  ${DIM}|${RESET}  ${_badge}${_notes_str}"
        done
        echo
        sep

        _n="${#ALL_SERVERS[@]}"
        IDX_STARTALL=$(( _n + 1 ))
        IDX_STOPALL=$(( _n + 2 ))
        IDX_BROADCAST=$(( _n + 3 ))
        IDX_LOGS=$(( _n + 4 ))
        IDX_ADD=$(( _n + 5 ))
        IDX_QUIT=$(( _n + 6 ))

        echo -e "  ${BOLD}${CYAN}[${IDX_STARTALL}]${RESET}  Start all servers"
        echo -e "  ${BOLD}${CYAN}[${IDX_STOPALL}]${RESET}  Stop all servers"
        echo -e "  ${BOLD}${CYAN}[${IDX_BROADCAST}]${RESET}  Broadcast command to all"
        echo -e "  ${BOLD}${CYAN}[${IDX_LOGS}]${RESET}  View crash logs"
        echo -e "  ${BOLD}${CYAN}[${IDX_ADD}]${RESET}  Add a new server"
        echo -e "  ${BOLD}${CYAN}[${IDX_QUIT}]${RESET}  Quit"
    else
        info "No servers found in ${SERVERS_DIR}."
        echo
        sep
        IDX_STARTALL=-1
        IDX_STOPALL=-1
        IDX_BROADCAST=-1
        IDX_LOGS=-1
        IDX_ADD=1
        IDX_QUIT=2

        echo -e "  ${BOLD}${CYAN}[${IDX_ADD}]${RESET}  Add a new server"
        echo -e "  ${BOLD}${CYAN}[${IDX_QUIT}]${RESET}  Quit"
    fi

    echo

    read -rp "$(echo -e "${BOLD}Choose an option: ${RESET}")" main_choice

    if ! [[ "$main_choice" =~ ^[0-9]+$ ]]; then
        warn "Please enter a number."; sleep 1; continue
    fi

    if (( main_choice == IDX_QUIT )); then
        echo; info "Bye!"; echo; exit 0
    elif (( main_choice == IDX_ADD )); then
        add_new_server
    elif (( IDX_STARTALL > 0 && main_choice == IDX_STARTALL )); then
        start_all_servers
    elif (( IDX_STOPALL > 0 && main_choice == IDX_STOPALL )); then
        stop_all_servers
    elif (( IDX_BROADCAST > 0 && main_choice == IDX_BROADCAST )); then
        broadcast_all
    elif (( IDX_LOGS > 0 && main_choice == IDX_LOGS )); then
        view_crash_logs
    elif [[ "${#ALL_SERVERS[@]}" -gt 0 ]] && (( main_choice >= 1 && main_choice <= ${#ALL_SERVERS[@]} )); then
        manage_server "${ALL_SERVERS[$((main_choice-1))]}"
    else
        warn "Invalid selection."; sleep 1
    fi
done
