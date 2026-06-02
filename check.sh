#!/usr/bin/env bash
# =============================================================================
# 🔥 Firecrawl Health Check Script — Dashboard Edition
# =============================================================================
# Sprawdza stan wszystkich komponentów Firecrawl
# Użycie: chmod +x check.sh && ./check.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# Terminal colors
# =============================================================================
if [[ -t 1 ]]; then
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

# Status symbols
PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"

FIRECRAWL_DIR="${FIRECRAWL_DIR:-/opt/firecrawl}"
API_PORT="${API_PORT:-3002}"
API_HOST="${API_HOST:-localhost}"

PASSED=0
FAILED=0
WARNINGS=0
TOTAL=0

# JSON output support
JSON_OUTPUT=false
JSON_RESULTS=""
if [[ "${1:-}" == "--json" ]]; then
    JSON_OUTPUT=true
fi

# =============================================================================
# Box-drawing helpers
# =============================================================================
BOX_W=60

box_top() {
    local title="${1:-}"
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        [[ -n "$title" ]] && echo "── ${title} ──"
        return
    fi
    local inner=$((BOX_W - 2))
    if [[ -n "$title" ]]; then
        printf "  ${CYAN}╭%s╮${NC}\n" "$(printf '─%.0s' $(seq 1 $inner))"
        printf "  ${CYAN}│${NC} ${BOLD}%s${NC}%*s${CYAN}│${NC}\n" "$title" $((inner - ${#title} - 1)) ""
    else
        printf "  ${CYAN}╭%s╮${NC}\n" "$(printf '─%.0s' $(seq 1 $inner))"
    fi
}

box_mid() {
    [[ "$TERM_IS_TTY" != "true" ]] && return
    printf "  ${CYAN}├%s┤${NC}\n" "$(printf '─%.0s' $(seq 1 $((BOX_W - 2))))"
}

box_bot() {
    [[ "$TERM_IS_TTY" != "true" ]] && { echo ""; return; }
    printf "  ${CYAN}╰%s╯${NC}\n" "$(printf '─%.0s' $(seq 1 $((BOX_W - 2))))"
}

box_fill() {
    if [[ "$TERM_IS_TTY" != "true" ]]; then
        echo "  $1"
        return
    fi
    local inner=$((BOX_W - 2))
    printf "  ${CYAN}│${NC} %s%*s${CYAN}│${NC}\n" "$1" $((inner - ${#1})) ""
}

# =============================================================================
# Check function — color-coded results
# =============================================================================
check() {
    local name="$1"
    local result="$2"
    local detail="${3:-}"
    TOTAL=$((TOTAL + 1))

    # Determine status string
    local status="pass"
    if [[ "$result" -eq 2 ]]; then status="warn"; elif [[ "$result" -ne 0 ]]; then status="fail"; fi

    # Collect JSON result
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local json_entry
        json_entry=$(printf '{"name":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")
        if [[ -z "$JSON_RESULTS" ]]; then
            JSON_RESULTS="$json_entry"
        else
            JSON_RESULTS="${JSON_RESULTS},${json_entry}"
        fi
    fi

    if [[ "$result" -eq 0 ]]; then
        if [[ "$TERM_IS_TTY" == "true" ]]; then
            printf "  ${CYAN}│${NC}  ${GREEN}✓${NC} %s%*s${CYAN}│${NC}\n" "$name" $((BOX_W - ${#name} - 6)) ""
        else
            echo "  ✓ ${name}"
        fi
        PASSED=$((PASSED + 1))
    elif [[ "$result" -eq 2 ]]; then
        if [[ "$TERM_IS_TTY" == "true" ]]; then
            printf "  ${CYAN}│${NC}  ${YELLOW}⚠${NC} %s %s%*s${CYAN}│${NC}\n" "$name" "$detail" $((BOX_W - ${#name} - ${#detail} - 7)) ""
        else
            echo "  ⚠ ${name} ${detail}"
        fi
        WARNINGS=$((WARNINGS + 1))
    else
        if [[ "$TERM_IS_TTY" == "true" ]]; then
            printf "  ${CYAN}│${NC}  ${RED}✗${NC} %s %s%*s${CYAN}│${NC}\n" "$name" "$detail" $((BOX_W - ${#name} - ${#detail} - 7)) ""
        else
            echo "  ✗ ${name} ${detail}"
        fi
        FAILED=$((FAILED + 1))
    fi
}

# =============================================================================
# HEADER — System info
# =============================================================================
os_name="unknown"
kernel_ver=$(uname -r 2>/dev/null || echo "unknown")
ram_total=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "?")
cpu_cores=$(nproc 2>/dev/null || echo "?")

if [[ -f /etc/os-release ]]; then
    source /etc/os-release 2>/dev/null || true
    os_name="${PRETTY_NAME:-${NAME:-unknown}}"
fi

version="v2.0.0"

echo ""
if [[ "$TERM_IS_TTY" == "true" ]]; then
    echo -e "  ${RED}${BOLD}  ╭──────────────────────────────────────────────────────────╮${NC}"
    echo -e "  ${RED}${BOLD}  │${NC}  ${BOLD}🔥 Firecrawl Health Check  ${version}${NC}                         ${RED}${BOLD}│${NC}"
    echo -e "  ${RED}${BOLD}  ├──────────────────────────────────────────────────────────┤${NC}"
    printf "  ${RED}${BOLD}  │${NC}  ${DIM}OS:${NC}  %-51s ${RED}${BOLD}│${NC}\n" "${os_name}"
    printf "  ${RED}${BOLD}  │${NC}  ${DIM}RAM:${NC} %-51s ${RED}${BOLD}│${NC}\n" "${ram_total} GB  |  ${cpu_cores} CPUs"
    echo -e "  ${RED}${BOLD}  ╰──────────────────────────────────────────────────────────╯${NC}"
else
    echo "  🔥 Firecrawl Health Check ${version}"
    echo "  OS: ${os_name}  |  RAM: ${ram_total} GB  |  ${cpu_cores} CPUs"
fi
echo ""

# =============================================================================
# SYSTEM CHECKS
# =============================================================================
box_top "🖥️  System"

# OS
source /etc/os-release 2>/dev/null || true
check "OS: ${PRETTY_NAME:-unknown}" 0

# RAM
total_ram=$(free -m | awk '/^Mem:/{print $2}')
if [[ $total_ram -lt 4096 ]]; then
    check "RAM: ${total_ram} MB (MINIMUM: 4096 MB!)" 1 "— increase container RAM!"
else
    check "RAM: ${total_ram} MB ($(awk "BEGIN {printf \"%.1f\", $total_ram/1024}") GB)" 0
fi

# Disk
disk_avail_raw=$(df -h / | awk 'NR==2 {print $4}')
if [[ "$disk_avail_raw" =~ G ]]; then
    disk_avail=$(echo "$disk_avail_raw" | sed 's/G//')
elif [[ "$disk_avail_raw" =~ M ]]; then
    disk_avail=$(echo "$disk_avail_raw" | sed 's/M//' | awk '{printf "%.1f", $1/1024}')
else
    disk_avail="999"
fi
if [[ "$disk_avail" == "999" ]]; then
    check "Disk free: ${disk_avail_raw} (unknown format)" 2 "— check manually: df -h /"
elif awk "BEGIN {exit !($disk_avail < 20)}"; then
    check "Disk free: ${disk_avail_raw} (LOW!)" 2 "— expand disk"
else
    check "Disk free: ${disk_avail_raw}" 0
fi

# LXC nesting
if [[ -f /proc/sys/net/ipv4/ip_forward ]]; then
    check "LXC nesting: OK (/proc accessible)" 0
else
    check "LXC nesting: MISSING!" 1 "— add features: nesting=1"
fi

box_bot

# =============================================================================
# NETWORK CONNECTIVITY
# =============================================================================
box_top "🌐 Network Connectivity"

# Check api.deepseek.com
if ping -c 1 -W 3 api.deepseek.com > /dev/null 2>&1; then
    check "api.deepseek.com: reachable" 0
elif curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.deepseek.com/v1/models 2>/dev/null | grep -q "200\|401\|403"; then
    check "api.deepseek.com: reachable (HTTPS)" 0
else
    check "api.deepseek.com: UNREACHABLE" 1 "— sprawdź DNS / firewall"
fi

# Check github.com
if ping -c 1 -W 3 github.com > /dev/null 2>&1; then
    check "github.com: reachable" 0
elif curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" https://github.com 2>/dev/null | grep -q "200\|301"; then
    check "github.com: reachable (HTTPS)" 0
else
    check "github.com: UNREACHABLE" 1 "— sprawdź DNS / firewall"
fi

box_bot

# =============================================================================
# DOCKER CHECKS
# =============================================================================
box_top "🐳 Docker"

if command -v docker &> /dev/null; then
    docker_ver=$(docker --version 2>/dev/null | head -n 1)
    check "Docker: ${docker_ver}" 0

    if docker info &> /dev/null; then
        check "Docker daemon: running" 0
    else
        check "Docker daemon: NOT RUNNING" 1 "— systemctl start docker"
    fi

    # Storage driver
    storage_driver=$(docker info 2>/dev/null | grep "Storage Driver" | awk -F': ' '{print $2}' || echo "unknown")
    if [[ "$storage_driver" == "overlay2" ]]; then
        check "Storage driver: overlay2 (optimal)" 0
    else
        check "Storage driver: ${storage_driver}" 2 "— overlay2 recommended"
    fi
else
    check "Docker: NOT INSTALLED" 1 "— run install.sh"
fi

if docker compose version &> /dev/null; then
    check "Docker Compose: $(docker compose version --short)" 0
else
    check "Docker Compose: MISSING" 1
fi

# Docker disk usage
if command -v docker &> /dev/null && docker info &> /dev/null; then
    docker_df=$(docker system df --format 'table {{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null || true)
    if [[ -n "$docker_df" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^TYPE ]] && continue
            dtype=$(echo "$line" | cut -d'|' -f1 | xargs)
            dcount=$(echo "$line" | cut -d'|' -f2 | xargs)
            dsize=$(echo "$line" | cut -d'|' -f3 | xargs)
            dreclaim=$(echo "$line" | cut -d'|' -f4 | xargs)
            if [[ "$dreclaim" != "0B" && "$dreclaim" != "true" ]]; then
                check "Docker ${dtype}: ${dcount} × ${dsize} (reclaim: ${dreclaim})" 2 "— docker system prune"
            else
                check "Docker ${dtype}: ${dcount} × ${dsize}" 0
            fi
        done <<< "$docker_df"
    fi
fi

box_bot

# =============================================================================
# FIRECRAWL CONTAINERS
# =============================================================================
box_top "📦 Firecrawl Containers"

if [[ -f "${FIRECRAWL_DIR}/docker-compose.yaml" ]]; then
    cd "${FIRECRAWL_DIR}"

    EXPECTED_SERVICES=("api" "playwright-service" "redis" "rabbitmq" "nuq-postgres")

    for svc in "${EXPECTED_SERVICES[@]}"; do
        state=$(docker compose ps --format json 2>/dev/null | grep "\"Service\":\"${svc}\"" | grep -o '"State":"[^"]*"' | cut -d'"' -f4 || echo "missing")
        case "$state" in
            "running")
                check "Container ${svc}: running" 0 ;;
            "starting")
                check "Container ${svc}: starting..." 2 "— wait a moment" ;;
            "unhealthy")
                check "Container ${svc}: unhealthy" 1 "— docker compose restart ${svc}" ;;
            "exited")
                check "Container ${svc}: exited (stopped)" 1 "— docker compose restart ${svc}" ;;
            "missing")
                check "Container ${svc}: MISSING" 1 "— docker compose up -d" ;;
            *)
                check "Container ${svc}: ${state}" 1 "— unknown state" ;;
        esac
    done

    # Container uptime
    uptime_info=$(docker compose ps --format json 2>/dev/null | python3 -c "
import json, sys, datetime
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        c = json.loads(line)
        svc = c.get('Service','?')
        state = c.get('State','?')
        status = c.get('Status','')
        # Parse Docker uptime like 'Up 3 hours'
        if 'Up' in status and state == 'running':
            uptime = status.replace('Up ','')
            print(f'{svc}: {uptime}')
        elif state == 'running':
            print(f'{svc}: running (uptime unknown)')
    except: pass
" 2>/dev/null || true)
    if [[ -n "$uptime_info" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local cname=$(echo "$line" | cut -d':' -f1 | xargs)
            local ctime=$(echo "$line" | cut -d':' -f2- | xargs)
            check "  Uptime ${cname}: ${ctime}" 0
        done <<< "$uptime_info"
    fi
else
    check "docker-compose.yaml: MISSING in ${FIRECRAWL_DIR}" 1
fi

box_bot

# =============================================================================
# API CHECKS
# =============================================================================
box_top "📡 Firecrawl API"

# Port
if ss -tlnp 2>/dev/null | grep -q ":${API_PORT}"; then
    check "Port ${API_PORT}: listening" 0
else
    check "Port ${API_PORT}: NOT listening" 1
fi

# Health endpoint
health=$(curl -s -o /dev/null -w "%{http_code}" "http://${API_HOST}:${API_PORT}/v1/health" 2>/dev/null || echo "000")
if [[ "$health" == "200" ]]; then
    check "GET /v1/health: 200 OK" 0
else
    check "GET /v1/health: ${health}" 1 "— API not responding"
fi

# Scrape test
scrape_test=$(curl -s -X POST "http://${API_HOST}:${API_PORT}/v1/scrape" \
    -H 'Content-Type: application/json' \
    -d '{"url":"https://httpbin.org/status/200","formats":["markdown"],"timeout":15000}' 2>/dev/null)
if echo "$scrape_test" | grep -q '"success":true'; then
    check "POST /v1/scrape: working ✓" 0
elif echo "$scrape_test" | grep -q '"success":false'; then
    check "POST /v1/scrape: returned error" 2 "— $(echo "$scrape_test" | head -c 80)"
else
    check "POST /v1/scrape: timeout/error" 1
fi

box_bot

# =============================================================================
# CONFIGURATION CHECKS
# =============================================================================
box_top "⚙️  Configuration"

if [[ -f "${FIRECRAWL_DIR}/.env" ]]; then
    check ".env file: exists" 0

    # Check critical variables
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        case "$key" in
            OPENAI_API_KEY)
                if [[ -n "$value" && "$value" != *"TWÓJ_KLUCZ"* && "$value" != *"ZMIEŃ"* ]]; then
                    check "  OPENAI_API_KEY: set" 0
                else
                    check "  OPENAI_API_KEY: MISSING/INVALID" 2 "— AI features won't work"
                fi
                ;;
            POSTGRES_PASSWORD)
                if [[ -n "$value" && ${#value} -ge 32 && "$value" != *"ZMIEŃ"* ]]; then
                    check "  POSTGRES_PASSWORD: set (${#value} chars)" 0
                else
                    check "  POSTGRES_PASSWORD: INVALID" 1 "— minimum 32 chars"
                fi
                ;;
            BULL_AUTH_KEY)
                if [[ -n "$value" && ${#value} -ge 32 && "$value" != *"ZMIEŃ"* ]]; then
                    check "  BULL_AUTH_KEY: set (${#value} chars)" 0
                else
                    check "  BULL_AUTH_KEY: INVALID" 1 "— minimum 32 chars"
                fi
                ;;
        esac
    done < "${FIRECRAWL_DIR}/.env"
else
    check ".env file: MISSING" 1 "— copy .env.example → .env"
fi

box_bot

# =============================================================================
# SUMMARY DASHBOARD
# =============================================================================
echo ""

if [[ "$TERM_IS_TTY" == "true" ]]; then
    # Colored summary boxes
    echo -e "  ${BOLD}Results Summary:${NC}"
    echo ""

    # Three big boxes side by side (PASS / WARN / FAIL)

    # PASS box
    echo -e "  ${GREEN}╔══════════════════╗${NC}   ${YELLOW}╔══════════════════╗${NC}   ${RED}╔══════════════════╗${NC}"
    printf "  ${GREEN}║${NC}  ${BOLD}%-14s${NC} ${GREEN}║${NC}   " "PASSED"
    printf "${YELLOW}║${NC}  ${BOLD}%-14s${NC} ${YELLOW}║${NC}   " "WARNINGS"
    printf "${RED}║${NC}  ${BOLD}%-14s${NC} ${RED}║${NC}\n" "FAILED"
    printf "  ${GREEN}║${NC}    ${BOLD}${GREEN}%02d${NC}          ${GREEN}║${NC}   " "$PASSED"
    printf "${YELLOW}║${NC}    ${BOLD}${YELLOW}%02d${NC}          ${YELLOW}║${NC}   " "$WARNINGS"
    printf "${RED}║${NC}    ${BOLD}${RED}%02d${NC}          ${RED}║${NC}\n" "$FAILED"
    echo -e "  ${GREEN}╚══════════════════╝${NC}   ${YELLOW}╚══════════════════╝${NC}   ${RED}╚══════════════════╝${NC}"
    echo ""

    # Overall status
    if [[ $FAILED -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        # ALL PASSED — trophy celebration
        echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${GREEN}${BOLD}║${NC}  ${BOLD}✅  ALL CHECKS PASSED  (${PASSED}/${TOTAL})${NC}                           ${GREEN}${BOLD}║${NC}"
        echo -e "  ${GREEN}${BOLD}║${NC}                                                          ${GREEN}${BOLD}║${NC}"
        echo -e "  ${GREEN}${BOLD}║${NC}      ${YELLOW}████████████████████████████████████████████${NC}      ${GREEN}${BOLD}║${NC}"
        echo -e "  ${GREEN}${BOLD}║${NC}      ${YELLOW}██${NC}  ${BOLD}🎉  Everything is perfect!  🎉${NC}  ${YELLOW}██${NC}      ${GREEN}${BOLD}║${NC}"
        echo -e "  ${GREEN}${BOLD}║${NC}      ${YELLOW}████████████████████████████████████████████${NC}      ${GREEN}${BOLD}║${NC}"
        echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${GREEN}  🏆  Your Firecrawl installation is healthy and ready!${NC}"
    elif [[ $FAILED -eq 0 ]]; then
        # WARNINGS but no failures
        echo -e "  ${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${YELLOW}${BOLD}║${NC}  ${BOLD}⚠️  CHECKS PASSED WITH WARNINGS  (${PASSED}/${TOTAL})${NC}                     ${YELLOW}${BOLD}║${NC}"
        echo -e "  ${YELLOW}${BOLD}║${NC}  ${DIM}Review ${WARNINGS} warning(s) above to ensure optimal operation${NC}       ${YELLOW}${BOLD}║${NC}"
        echo -e "  ${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${YELLOW}  😐  Running, but ${WARNINGS} warning(s) to address.${NC}"
    else
        # FAILURES
        echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${RED}${BOLD}║${NC}  ${BOLD}💥  ${FAILED} CHECK(S) FAILED  (${PASSED}/${TOTAL} passed)${NC}                        ${RED}${BOLD}║${NC}"
        echo -e "  ${RED}${BOLD}║${NC}  ${DIM}Review the failed checks above and fix the issues${NC}             ${RED}${BOLD}║${NC}"
        echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${RED}  💥  Detected ${FAILED} error(s) — check details above.${NC}"
    fi
else
    # Plain text summary
    echo "  ─────────────────────────────"
    echo "  Results: ${PASSED} passed, ${WARNINGS} warnings, ${FAILED} failed (${TOTAL} total)"
    echo "  ─────────────────────────────"
    echo ""

    if [[ $FAILED -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        echo "  🎉 All checks passed! Everything is perfect!"
    elif [[ $FAILED -eq 0 ]]; then
        echo "  😐 Running, but there are warnings to address."
    else
        echo "  💥 Detected ${FAILED} error(s) — check details above."
    fi
fi

echo ""

# JSON output
if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "{"
    echo "  \"summary\": {"
    echo "    \"passed\": ${PASSED},"
    echo "    \"warnings\": ${WARNINGS},"
    echo "    \"failed\": ${FAILED},"
    echo "    \"total\": ${TOTAL}"
    echo "  },"
    echo "  \"results\": [${JSON_RESULTS}]"
    echo "}"
    exit 0
fi

# Exit with appropriate code
if [[ $FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
