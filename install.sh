#!/usr/bin/env bash
# =============================================================================
# 🔥 Firecrawl Auto-Installer for Debian 13 Trixie (Proxmox LXC)
# =============================================================================
# Użycie:  chmod +x install.sh && ./install.sh
#          DEEPSEEK_API_KEY="sk-..." ./install.sh
#          ./install.sh --non-interactive --log-file /var/log/firecrawl-install.log
#          ./install.sh --dry-run
#
# Co robi ten skrypt / What this script does:
#   1. Pre-flight checks (disk, RAM, cgroup, LXC features, connectivity)
#   2. Instaluje wszystkie zależności systemowe
#   3. Instaluje Dockera + Docker Compose (poprawnie dla Debiana 13!)
#   4. Klonuje Firecrawl z GitHub (z retry logic)
#   5. Konfiguruje .env z DeepSeek API
#   6. Podmienia docker-compose.yaml na gotowe obrazy (bez kompilacji)
#   7. Uruchamia wszystkie serwisy
#   8. Tworzy usługę systemd do autostartu
# =============================================================================

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true  # Bash >= 4.4

# =============================================================================
# Kolory / Terminal Colors — consistent palette
#   🔴 Red: errors        🟡 Yellow: warnings
#   🟢 Green: success     🔵 Blue: info
#   🟣 Magenta: headers   🟠 Cyan: progress/paths
#   ⚪ White/Bold: highlights
# =============================================================================
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
    TERM_IS_TTY=true
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
    TERM_IS_TTY=false
fi

# =============================================================================
# Konfiguracja / Configuration
# Wszystko można nadpisać przez zmienne środowiskowe
# Przykład: CONTAINER_IP=10.0.0.50 DEEPSEEK_API_KEY="sk-..." ./install.sh
# =============================================================================
FIRECRAWL_HOST="${FIRECRAWL_HOST:-0.0.0.0}"
FIRECRAWL_PORT="${FIRECRAWL_PORT:-3002}"
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
BULL_AUTH_KEY="${BULL_AUTH_KEY:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

# DeepSeek model — deepseek-chat będzie zdeprecjonowany 2026/07/24
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek-v4-pro}"

# Auto-detekcja adresu IP kontenera / Auto-detect container IP
if [[ -z "${CONTAINER_IP:-}" ]]; then
    CONTAINER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' || \
                   hostname -I 2>/dev/null | awk '{print $1}' || \
                   echo "127.0.0.1")
fi

FIRECRAWL_DIR="/opt/firecrawl"
FIRECRAWL_REPO="https://github.com/firecrawl/firecrawl.git"

# Opcje CLI / CLI options
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
DRY_RUN="${DRY_RUN:-false}"
LOG_FILE="${LOG_FILE:-}"
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
DEBUG="${DEBUG:-false}"
UPDATE_MODE="${UPDATE_MODE:-false}"
STATUS_MODE="${STATUS_MODE:-false}"

# Timestamp do logów / Timestamp for logs
SCRIPT_START_TIME=$(date +%s)
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Minimalne wymagania systemowe / Minimum system requirements
MIN_DISK_GB=40
MIN_RAM_MB=4096
MIN_CPU_CORES=2

# Retry configuration dla network operations
MAX_RETRIES=3
RETRY_DELAY_BASE=5

# Total steps for progress bar
TOTAL_STEPS=7
CURRENT_STEP=0

# =============================================================================
# Parsowanie argumentów CLI / CLI Argument Parsing
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive|-y|--yes)
                NON_INTERACTIVE=true ;;
            --dry-run|--dryrun)
                DRY_RUN=true ;;
            --log-file)
                LOG_FILE="$2"; shift ;;
            --log-file=*)
                LOG_FILE="${1#*=}" ;;
            --skip-preflight)
                SKIP_PREFLIGHT=true ;;
            --debug)
                DEBUG=true ;;
            --update)
                UPDATE_MODE=true ;;
            --status)
                STATUS_MODE=true ;;
            --help|-h)
                echo "Użycie: $0 [opcje]"
                echo ""
                echo "Opcje:"
                echo "  --non-interactive, -y   Tryb bez interakcji (CI/CD)"
                echo "  --dry-run               Pokaż co zostałoby zrobione (nie wykonuj)"
                echo "  --log-file PATH         Zapisz logi do pliku"
                echo "  --skip-preflight        Pomiń testy przedinstalacyjne"
                echo "  --debug                 Więcej logów diagnostycznych"
                echo "  --update                Tylko git pull + docker pull + restart"
                echo "  --status                Pokaż docker compose ps + health check"
                echo "  --help, -h              Ta pomoc"
                echo ""
                echo "Zmienne środowiskowe:"
                echo "  DEEPSEEK_API_KEY        Klucz API DeepSeek"
                echo "  DEEPSEEK_MODEL          Model DeepSeek (domyślnie: deepseek-v4-pro)"
                echo "  BULL_AUTH_KEY           Klucz autoryzacji Bull Queue"
                echo "  POSTGRES_PASSWORD       Hasło PostgreSQL"
                echo "  FIRECRAWL_PORT          Port API (domyślnie: 3002)"
                echo "  NO_COLOR=1              Wyłącz kolory w output"
                exit 0 ;;
            *)
                log_error "Nieznana opcja: $1 (użyj --help)"
                exit 1 ;;
        esac
        shift
    done
}

# =============================================================================
# Logowanie / Logging
# =============================================================================
setup_logging() {
    if [[ -n "$LOG_FILE" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        mkdir -p "$log_dir" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
        log_info "Logowanie do pliku: $LOG_FILE"
    fi
}

log_info()  { echo -e "${BLUE}●${NC} ${DIM}$(date '+%H:%M:%S')${NC} $*"; }
log_ok()    { echo -e "${GREEN}✓${NC} ${DIM}$(date '+%H:%M:%S')${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} ${DIM}$(date '+%H:%M:%S')${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} ${DIM}$(date '+%H:%M:%S')${NC} $*" >&2; }
log_step()  { echo -e "\n${MAGENTA}${BOLD}▸${NC} ${BOLD}$*${NC}"; }
log_debug() { if [[ "${DEBUG:-false}" == "true" ]]; then echo -e "${DIM}  ⟐ $*${NC}"; fi; }

# =============================================================================
# Box-drawing helpers / Ramki — używa ╭╮╰╯├┤│
# =============================================================================
BOX_W=62

box_top() {
    local title="${1:-}"
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        [[ -n "$title" ]] && echo "── ${title} ──"
        return
    fi
    local inner=$((BOX_W - 2))
    if [[ -n "$title" ]]; then
        printf "${MAGENTA}╭%s╮${NC}\n" "$(printf '─%.0s' $(seq 1 $inner))"
        printf "${MAGENTA}│${NC} ${BOLD}%s${NC}%*s${MAGENTA}│${NC}\n" "$title" $((inner - ${#title} - 1)) ""
    else
        printf "${MAGENTA}╭%s╮${NC}\n" "$(printf '─%.0s' $(seq 1 $inner))"
    fi
}

box_mid() {
    [[ "$TERM_IS_TTY" != "true" ]] && return
    printf "${MAGENTA}├%s┤${NC}\n" "$(printf '─%.0s' $(seq 1 $((BOX_W - 2))))"
}

box_bot() {
    [[ "$TERM_IS_TTY" != "true" ]] && { echo ""; return; }
    printf "${MAGENTA}╰%s╯${NC}\n" "$(printf '─%.0s' $(seq 1 $((BOX_W - 2))))"
    echo ""
}

box_line() {
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        echo "  $1"
        return
    fi
    local inner=$((BOX_W - 2))
    printf "${MAGENTA}│${NC} %s%*s${MAGENTA}│${NC}\n" "$1" $((inner - ${#1})) ""
}

box_ok() {
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        echo "  ✓ $1"
        return
    fi
    local inner=$((BOX_W - 2))
    printf "${MAGENTA}│${NC} ${GREEN}✓${NC} %s%*s${MAGENTA}│${NC}\n" "$1" $((inner - ${#1} - 2)) ""
}

box_err() {
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        echo "  ✗ $1"
        return
    fi
    local inner=$((BOX_W - 2))
    printf "${MAGENTA}│${NC} ${RED}✗${NC} %s%*s${MAGENTA}│${NC}\n" "$1" $((inner - ${#1} - 2)) ""
}

box_warn() {
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        echo "  ⚠ $1"
        return
    fi
    local inner=$((BOX_W - 2))
    printf "${MAGENTA}│${NC} ${YELLOW}⚠${NC} %s%*s${MAGENTA}│${NC}\n" "$1" $((inner - ${#1} - 2)) ""
}

# =============================================================================
# Progress bar / Pasek postępu
# =============================================================================
show_progress_bar() {
    local step_num="$1"
    local step_name="$2"
    local width=46

    if [[ "$TERM_IS_TTY" == "true" ]]; then
        local filled=$(( step_num * width / TOTAL_STEPS ))
        local empty=$(( width - filled ))
        echo ""
        printf "  ${CYAN}╔%s╗${NC}\n" "$(printf '═%.0s' $(seq 1 52))"
        printf "  ${CYAN}║${NC} ${BOLD}[${NC}"
        printf "${GREEN}%s${NC}" "$(printf '█%.0s' $(seq 1 $filled))"
        printf "${DIM}%s${NC}" "$(printf '░%.0s' $(seq 1 $empty))"
        printf "${BOLD}]${NC} ${BOLD}%d/%d${NC}  ${CYAN}%-26s${NC} ${CYAN}║${NC}\n" "$step_num" "$TOTAL_STEPS" "$step_name"
        printf "  ${CYAN}╚%s╝${NC}\n" "$(printf '═%.0s' $(seq 1 52))"
        echo ""
    else
        echo ""
        echo "━━━ [${step_num}/${TOTAL_STEPS}] ${step_name} ━━━"
        echo ""
    fi
}

# =============================================================================
# Trap — cleanup na SIGINT/SIGTERM / Cleanup on interrupt
# =============================================================================
cleanup_on_interrupt() {
    local exit_code=$?
    echo ""
    if [[ "$TERM_IS_TTY" == "true" ]]; then
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠  Interrupted — cleaning up...                        ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${YELLOW}⚠ Interrupted — cleaning up...${NC}"
    fi

    kill_spinner

    if [[ -d "$FIRECRAWL_DIR" ]] && [[ -f "$FIRECRAWL_DIR/docker-compose.yaml" ]] && command -v docker &>/dev/null; then
        log_info "Stopping Docker containers..."
        cd "$FIRECRAWL_DIR" && docker compose down --timeout 30 2>/dev/null || true
    fi

    log_info "Installation interrupted. Run again: ./install.sh"

    if [[ -f "$FIRECRAWL_DIR/.env.credentials" ]]; then
        log_warn "Generated credentials saved in: $FIRECRAWL_DIR/.env.credentials"
    fi

    exit "$exit_code"
}

# =============================================================================
# Spinner — wizualny wskaźnik postępu / Visual progress indicator
# Używa tymczasowego pliku jako flagi (zmienna nie propaguje do subshella)
# Uses a temp file as flag (variables don't propagate to subshells)
# =============================================================================
SPINNER_PID=""
SPINNER_FLAG=""
SPINNER_START_TIME=0

start_spinner() {
    local message="$1"
    if [[ "$NON_INTERACTIVE" == "true" ]] || [[ "$DRY_RUN" == "true" ]] || [[ "$TERM_IS_TTY" != "true" ]]; then
        log_info "$message"
        return
    fi
    SPINNER_FLAG=$(mktemp /tmp/firecrawl-spinner.XXXXXX 2>/dev/null || mktemp 2>/dev/null || true)
    SPINNER_START_TIME=$(date +%s)
    (
        local -a spinner_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while [[ -f "${SPINNER_FLAG:-/dev/null}" ]]; do
            local elapsed=$(($(date +%s) - SPINNER_START_TIME))
            local min=$(( elapsed / 60 ))
            local sec=$(( elapsed % 60 ))
            printf "\r  ${CYAN}%s${NC} %s ${DIM}[%02d:%02d]${NC}" "${spinner_chars[$i]}" "$message" "$min" "$sec"
            i=$(( (i + 1) % ${#spinner_chars[@]} ))
            sleep 0.1
        done
        printf "\r\033[K"
    ) &
    SPINNER_PID=$!
}

kill_spinner() {
    # Usuń plik flagi — subshell wykryje brak pliku i zakończy się
    # Remove flag file — subshell detects missing file and exits
    if [[ -n "${SPINNER_FLAG:-}" ]] && [[ -f "$SPINNER_FLAG" ]]; then
        rm -f "$SPINNER_FLAG"
        SPINNER_FLAG=""
    fi
    if [[ -n "${SPINNER_PID:-}" ]]; then
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
}

# =============================================================================
# Pomocnicze / Helpers
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ten skrypt musi być uruchomiony jako root (sudo ./install.sh)"
        exit 1
    fi
}

check_internet() {
    log_info "Checking internet connectivity..."
    local targets=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    for target in "${targets[@]}"; do
        if ping -c 1 -W 3 "$target" > /dev/null 2>&1; then
            log_ok "Internet OK (ping $target)"
            return 0
        fi
    done
    log_error "No internet connectivity!"
    exit 1
}

# Check available disk space in /var/lib/docker and /opt. Warn if < 10GB.
check_disk_space() {
    log_info "Sprawdzanie dostępnego miejsca na dysku..."
    local warn_threshold=10  # GB
    local space_ok=true

    # Check /opt
    if [[ -d /opt ]]; then
        local opt_avail_gb
        opt_avail_gb=$(df --output=avail -BG /opt 2>/dev/null | awk 'NR==2{gsub(/G/,""); print $1}' || echo 0)
        if [[ "$opt_avail_gb" -lt "$warn_threshold" ]]; then
            log_warn "/opt: tylko ${opt_avail_gb} GB wolnego (minimum zalecane: ${warn_threshold} GB)!"
            log_warn "  Może zabraknąć miejsca na obrazy Docker. Rozszerz dysk."
            space_ok=false
        else
            log_ok "/opt: ${opt_avail_gb} GB wolnego (≥ ${warn_threshold} GB)"
        fi
    fi

    # Check /var/lib/docker (or default docker data root)
    local docker_root="/var/lib/docker"
    if [[ -d "$docker_root" ]]; then
        local docker_avail_gb
        docker_avail_gb=$(df --output=avail -BG "$docker_root" 2>/dev/null | awk 'NR==2{gsub(/G/,""); print $1}' || echo 0)
        if [[ "$docker_avail_gb" -lt "$warn_threshold" ]]; then
            log_warn "/var/lib/docker: tylko ${docker_avail_gb} GB wolnego (minimum zalecane: ${warn_threshold} GB)!"
            log_warn "  Rozszerz dysk lub uruchom: docker system prune -a"
            space_ok=false
        else
            log_ok "/var/lib/docker: ${docker_avail_gb} GB wolnego (≥ ${warn_threshold} GB)"
        fi
    fi

    if [[ "$space_ok" == "false" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "Kontynuuję mimo małej ilości miejsca (tryb nieinteraktywny)..."
        elif ! ask_yes_no "Mało miejsca na dysku. Kontynuować mimo to?" "false"; then
            log_error "Przerywam. Zwolnij miejsce na dysku i spróbuj ponownie."
            exit 1
        fi
    fi
}

download() {
    local url="$1"
    local output="$2"
    if command -v curl &> /dev/null; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 "$url" -o "$output"
    elif command -v wget &> /dev/null; then
        wget -q --tries=3 --timeout=10 "$url" -O "$output"
    else
        log_error "No curl or wget! Install one."
        return 1
    fi
}

retry() {
    local description="$1"
    shift
    local attempt=1
    local delay=$RETRY_DELAY_BASE

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            log_warn "Attempt $attempt/$MAX_RETRIES: $description (waiting ${delay}s)..."
        fi
        if "$@" 2>/dev/null; then
            if [[ $attempt -gt 1 ]]; then
                log_ok "Succeeded after $attempt attempts: $description"
            fi
            return 0
        fi
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        attempt=$((attempt + 1))
    done

    log_error "Failed after $MAX_RETRIES attempts: $description"
    return 1
}

ask_yes_no() {
    local prompt="$1"
    local default_yes="${2:-true}"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        if [[ "$default_yes" == "true" ]]; then
            log_info "$prompt → [Y] (auto)"
            return 0
        else
            log_info "$prompt → [N] (auto)"
            return 1
        fi
    fi

    local default_display
    if [[ "$default_yes" == "true" ]]; then
        default_display="Y/n"
    else
        default_display="y/N"
    fi

    echo -ne "   ${YELLOW}${prompt} [${default_display}]${NC} "
    read -r
    echo

    if [[ -z "$REPLY" ]]; then
        [[ "$default_yes" == "true" ]] && return 0 || return 1
    elif [[ "$REPLY" =~ ^[YyTt]$ ]]; then
        return 0
    else
        return 1
    fi
}

ask_input() {
    local prompt="$1"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_warn "$prompt → skipped (non-interactive)"
        echo ""
        return
    fi
    echo -ne "   ${YELLOW}${prompt}${NC} "
    read -r
    echo "$REPLY"
}

# =============================================================================
# Splash screen / Ekran powitalny z animacją
# =============================================================================
show_splash() {
    if [[ "$TERM_IS_TTY" != "true" ]] || [[ "$NON_INTERACTIVE" == "true" ]]; then
        return
    fi

    clear 2>/dev/null || true

    # System info
    local os_name="unknown" kernel_ver="unknown" ram_total="?" cpu_cores="?"
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        os_name="${PRETTY_NAME:-${NAME:-unknown}}"
    fi
    kernel_ver=$(uname -r 2>/dev/null || echo "unknown")
    ram_total=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "?")
    cpu_cores=$(nproc 2>/dev/null || echo "?")

    local version="v2.0.0"

    # Flame ASCII art
    echo -e "${RED}${BOLD}"
    echo "                   .                  "
    echo "                  .:.                 "
    echo "                 .:::.                "
    echo "                .:::::.               "
    echo "               .:;;:::'.              "
    echo "              .:;:..:;:'.             "
    echo "             .:;:.  .:;:'.            "
    echo "            .:;:.    .:;:'.           "
    echo "           .:;:.      ':;,.           "
    echo "          .:;:.        ':;,.          "
    echo "         .:;:.          ':;,.         "
    echo "        .:;:.            ':;,.        "
    echo "       .:;:.              ':;,.       "
    echo "      .:;:.                ':;,.      "
    echo "     .:;:.                  ':;,.     "
    echo "    .:;:.                    ':;,.    "
    echo "   .:;:.                      ':;,.   "
    echo "   '::::'                      '::::'  "
    echo -e "${NC}"
    echo -e "   ${BOLD}${RED}F${YELLOW}I${RED}R${YELLOW}E${RED}C${YELLOW}R${RED}A${YELLOW}W${RED}L${NC} ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "   ${DIM}Auto-Installer ${BOLD}${version}${NC} ${DIM}· Proxmox LXC · Debian 13 · DeepSeek API${NC}"
    echo ""

    # Loading animation
    echo -ne "   ${DIM}Initializing"
    local -a dots=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    for i in $(seq 0 29); do
        local idx=$(( i % ${#dots[@]} ))
        echo -ne "\r   ${CYAN}${dots[$idx]}${NC} ${DIM}Initializing system..."
        sleep 0.1
    done
    echo -e "\r\033[K"

    # System info box
    echo ""
    echo -e "  ${CYAN}╭──────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${CYAN}│${NC}  ${BOLD}System Information${NC}                                       ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────────────────────────────────────────────┤${NC}"
    printf "  ${CYAN}│${NC}  ${DIM}OS:${NC}       %-45s ${CYAN}│${NC}\n" "${os_name}"
    printf "  ${CYAN}│${NC}  ${DIM}Kernel:${NC}   %-45s ${CYAN}│${NC}\n" "${kernel_ver}"
    printf "  ${CYAN}│${NC}  ${DIM}RAM:${NC}      %-45s ${CYAN}│${NC}\n" "${ram_total} GB"
    printf "  ${CYAN}│${NC}  ${DIM}CPU:${NC}      %-45s ${CYAN}│${NC}\n" "${cpu_cores} cores"
    printf "  ${CYAN}│${NC}  ${DIM}IP:${NC}       %-45s ${CYAN}│${NC}\n" "${CONTAINER_IP}"
    echo -e "  ${CYAN}╰──────────────────────────────────────────────────────────╯${NC}"
    echo ""
    sleep 0.5
}

# =============================================================================
# Pre-flight checks / Testy przedinstalacyjne
# =============================================================================
run_preflight_checks() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Pre-flight checks"

    box_top "🔍 Pre-flight Checks — System Verification"
    local all_ok=true

    # OS check
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release || true
        if [[ "${ID:-}" != "debian" ]]; then
            box_warn "OS: ${PRETTY_NAME:-unknown} (not Debian — untested)"
        elif [[ -n "${VERSION_ID:-}" ]] && [[ "${VERSION_ID%%.*}" -lt 13 ]]; then
            box_warn "OS: ${PRETTY_NAME:-unknown} (designed for Debian 13+)"
        else
            box_ok "OS: ${PRETTY_NAME:-unknown}"
        fi
    else
        box_warn "OS: unknown (/etc/os-release not found)"
    fi

    # RAM check
    local total_ram_mb
    total_ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_ram_mb" -lt "$MIN_RAM_MB" ]]; then
        box_err "RAM: ${total_ram_mb} MB (minimum: ${MIN_RAM_MB} MB)"
        all_ok=false
    else
        box_ok "RAM: ${total_ram_mb} MB (≥ ${MIN_RAM_MB} MB)"
    fi

    # CPU cores check
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 0)
    if [[ "$cpu_cores" -lt "$MIN_CPU_CORES" ]]; then
        box_warn "CPU: ${cpu_cores} cores (recommended ≥ ${MIN_CPU_CORES})"
    else
        box_ok "CPU: ${cpu_cores} cores (≥ ${MIN_CPU_CORES})"
    fi

    # Disk space check
    local disk_path="/opt"
    if [[ ! -d "$disk_path" ]]; then disk_path="/"; fi
    local disk_avail_gb
    disk_avail_gb=$(df --output=avail -BG "$disk_path" 2>/dev/null | awk 'NR==2{gsub(/G/,""); print $1}' || echo 0)
    if [[ "$disk_avail_gb" -lt "$MIN_DISK_GB" ]]; then
        box_err "Disk (${disk_path}): ${disk_avail_gb} GB free (minimum: ${MIN_DISK_GB} GB)"
        all_ok=false
    else
        box_ok "Disk (${disk_path}): ${disk_avail_gb} GB free (≥ ${MIN_DISK_GB} GB)"
    fi

    # LXC nesting check
    if [[ -f /proc/sys/net/ipv4/ip_forward ]]; then
        box_ok "LXC nesting: /proc accessible (nesting=1)"
    else
        box_err "LXC nesting: NO /proc/sys access!"
        box_err "  On Proxmox: pct set <CTID> -features keyctl=1,nesting=1"
        box_err "  Then: pct stop <CTID> && pct start <CTID>"
        all_ok=false
    fi

    # Cgroup check
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        box_ok "Cgroup: v2 (unified) — optimal for Docker"
    elif [[ -d /sys/fs/cgroup/cpu ]]; then
        box_warn "Cgroup: v1 (legacy) — v2 recommended"
    else
        box_warn "Cgroup: version unknown"
    fi

    # Check if /opt/firecrawl exists
    if [[ -d "$FIRECRAWL_DIR" ]] && [[ ! -d "$FIRECRAWL_DIR/.git" ]]; then
        box_warn "${FIRECRAWL_DIR} exists (not a git repo) — will be overwritten"
    fi

    # Check port availability
    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -q ":${FIRECRAWL_PORT} "; then
            box_warn "Port ${FIRECRAWL_PORT} is already in use! Set FIRECRAWL_PORT=3003"
        else
            box_ok "Port ${FIRECRAWL_PORT}: available"
        fi
    fi

    box_bot

    if [[ "$all_ok" == "false" ]]; then
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ✗ PRE-FLIGHT CHECKS FAILED                             ║${NC}"
        echo -e "${RED}║  Fix the issues above or use --skip-preflight           ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi

    box_ok "All pre-flight checks passed"
    echo ""
}

# =============================================================================
# Krok 1: Zależności systemowe
# =============================================================================
install_system_deps() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "System dependencies"

    box_top "📦 System Dependencies"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] apt update && apt install curl wget git gnupg ca-certificates..."
        box_bot
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    start_spinner "Updating package lists (apt update)..."
    apt update -qq 2>&1 | tail -1
    kill_spinner
    box_ok "Package lists updated"

    start_spinner "Installing: curl wget git gnupg ca-certificates..."
    apt install -y -qq curl wget git gnupg ca-certificates lsb-release \
        apt-transport-https software-properties-common \
        htop net-tools acl > /dev/null 2>&1
    kill_spinner

    box_ok "System dependencies installed"
    box_bot
}

# =============================================================================
# Krok 2: Instalacja Dockera (POPRAWIONA dla Debiana 13 Trixie!)
# =============================================================================
install_docker() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Docker + Docker Compose"

    box_top "🐳 Docker Engine Installation"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] Docker install from download.docker.com (.asc + .sources format)"
        box_bot
        return 0
    fi

    # Check if Docker already installed
    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        local existing_version
        existing_version=$(docker --version 2>/dev/null)
        box_warn "Docker already installed: ${existing_version}"
        if ! ask_yes_no "Reinstall Docker?" "false"; then
            box_ok "Skipping Docker installation"
            box_bot
            return 0
        fi
    fi

    # Remove old versions
    log_info "Removing old Docker packages (if any)..."
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt remove -y "$pkg" 2>/dev/null || true
    done

    # POPRAWIONA metoda dla Debiana 13: .asc zamiast .gpg, .sources zamiast .list!
    log_info "Adding official Docker repository..."
    install -m 0755 -d /etc/apt/keyrings

    if ! retry "Download Docker GPG key" download \
        "https://download.docker.com/linux/debian/gpg" \
        "/etc/apt/keyrings/docker.asc"; then
        box_err "Failed to download Docker GPG key"
        box_bot
        exit 1
    fi
    chmod a+r /etc/apt/keyrings/docker.asc
    box_ok "Docker GPG key installed (.asc format)"

    # Format DEB822 (.sources) - required for Debian 13
    local debian_codename
    debian_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    local arch
    arch=$(dpkg --print-architecture)

    tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${debian_codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    box_ok "Docker repository configured (.sources format)"

    log_info "Installing Docker packages..."
    apt update -qq

    start_spinner "Installing docker-ce, docker-ce-cli, containerd.io..."
    apt install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
    kill_spinner

    # Enable and start
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker

    # Verification
    log_info "Verifying Docker installation..."
    if docker run --rm hello-world > /dev/null 2>&1; then
        box_ok "Docker: $(docker --version 2>/dev/null)"
        box_ok "Docker Compose: $(docker compose version --short 2>/dev/null)"

        local storage_driver
        storage_driver=$(docker info 2>/dev/null | grep "Storage Driver" | awk -F': ' '{print $2}' || echo "unknown")
        box_ok "Storage driver: ${storage_driver}"

        local cgroup_driver
        cgroup_driver=$(docker info 2>/dev/null | grep "Cgroup Driver" | awk -F': ' '{print $2}' || echo "unknown")
        box_ok "Cgroup driver: ${cgroup_driver}"

        # Warning about overlay2 on ZFS
        if [[ "$storage_driver" == "overlay2" ]]; then
            if stat -f /var/lib/docker 2>/dev/null | grep -q "Type: zfs" || \
               mount 2>/dev/null | grep " / " | grep -q "zfs"; then
                box_warn "overlay2 on ZFS may cause performance issues"
                box_warn "  Consider fuse-overlayfs for ZFS"
            fi
        fi
    else
        box_err "Docker is NOT working correctly!"
        box_err "  Diagnostics:"
        box_err "  1. LXC: features: keyctl=1,nesting=1 ?"
        box_err "     On Proxmox: pct set <CTID> -features keyctl=1,nesting=1"
        box_err "  2. Check AppArmor: dmesg | grep -i apparmor"
        box_err "  3. /etc/pve/lxc/<CTID>.conf: lxc.apparmor.profile = unconfined"
        box_err "  4. pct stop <CTID> && pct start <CTID>"
        box_err "  Logs: journalctl -xeu docker --no-pager -n 50"
        box_bot
        exit 1
    fi

    box_bot
}

# =============================================================================
# Krok 3: Klonowanie Firecrawl (z retry logic)
# =============================================================================
clone_firecrawl() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Clone Firecrawl repo"

    box_top "📥 Clone Firecrawl Repository"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] git clone --depth 1 ${FIRECRAWL_REPO} ${FIRECRAWL_DIR}"
        box_bot
        return 0
    fi

    if [[ -d "$FIRECRAWL_DIR/.git" ]]; then
        box_warn "Firecrawl already exists in ${FIRECRAWL_DIR}"
        if ask_yes_no "Update (git pull)?" "true"; then
            cd "$FIRECRAWL_DIR"
            if retry "Git pull Firecrawl" git pull origin main; then
                box_ok "Firecrawl updated"
            else
                box_err "Failed to update. Check GitHub connectivity."
                box_bot
                exit 1
            fi
        else
            box_ok "Using existing installation"
        fi
    elif [[ -d "$FIRECRAWL_DIR" ]]; then
        box_err "${FIRECRAWL_DIR} exists but is not a git repo!"
        box_err "  Remove it: mv ${FIRECRAWL_DIR} ${FIRECRAWL_DIR}.bak.\$(date +%Y%m%d)"
        box_bot
        exit 1
    else
        log_info "Cloning from GitHub (shallow clone)..."
        if ! retry "Git clone Firecrawl" git clone --depth 1 "$FIRECRAWL_REPO" "$FIRECRAWL_DIR"; then
            box_err "Failed to clone repository"
            box_err "  Check: https://github.com/firecrawl/firecrawl"
            box_bot
            exit 1
        fi
        box_ok "Firecrawl cloned to ${FIRECRAWL_DIR}"
    fi

    cd "$FIRECRAWL_DIR"
    box_bot
}

# =============================================================================
# Krok 4: Konfiguracja .env
# =============================================================================
configure_env() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Configure .env"

    box_top "⚙️  Environment Configuration (.env)"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] Creating .env with DeepSeek configuration"
        box_bot
        return 0
    fi

    cd "$FIRECRAWL_DIR"

    # Backup old .env
    if [[ -f .env ]]; then
        local backup_name=".env.backup.$(date +%Y%m%d_%H%M%S)"
        cp .env "$backup_name"
        box_ok "Old .env backed up as ${backup_name}"
    fi

    # Generate strong passwords if not provided
    if [[ -z "$POSTGRES_PASSWORD" ]]; then
        POSTGRES_PASSWORD=$(</dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[]^_{|}~' 2>/dev/null | head -c 32 || \
            openssl rand -base64 32 2>/dev/null | tr -d '\n/+=' | head -c 32 || \
            date +%s%N | sha256sum 2>/dev/null | head -c 32 || \
            echo "firecrawl_$(date +%s)_$RANDOM$RANDOM")
    fi
    if [[ -z "$BULL_AUTH_KEY" ]]; then
        BULL_AUTH_KEY=$(</dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[]^_{|}~' 2>/dev/null | head -c 32 || \
            openssl rand -base64 24 2>/dev/null | tr -d '\n/+=' | head -c 32 || \
            date +%s%N | sha256sum 2>/dev/null | head -c 32 || \
            echo "bull_$(date +%s)_$RANDOM$RANDOM")
    fi

    # Deprecation warning for deepseek-chat
    local deprecation_notice=""
    if [[ "$DEEPSEEK_MODEL" == "deepseek-chat" ]]; then
        deprecation_notice="# ⚠️  deepseek-chat będzie ZDEPRECJONOWANY 2026/07/24! Zmień na: deepseek-v4-pro"
        box_warn "Model deepseek-chat will be deprecated 2026/07/24"
        box_warn "  Switch to: DEEPSEEK_MODEL=deepseek-v4-pro"
    fi

    # Create .env
    cat > .env <<ENVEOF
# =============================================================================
# Firecrawl .env — wygenerowane automatycznie przez install.sh
# Generated automatically by install.sh — $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================
${deprecation_notice}

# ===== WYMAGANE / REQUIRED =====
NUM_WORKERS_PER_QUEUE=8
PORT=${FIRECRAWL_PORT}
HOST=${FIRECRAWL_HOST}
USE_DB_AUTHENTICATION=false

# ===== DEEPSEEK API (OpenAI-kompatybilny / OpenAI-compatible) =====
# deepseek-chat → deprecated 2026/07/24. Use deepseek-v4-pro or deepseek-v4-flash
OPENAI_BASE_URL=https://api.deepseek.com/v1
OPENAI_API_KEY=${DEEPSEEK_API_KEY}
MODEL_NAME=${DEEPSEEK_MODEL}
# DeepSeek nie ma embeddingów — pozostaw puste
# DeepSeek doesn't support embeddings — leave blank
# MODEL_EMBEDDING_NAME=

# ===== BAZA DANYCH / DATABASE =====
POSTGRES_USER=firecrawl
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=firecrawl
POSTGRES_HOST=nuq-postgres
POSTGRES_PORT=5432

# ===== BEZPIECZEŃSTWO / SECURITY =====
BULL_AUTH_KEY=${BULL_AUTH_KEY}

# ===== WYDAJNOŚĆ / PERFORMANCE =====
CRAWL_CONCURRENT_REQUESTS=10
MAX_CONCURRENT_JOBS=5
BROWSER_POOL_SIZE=5
MAX_CPU=0.8
MAX_RAM=0.8

# ===== LOGOWANIE / LOGGING =====
LOGGING_LEVEL=INFO

# ===== PROXY (opcjonalnie / optional) =====
# PROXY_SERVER=http://ip:port
# PROXY_USERNAME=
# PROXY_PASSWORD=

# ===== WEBHOOKI / WEBHOOKS (opcjonalnie / optional) =====
# SELF_HOSTED_WEBHOOK_URL=
# SELF_HOSTED_WEBHOOK_HMAC_SECRET=
# ALLOW_LOCAL_WEBHOOKS=true

# ===== PLAYWRIGHT / BROWSER =====
# BLOCK_MEDIA=true  # blokuj media aby oszczędzić bandwidth / block media to save bandwidth
HARNESS_STARTUP_TIMEOUT_MS=60000

# ===== SEARXNG (opcjonalnie / optional, do /search API) =====
# SEARXNG_ENDPOINT=
# SEARXNG_ENGINES=
# SEARXNG_CATEGORIES=
ENVEOF

    box_ok ".env file created"

    box_mid
    box_ok "PostgreSQL password: ${#POSTGRES_PASSWORD} chars (auto-generated)"
    box_ok "Bull Auth Key: ${#BULL_AUTH_KEY} chars (auto-generated)"
    if [[ -n "$DEEPSEEK_API_KEY" ]]; then
        box_ok "DeepSeek API Key: set (${DEEPSEEK_API_KEY:0:10}...)"
    else
        box_err "DeepSeek API Key: NOT SET — AI features disabled"
    fi
    box_ok "DeepSeek Model: ${DEEPSEEK_MODEL}"
    box_bot

    echo -e "\n${YELLOW}═══ Generated passwords (save them!): ═══${NC}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        # Logowanie aktywne — nie zapisuj haseł do logu
        # Logging active — don't write passwords to log
        printf "  ${CYAN}PostgreSQL:${NC}    ${GREEN}(%d chars — saved to .env.credentials)${NC}\n" "${#POSTGRES_PASSWORD}"
        printf "  ${CYAN}Bull Auth Key:${NC} ${GREEN}(%d chars — saved to .env.credentials)${NC}\n" "${#BULL_AUTH_KEY}"
        log_info "Passwords NOT logged (security)"
    else
        # Terminal — pokaż pełne hasła / show full passwords
        printf "  ${CYAN}PostgreSQL:${NC}    ${GREEN}%s${NC}\n" "${POSTGRES_PASSWORD}"
        printf "  ${CYAN}Bull Auth Key:${NC} ${GREEN}%s${NC}\n" "${BULL_AUTH_KEY}"
    fi
    echo -e "${YELLOW}══════════════════════════════════════════${NC}\n"

    # Save credentials to separate file (safer)
    cat > .env.credentials <<CREDEOF
# Firecrawl Credentials — wygenerowane $(date)
# TRZYMAJ TEN PLIK W BEZPIECZNYM MIEJSCU!
# KEEP THIS FILE IN A SAFE PLACE!
# Location: ${FIRECRAWL_DIR}/.env.credentials
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
BULL_AUTH_KEY=${BULL_AUTH_KEY}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL}
CREDEOF
    chmod 600 .env.credentials
    log_info "Credentials saved to .env.credentials (chmod 600)"

    # Config validation
    validate_env
}

# =============================================================================
# Walidacja .env po wygenerowaniu / Validate .env after generation
# =============================================================================
validate_env() {
    log_info "Validating .env configuration..."
    local cfg_ok=true

    # Check POSTGRES_PASSWORD is not a template default
    if [[ "$POSTGRES_PASSWORD" =~ ^(changeme|password|postgres|admin|secret|firecrawl_default)$ ]] || [[ ${#POSTGRES_PASSWORD} -lt 32 ]]; then
        log_error "POSTGRES_PASSWORD jest zbyt słabe lub to wartość domyślna szablonu (min. 32 znaki)!"
        cfg_ok=false
    fi

    # Check BULL_AUTH_KEY is not a template default
    if [[ "$BULL_AUTH_KEY" =~ ^(changeme|bull_auth_key|secret|default_key)$ ]] || [[ ${#BULL_AUTH_KEY} -lt 32 ]]; then
        log_error "BULL_AUTH_KEY jest zbyt słabe lub to wartość domyślna szablonu (min. 32 znaki)!"
        cfg_ok=false
    fi

    # Check DEEPSEEK_API_KEY starts with sk- if provided
    if [[ -n "$DEEPSEEK_API_KEY" ]]; then
        if [[ ! "$DEEPSEEK_API_KEY" =~ ^sk- ]]; then
            log_error "DEEPSEEK_API_KEY powinien zaczynać się od \"sk-\". Podano: ${DEEPSEEK_API_KEY:0:8}..."
            cfg_ok=false
        else
            log_ok "DEEPSEEK_API_KEY: format poprawny (sk-...)"
        fi
    else
        log_warn "DEEPSEEK_API_KEY nie ustawiony — funkcje AI będą niedostępne"
    fi

    if [[ "$cfg_ok" == "false" ]]; then
        log_error "Walidacja konfiguracji NIE POWIODŁA SIĘ. Popraw .env i uruchom ponownie."
        log_error "  Edytuj: ${FIRECRAWL_DIR}/.env"
        exit 1
    fi

    log_ok "Konfiguracja .env zwalidowana pomyślnie"
}

# =============================================================================
# Krok 5: Podmiana docker-compose.yaml na gotowe obrazy
# =============================================================================
configure_docker_compose() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Docker Compose setup"

    box_top "🐙 Docker Compose — Prebuilt Images"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] Replace build: → image: in docker-compose.yaml"
        box_bot
        return 0
    fi

    cd "$FIRECRAWL_DIR"

    # Backup original
    if [[ ! -f docker-compose.yaml.original ]]; then
        cp docker-compose.yaml docker-compose.yaml.original
        box_ok "Original docker-compose.yaml saved as .original"
    fi

    box_line "Replacing build: → image: (prebuilt GHCR images)"

    # Use Python for safe YAML editing
    if python3 -c "
import re

with open('docker-compose.yaml', 'r') as f:
    content = f.read()

# 1. x-common-service: comment build:, uncomment image:
content = content.replace(
    '  build: apps/api',
    '  # build: apps/api  # auto: using prebuilt image'
)
content = content.replace(
    '  # image: ghcr.io/firecrawl/firecrawl',
    '  image: ghcr.io/firecrawl/firecrawl  # auto: prebuilt GHCR image'
)

# 2. playwright-service: comment build:, uncomment image:
content = content.replace(
    '    build: apps/playwright-service-ts',
    '    # build: apps/playwright-service-ts  # auto: using prebuilt image'
)
content = content.replace(
    '    # image: ghcr.io/firecrawl/playwright-service:latest',
    '    image: ghcr.io/firecrawl/playwright-service:latest  # auto: prebuilt GHCR image'
)

# 3. nuq-postgres: comment build:, uncomment image:
content = content.replace(
    '    build: apps/nuq-postgres',
    '    # build: apps/nuq-postgres  # auto: using prebuilt image'
)
content = content.replace(
    '    # image: ghcr.io/firecrawl/nuq-postgres:latest',
    '    image: ghcr.io/firecrawl/nuq-postgres:latest  # auto: prebuilt GHCR image'
)

with open('docker-compose.yaml', 'w') as f:
    f.write(content)
" 2>&1; then
        box_ok "docker-compose.yaml configured via Python"
    else
        box_warn "Python3 unavailable — falling back to sed..."
        sed -i 's/^    build: apps\/playwright-service-ts/    # build: apps\/playwright-service-ts  # auto: prebuilt image/' docker-compose.yaml
        sed -i 's/^    # image: ghcr.io\/firecrawl\/playwright-service:latest/    image: ghcr.io\/firecrawl\/playwright-service:latest  # auto: prebuilt image/' docker-compose.yaml
        sed -i 's/^  build: apps\/api/  # build: apps\/api  # auto: prebuilt image/' docker-compose.yaml
        sed -i 's/^  # image: ghcr.io\/firecrawl\/firecrawl/  image: ghcr.io\/firecrawl\/firecrawl  # auto: prebuilt image/' docker-compose.yaml
        sed -i 's/^    build: apps\/nuq-postgres/    # build: apps\/nuq-postgres  # auto: prebuilt image/' docker-compose.yaml
        sed -i 's/^    # image: ghcr.io\/firecrawl\/nuq-postgres:latest/    image: ghcr.io\/firecrawl\/nuq-postgres:latest  # auto: prebuilt image/' docker-compose.yaml
        box_ok "docker-compose.yaml configured via sed"
    fi

    # Verify: check for active build: lines
    local active_builds
    active_builds=$(grep -nP '^\s*build:' docker-compose.yaml 2>/dev/null | grep -v '#' || true)
    if [[ -n "$active_builds" ]]; then
        box_warn "WARNING: Uncommented 'build:' lines found:"
        box_warn "  ${active_builds}"
        box_warn "  Builds may run locally instead of pulling from GHCR"
        if ! ask_yes_no "Continue anyway?" "true"; then
            box_err "Aborting. Restore docker-compose.yaml from .original"
            box_bot
            exit 1
        fi
    else
        box_ok "All build: lines commented, all image: lines active"
    fi

    box_bot
}

# =============================================================================
# Krok 6: Uruchomienie (z retry dla docker pull + GHCR rate limit handling)
# =============================================================================
start_firecrawl() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Launch Firecrawl"

    box_top "🚀 Starting Firecrawl Services"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] docker compose pull && docker compose up -d"
        box_bot
        return 0
    fi

    cd "$FIRECRAWL_DIR"

    # Check disk space before pulling images
    check_disk_space

    box_line "Pulling Docker images from ghcr.io..."
    box_line "$(printf "${DIM}(this may take several minutes)${NC}")"

    local pull_success=false

    # Attempt 1: normal pull
    start_spinner "docker compose pull (attempt 1/3)..."
    if docker compose pull 2>&1; then
        pull_success=true
        kill_spinner
        box_ok "Images pulled successfully"
    else
        local pull_exit=$?      # zapisz exit code PRZED kill_spinner / capture BEFORE kill_spinner
        kill_spinner
        box_warn "docker compose pull exited with code ${pull_exit}"

        # Check for rate limit
        if docker compose pull 2>&1 | grep -qi "rate limit\|too many requests\|429\|DENIED"; then
            box_warn "GHCR rate limit detected!"
            box_warn "  GitHub Container Registry limits anonymous pulls."

            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                local gh_user
                local gh_token
                echo -ne "   ${YELLOW}GitHub username (ENTER to skip): ${NC}"
                read -r gh_user
                if [[ -n "$gh_user" ]]; then
                    echo -ne "   ${YELLOW}GitHub Personal Access Token (classic, read:packages): ${NC}"
                    read -rs gh_token
                    echo ""
                    if [[ -n "$gh_token" ]]; then
                        log_info "Logging in to ghcr.io as ${gh_user}..."
                        if echo "$gh_token" | docker login ghcr.io -u "$gh_user" --password-stdin 2>/dev/null; then
                            box_ok "Logged in to ghcr.io. Retrying pull..."
                            start_spinner "docker compose pull (attempt 2/3, authenticated)..."
                            if docker compose pull 2>&1; then
                                pull_success=true
                                kill_spinner
                                box_ok "Images pulled (authenticated)"
                            else
                                kill_spinner
                                box_warn "Pull still failed despite authentication"
                            fi
                        else
                            box_err "Login to ghcr.io failed"
                        fi
                    fi
                fi
            fi
        fi

        # Attempt 3: retry with exponential backoff
        if [[ "$pull_success" != "true" ]]; then
            box_line "Retrying pull in 10s (attempt 3/3)..."
            sleep 10
            start_spinner "docker compose pull (last attempt)..."
            if docker compose pull 2>&1; then
                pull_success=true
                kill_spinner
                box_ok "Images pulled (after retry)"
            else
                kill_spinner
                box_warn "Pull failed after 3 attempts. Trying to start anyway..."
            fi
        fi
    fi

    box_mid
    box_line "Starting containers..."
    if ! docker compose up -d; then
        box_err "docker compose up -d FAILED!"
        box_err "  Check: docker compose -f ${FIRECRAWL_DIR}/docker-compose.yaml logs"
        box_err "  Check: docker compose -f ${FIRECRAWL_DIR}/docker-compose.yaml config"
        box_bot
        exit 1
    fi
    box_ok "Containers started"

    # Wait for services
    box_mid
    box_line "Waiting for all services (max 3 min)..."

    local max_wait=180
    local waited=0
    local interval=5
    local expected_services=5

    while [[ $waited -lt $max_wait ]]; do
        sleep $interval
        waited=$((waited + interval))

        local running
        running=$(docker compose ps --format json 2>/dev/null | grep -c '"State":"running"' || echo 0)
        local total
        total=$(docker compose ps --format json 2>/dev/null | wc -l || echo "$expected_services")

        local bar_width=28
        local filled=$(( waited * bar_width / max_wait ))
        local empty=$(( bar_width - filled ))
        local bar
        bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
        bar+=$(printf '%*s' "$empty" '' | tr ' ' '░')

        printf "\r  ${MAGENTA}│${NC} ${CYAN}⏳${NC} [${GREEN}%s${DIM}%s${NC}] %d/%d services (${waited}s/${max_wait}s) ${MAGENTA}│${NC}" "$bar" "" "$running" "$total"

        if [[ $running -ge $expected_services ]]; then
            echo ""
            box_ok "All ${expected_services} services running!"
            break
        fi
    done

    if [[ $waited -ge $max_wait ]]; then
        echo ""
        box_warn "Some services may still be starting"
        box_warn "  Check: docker compose -f ${FIRECRAWL_DIR}/docker-compose.yaml ps"
    fi

    # Additional wait for API health
    box_mid
    box_line "Waiting for API health endpoint..."
    local api_ready=false
    for i in $(seq 1 12); do
        if curl -s "http://localhost:${FIRECRAWL_PORT}/v1/health" > /dev/null 2>&1; then
            box_ok "Firecrawl API is responding!"
            api_ready=true
            break
        fi
        sleep 5
    done

    if [[ "$api_ready" != "true" ]]; then
        box_warn "API not responding yet. May need more time to start."
        box_warn "  Check: curl http://localhost:${FIRECRAWL_PORT}/v1/health"
    fi

    box_bot
}

# =============================================================================
# Krok 7: Systemd + finalizacja
# =============================================================================
setup_systemd() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress_bar "$CURRENT_STEP" "Systemd autostart"

    box_top "⚡ Systemd Service Setup"

    if [[ "$DRY_RUN" == "true" ]]; then
        box_line "[DRY-RUN] Create /etc/systemd/system/firecrawl.service"
        box_bot
        return 0
    fi

    local SERVICE_FILE="/etc/systemd/system/firecrawl.service"

    # Backup if exists
    if [[ -f "$SERVICE_FILE" ]]; then
        cp "$SERVICE_FILE" "${SERVICE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        box_ok "Existing firecrawl.service backed up"
    fi

    cat > "$SERVICE_FILE" <<SYSTEMDEOF
[Unit]
Description=Firecrawl Web Scraping API
Documentation=https://docs.firecrawl.dev
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${FIRECRAWL_DIR}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down --timeout 60
ExecReload=/usr/bin/docker compose restart
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=15
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true
ReadWritePaths=/opt/firecrawl /var/lib/docker
RestrictRealtime=true
RestrictSUIDSGID=true
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

    systemctl daemon-reload
    systemctl enable firecrawl.service
    box_ok "firecrawl.service created & enabled"
    box_ok "  systemctl [start|stop|restart|status] firecrawl"
    box_bot
}

# =============================================================================
# Podsumowanie / Summary Dashboard
# =============================================================================
print_summary() {
    local elapsed
    elapsed=$(($(date +%s) - SCRIPT_START_TIME))
    local elapsed_min=$(( elapsed / 60 ))
    local elapsed_sec=$(( elapsed % 60 ))

    # Gather stats
    local container_count="?"
    local disk_used="?"
    if [[ "$DRY_RUN" != "true" ]] && command -v docker &>/dev/null; then
        container_count=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l || echo "?")
        if [[ -d "$FIRECRAWL_DIR" ]]; then
            disk_used=$(du -sh "$FIRECRAWL_DIR" 2>/dev/null | awk '{print $1}' || echo "?")
        fi
    fi

    echo ""
    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║  ✅  FIRECRAWL INSTALLATION COMPLETE                     ║${NC}"
    echo -e "${GREEN}${BOLD}  ╠══════════════════════════════════════════════════════════╣${NC}"
    printf "  ${GREEN}║${NC}  ${DIM}🕐 Time elapsed:${NC}    %-34s ${GREEN}║${NC}\n" "${elapsed_min}m ${elapsed_sec}s"
    printf "  ${GREEN}║${NC}  ${DIM}📡 API Endpoint:${NC}    ${CYAN}%-34s${NC} ${GREEN}║${NC}\n" "http://${CONTAINER_IP}:${FIRECRAWL_PORT}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf "  ${GREEN}║${NC}  ${DIM}📊 Bull Queue UI:${NC}  ${CYAN}%-34s${NC} ${GREEN}║${NC}\n" "http://${CONTAINER_IP}:${FIRECRAWL_PORT}/admin/<KLUCZ>/queues"
        printf "  ${GREEN}║${NC}                                          ${GREEN}║${NC}\n"
        printf "  ${GREEN}║${NC}  ${YELLOW}⚠  Bull Auth Key nie zapisany w logu${NC}       ${GREEN}║${NC}\n" 
        printf "  ${GREEN}║${NC}  ${YELLOW}   (klucz w .env.credentials)${NC}             ${GREEN}║${NC}\n"
    else
        printf "  ${GREEN}║${NC}  ${DIM}📊 Bull Queue UI:${NC}  ${CYAN}%-34s${NC} ${GREEN}║${NC}\n" "http://${CONTAINER_IP}:${FIRECRAWL_PORT}/admin/${BULL_AUTH_KEY}/queues"
    fi
    printf "  ${GREEN}║${NC}  ${DIM}💾 Disk used:${NC}       %-34s ${GREEN}║${NC}\n" "${disk_used}"
    printf "  ${GREEN}║${NC}  ${DIM}🐳 Containers:${NC}      ${GREEN}%-34s${NC} ${GREEN}║${NC}\n" "${container_count}/5 running"
    echo -e "${GREEN}  ╠══════════════════════════════════════════════════════════╣${NC}"
    printf "  ${GREEN}║${NC}  ${YELLOW}🔑 CREDENTIALS SAVED TO: %-28s${NC} ${GREEN}║${NC}\n" ".env.credentials"
    echo -e "${GREEN}  ╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Quick test commands
    echo -e "  ${BOLD}Quick Tests:${NC}"
    echo -e "  🏥 ${DIM}Health:${NC}           curl ${CYAN}http://${CONTAINER_IP}:${FIRECRAWL_PORT}/v1/health${NC}"
    echo -e "  🕷️ ${DIM}Scrape:${NC}           curl -X POST ${CYAN}http://${CONTAINER_IP}:${FIRECRAWL_PORT}/v1/scrape${NC} \\"
    echo -e "                       -H 'Content-Type: application/json' \\"
    echo -e "                       -d '{\"url\":\"https://example.com\"}'"
    echo ""

    echo -e "  ${BOLD}Management:${NC}"
    echo -e "  📋 ${DIM}Status:${NC}           docker compose -f ${FIRECRAWL_DIR}/docker-compose.yaml ps"
    echo -e "  📜 ${DIM}API Logs:${NC}         docker compose -f ${FIRECRAWL_DIR}/docker-compose.yaml logs -f api"
    echo -e "  🔄 ${DIM}Restart:${NC}          systemctl restart firecrawl"
    echo -e "  ⏹️ ${DIM}Stop:${NC}             systemctl stop firecrawl"
    echo ""

    # Deprecation warning if applicable
    if [[ "$DEEPSEEK_MODEL" == "deepseek-chat" ]]; then
        echo -e "  ${RED}${BOLD}⚠️  ATTENTION:${NC}"
        echo -e "  ${RED}Model deepseek-chat will be DEPRECATED on 2026/07/24!${NC}"
        echo -e "  ${RED}Change MODEL_NAME in .env to: deepseek-v4-pro${NC}"
        echo ""
    fi

    # Check script reminder
    if [[ -f "${INSTALL_DIR}/check.sh" ]]; then
        echo -e "  ${GREEN}💡 Run ./check.sh to verify the installation${NC}"
        echo ""
    fi

    echo -e "  ${YELLOW}⚠️  Save credentials from .env.credentials!${NC}"
    echo ""
}

# =============================================================================
# Tryb --update: tylko git pull + docker compose pull + docker compose up -d
# =============================================================================
run_update() {
    log_step "Tryb aktualizacji (--update) — tylko git pull + docker pull + restart"
    check_root

    if [[ ! -d "${FIRECRAWL_DIR}/.git" ]]; then
        log_error "Firecrawl nie jest zainstalowany w ${FIRECRAWL_DIR} (brak repozytorium git)!"
        log_error "Uruchom pełną instalację: ./install.sh"
        exit 1
    fi

    # Disk space check before pulling
    check_disk_space

    cd "$FIRECRAWL_DIR"

    # Git pull
    log_info "git pull origin main..."
    if ! git pull origin main; then
        log_error "git pull NIE POWIODŁO SIĘ. Sprawdź połączenie z GitHub."
        exit 1
    fi
    log_ok "Repozytorium zaktualizowane"

    # Docker compose pull
    log_info "docker compose pull..."
    if ! docker compose pull; then
        log_error "docker compose pull NIE POWIODŁO SIĘ. Sprawdź połączenie z ghcr.io."
        exit 1
    fi
    log_ok "Obrazy Docker zaktualizowane"

    # Restart containers
    log_info "docker compose up -d --remove-orphans..."
    if ! docker compose up -d --remove-orphans; then
        log_error "docker compose up -d NIE POWIODŁO SIĘ!"
        exit 1
    fi
    log_ok "Kontenery uruchomione"

    # Wait for API health
    log_info "Oczekiwanie na gotowość API (max 120s)..."
    local api_ready=false
    for i in $(seq 1 24); do
        if curl -s "http://localhost:${FIRECRAWL_PORT}/v1/health" > /dev/null 2>&1; then
            log_ok "Firecrawl API odpowiada!"
            api_ready=true
            break
        fi
        sleep 5
    done
    if [[ "$api_ready" != "true" ]]; then
        log_warn "API nie odpowiada. Może potrzebować więcej czasu na uruchomienie."
    fi

    log_ok "Aktualizacja zakończona pomyślnie!"
}

# =============================================================================
# Tryb --status: docker compose ps + health check, potem exit
# =============================================================================
run_status() {
    echo ""
    box_top "Status Firecrawl"

    if [[ ! -f "${FIRECRAWL_DIR}/docker-compose.yaml" ]]; then
        box_err "Firecrawl nie jest zainstalowany w ${FIRECRAWL_DIR}"
        box_bot
        exit 1
    fi

    cd "$FIRECRAWL_DIR"

    # docker compose ps
    box_line "docker compose ps:"
    box_bot
    docker compose ps 2>&1 || true
    echo ""

    box_top "Health Check"
    if curl -s "http://localhost:${FIRECRAWL_PORT}/v1/health" 2>/dev/null; then
        box_ok "API: http://localhost:${FIRECRAWL_PORT}/v1/health → OK"
    else
        box_err "API: http://localhost:${FIRECRAWL_PORT}/v1/health → NIE ODPOWIADA"
    fi
    box_bot

    # Container uptime summary
    if command -v docker &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}Uptime kontenerów:${NC}"
        docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
    fi

    exit 0
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Parse args
    parse_args "$@"

    # Setup logging
    setup_logging

    # Handle --status: just show status and exit
    if [[ "$STATUS_MODE" == "true" ]]; then
        run_status
    fi

    # Handle --update: skip system deps + Docker install, only git pull + pull + up
    if [[ "$UPDATE_MODE" == "true" ]]; then
        run_update
        exit 0
    fi

    # Install trap for SIGINT and SIGTERM
    trap cleanup_on_interrupt SIGINT SIGTERM

    # Splash screen (only in TTY)
    show_splash

    # Plain banner for non-TTY
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        echo "   FIRECRAWL Auto-Installer"
        echo "   Proxmox LXC / Debian 13 Trixie + DeepSeek API"
        echo ""
    fi

    # Mode banner
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "   ${MAGENTA}${BOLD}🔍 DRY-RUN MODE — nothing will be changed${NC}"
        echo ""
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo -e "   ${MAGENTA}${BOLD}🤖 NON-INTERACTIVE MODE — no prompts${NC}"
        echo ""
    fi

    # Prompt for API key if not set
    if [[ -z "$DEEPSEEK_API_KEY" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "DEEPSEEK_API_KEY not set! AI features will not work."
        else
            echo -ne "   ${YELLOW}Enter DeepSeek API Key (sk-...): ${NC}"
            read -rs DEEPSEEK_API_KEY
            echo ""  # newline after silent input
            if [[ -z "$DEEPSEEK_API_KEY" ]]; then
                log_error "DeepSeek API Key required for AI features!"
                log_info "You can continue without it, but /extract and JSON format will not work."
                if ! ask_yes_no "Continue without API key?" "false"; then
                    exit 1
                fi
            fi
        fi
    fi

    # Configuration summary
    echo ""
    box_top "Configuration"
    printf "${MAGENTA}│${NC}  ${DIM}IP:${NC}               ${GREEN}%-41s${NC} ${MAGENTA}│${NC}\n" "${CONTAINER_IP}"
    printf "${MAGENTA}│${NC}  ${DIM}Port:${NC}             ${GREEN}%-41s${NC} ${MAGENTA}│${NC}\n" "${FIRECRAWL_PORT}"
    printf "${MAGENTA}│${NC}  ${DIM}DeepSeek Model:${NC}   ${GREEN}%-41s${NC} ${MAGENTA}│${NC}\n" "${DEEPSEEK_MODEL}"
    if [[ -n "$DEEPSEEK_API_KEY" ]]; then
        printf "${MAGENTA}│${NC}  ${DIM}DeepSeek Key:${NC}     ${GREEN}%-41s${NC} ${MAGENTA}│${NC}\n" "✓ Set (${DEEPSEEK_API_KEY:0:10}...)"
    else
        printf "${MAGENTA}│${NC}  ${DIM}DeepSeek Key:${NC}     ${RED}%-41s${NC} ${MAGENTA}│${NC}\n" "✗ Missing"
    fi
    printf "${MAGENTA}│${NC}  ${DIM}Directory:${NC}        ${CYAN}%-41s${NC} ${MAGENTA}│${NC}\n" "${FIRECRAWL_DIR}"
    if [[ -n "$LOG_FILE" ]]; then
        printf "${MAGENTA}│${NC}  ${DIM}Log file:${NC}         ${CYAN}%-41s${NC} ${MAGENTA}│${NC}\n" "${LOG_FILE}"
    fi
    box_bot
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        if ! ask_yes_no "Start installation?" "true"; then
            echo -e "   ${DIM}Cancelled.${NC}"
            exit 0
        fi
    fi

    # Execute all steps
    check_root

    # Pre-flight checks
    if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
        check_internet
        run_preflight_checks
    else
        log_warn "Pre-flight checks skipped (--skip-preflight)"
    fi

    install_system_deps
    install_docker
    clone_firecrawl
    configure_env
    configure_docker_compose
    start_firecrawl
    setup_systemd
    print_summary
}

# Run
main "$@"
