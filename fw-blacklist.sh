#!/usr/bin/env bash
# fw-blacklist.sh — Temporary IP blacklist utility using ipset + iptables
# Usage: fw-blacklist <command> [options]
# Requires: ipset, iptables, ss/netstat, tc (iproute2), root

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SETNAME="blacklist"
CHAIN="FW_BLACKLIST"
#DEFAULT_TTL=3600          # seconds (1 hour)
DEFAULT_TTL=300          # seconds (5 mins)
STATE_DIR="/var/lib/fw-blacklist"
LOG_TAG="fw-blacklist"
BANDWIDTH_THRESHOLD=10    # MB/s per IP to trigger bandwidth block
CONN_THRESHOLD=40         # simultaneous connections per IP to trigger block
RATE_THRESHOLD="50/s"    # iptables hashlimit — packets/sec per IP
MONITOR_INTERVAL=10       # seconds between auto-monitor sweeps

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
require_root() { [[ $EUID -eq 0 ]] || { echo -e "${RED}Must run as root${RST}"; exit 1; }; }
log()  { logger -t "$LOG_TAG" "$*"; echo -e "${CYN}[$(date '+%H:%M:%S')]${RST} $*"; }
warn() { logger -t "$LOG_TAG" "WARN: $*"; echo -e "${YEL}[WARN]${RST} $*"; }
die()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }

setup_state_dir() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/expiry.db"  # format: IP UNBLOCK_EPOCH REASON
}

# ── ipset / iptables init ─────────────────────────────────────────────────────
init_firewall() {
    require_root
    setup_state_dir

    # Create ipset if missing
    if ! ipset list "$SETNAME" &>/dev/null; then
        ipset create "$SETNAME" hash:ip hashsize 4096 timeout 0
        log "Created ipset '$SETNAME'"
    fi

    # Create dedicated iptables chain
    if ! iptables -n -L "$CHAIN" &>/dev/null 2>&1; then
        iptables -N "$CHAIN"
        iptables -A "$CHAIN" -m set --match-set "$SETNAME" src \
            -m limit --limit 5/min \
            -j LOG --log-prefix "FW-BLACKLIST DROP: " --log-level 6
        iptables -A "$CHAIN" -m set --match-set "$SETNAME" src -j DROP
        log "Created iptables chain '$CHAIN'"
    fi

    # Hook chain into INPUT and FORWARD if not already hooked
    for tgt in INPUT FORWARD; do
        if ! iptables -C "$tgt" -j "$CHAIN" 2>/dev/null; then
            iptables -I "$tgt" 1 -j "$CHAIN"
            log "Hooked $CHAIN into $tgt"
        fi
    done

    # Rate-limit chain (separate, for auto-block on packet flood)
    if ! iptables -n -L FW_RATELIMIT &>/dev/null 2>&1; then
        iptables -N FW_RATELIMIT
        iptables -A FW_RATELIMIT \
            -m hashlimit --hashlimit-name fwrl \
            --hashlimit-above "$RATE_THRESHOLD" \
            --hashlimit-mode srcip \
            --hashlimit-burst 200 \
            -j SET --add-set "$SETNAME" src --exist
        for tgt in INPUT FORWARD; do
            iptables -I "$tgt" 2 -j FW_RATELIMIT
        done
        log "Rate-limit auto-block chain active (>${RATE_THRESHOLD} pps → blacklist)"
    fi

    echo -e "${GRN}Firewall blacklist initialized.${RST}"
}

teardown_firewall() {
    require_root
    for tgt in INPUT FORWARD; do
        iptables -D "$tgt" -j "$CHAIN" 2>/dev/null || true
        iptables -D "$tgt" -j FW_RATELIMIT 2>/dev/null || true
    done
    iptables -F "$CHAIN" 2>/dev/null || true;  iptables -X "$CHAIN" 2>/dev/null || true
    iptables -F FW_RATELIMIT 2>/dev/null || true; iptables -X FW_RATELIMIT 2>/dev/null || true
    ipset destroy "$SETNAME" 2>/dev/null || true
    log "Firewall blacklist torn down."
}

# ── Block / Unblock ───────────────────────────────────────────────────────────
block_ip() {
    local ip="$1" ttl="${2:-$DEFAULT_TTL}" reason="${3:-manual}"
    require_root; init_firewall

    # Validate IP (v4 or CIDR)
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        die "Invalid IP/CIDR: $ip"
    fi

    local expires=$(( $(date +%s) + ttl ))
    ipset add "$SETNAME" "$ip" timeout "$ttl" 2>/dev/null || \
        ipset add "$SETNAME" "$ip" timeout "$ttl" -exist

    # Record in state db (remove old entry first)
    sed -i "/^${ip} /d" "$STATE_DIR/expiry.db"
    echo "$ip $expires $reason" >> "$STATE_DIR/expiry.db"

    log "BLOCKED $ip for ${ttl}s — reason: $reason"
    echo -e "${RED}✖ Blocked${RST} ${BLD}$ip${RST} for $(secs_human $ttl) [${reason}]"
}

unblock_ip() {
    local ip="$1"
    require_root
    ipset del "$SETNAME" "$ip" 2>/dev/null || warn "$ip not in blacklist"
    sed -i "/^${ip} /d" "$STATE_DIR/expiry.db"
    log "UNBLOCKED $ip"
    echo -e "${GRN}✔ Unblocked${RST} ${BLD}$ip${RST}"
}

# ── List / Status ─────────────────────────────────────────────────────────────
list_blocked() {
    echo -e "\n${BLD}${CYN}── Active Blacklist ─────────────────────────────────────────${RST}"
    local now; now=$(date +%s)
    local count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local ip expires reason remaining
        read -r ip expires reason <<< "$line"
        remaining=$(( expires - now ))
        [[ $remaining -le 0 ]] && continue
        printf "  ${RED}%-18s${RST}  expires in ${YEL}%-12s${RST}  reason: %s\n" \
            "$ip" "$(secs_human $remaining)" "$reason"
        (( count++ ))
    done < "$STATE_DIR/expiry.db"

    # Also show any ipset entries not in db (e.g. added by rate-limit chain)
    while IFS= read -r entry; do
        local ip ttl_left
        ip=$(echo "$entry" | awk '{print $1}')
        ttl_left=$(echo "$entry" | grep -oP 'timeout \K[0-9]+' || echo "?")
        grep -q "^$ip " "$STATE_DIR/expiry.db" && continue
        printf "  ${RED}%-18s${RST}  ttl: ${YEL}%-12s${RST}  reason: %s\n" \
            "$ip" "${ttl_left}s" "auto-rate-limit"
        (( count++ ))
    done < <(ipset list "$SETNAME" 2>/dev/null | grep -E '^[0-9]' || true)

    echo -e "${BLD}${CYN}────────────────────────────────────────────────────────────${RST}"
    echo -e "  Total: ${BLD}$count${RST} IP(s) blocked\n"
}

# ── Auto-detect bandwidth hogs ────────────────────────────────────────────────
detect_bandwidth_hogs() {
    # Uses /proc/net/nf_conntrack if available, falls back to ss
    require_root
    echo -e "\n${BLD}Scanning for bandwidth hogs (threshold: ${BANDWIDTH_THRESHOLD} MB/s)...${RST}"

    if command -v nftables &>/dev/null || [[ -f /proc/net/nf_conntrack ]]; then
        # Count bytes per src IP from conntrack
        declare -A ip_bytes
        while IFS= read -r line; do
            local src bytes
            src=$(echo "$line" | grep -oP 'src=\K[^ ]+' | head -1)
            bytes=$(echo "$line" | grep -oP 'bytes=\K[0-9]+' | head -1)
            [[ -z "$src" || -z "$bytes" ]] && continue
            ip_bytes[$src]=$(( ${ip_bytes[$src]:-0} + bytes ))
        done < /proc/net/nf_conntrack 2>/dev/null || true

        for ip in "${!ip_bytes[@]}"; do
            local mb=$(( ${ip_bytes[$ip]} / 1048576 ))
            if (( mb > BANDWIDTH_THRESHOLD )); then
                warn "Bandwidth hog detected: $ip — ${mb} MB in conntrack"
                block_ip "$ip" "$DEFAULT_TTL" "bandwidth-hog:${mb}MB"
            fi
        done
    fi

    # Connection count heuristic via ss
    echo -e "${CYN}Checking connection counts...${RST}"
    ss -tn state established 2>/dev/null \
        | awk 'NR>1 {print $5}' \
        | grep -oP '^\S+(?=:\d+$)' \
        | sort | uniq -c | sort -rn \
        | while read -r cnt ip; do
            if (( cnt > CONN_THRESHOLD )); then
                warn "Connection flood: $ip has $cnt simultaneous connections"
                block_ip "$ip" "$DEFAULT_TTL" "conn-flood:${cnt}conns"
            fi
        done

    echo -e "${GRN}Scan complete.${RST}"
}

# ── Monitor daemon ────────────────────────────────────────────────────────────
monitor_loop() {
    require_root
    log "Starting monitor loop (interval: ${MONITOR_INTERVAL}s)"
    echo -e "${GRN}Monitor running. Ctrl-C to stop. Logging to syslog ($LOG_TAG).${RST}"
    while true; do
        detect_bandwidth_hogs 2>&1 | grep -v "^$" || true
        purge_expired
        sleep "$MONITOR_INTERVAL"
    done
}

# ── Purge expired entries from state db ──────────────────────────────────────
purge_expired() {
    local now; now=$(date +%s)
    local tmp; tmp=$(mktemp)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local ip expires reason
        read -r ip expires reason <<< "$line"
        if (( expires > now )); then
            echo "$line"
        else
            log "Expiry purge: $ip"
        fi
    done < "$STATE_DIR/expiry.db" > "$tmp"
    mv "$tmp" "$STATE_DIR/expiry.db"
}

# ── Import / Export ───────────────────────────────────────────────────────────
import_list() {
    local file="$1" ttl="${2:-$DEFAULT_TTL}"
    [[ -f "$file" ]] || die "File not found: $file"
    local count=0
    while IFS= read -r line; do
        line="${line%%#*}"; line="${line// /}"  # strip comments/spaces
        [[ -z "$line" ]] && continue
        block_ip "$line" "$ttl" "bulk-import"
        (( count++ ))
    done < "$file"
    echo -e "${GRN}Imported $count IPs from $file${RST}"
}

export_list() {
    local out="${1:-/tmp/blacklist-$(date +%Y%m%d).txt}"
    ipset list "$SETNAME" | grep -E '^[0-9]' | awk '{print $1}' > "$out"
    echo -e "${GRN}Exported blacklist to $out${RST}"
}

# ── Utility ───────────────────────────────────────────────────────────────────
secs_human() {
    local s=$1
    if (( s >= 3600 )); then printf "%dh%02dm" $(( s/3600 )) $(( (s%3600)/60 ))
    elif (( s >= 60 )); then printf "%dm%02ds" $(( s/60 )) $(( s%60 ))
    else printf "%ds" "$s"; fi
}

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BLD}fw-blacklist${RST} — Temporary IP blacklist using ipset + iptables

${BLD}USAGE${RST}
  fw-blacklist <command> [args]

${BLD}COMMANDS${RST}
  ${CYN}init${RST}                        Set up ipset + iptables chains
  ${CYN}teardown${RST}                    Remove all chains and ipset (flush everything)

  ${CYN}block${RST} <ip> [ttl] [reason]   Block an IP (TTL in seconds, default: ${DEFAULT_TTL})
  ${CYN}unblock${RST} <ip>                Remove IP from blacklist immediately
  ${CYN}list${RST}                        Show all currently blocked IPs with TTL

  ${CYN}scan${RST}                        One-shot scan for bandwidth hogs & conn floods
  ${CYN}monitor${RST}                     Run continuous background monitor loop

  ${CYN}import${RST} <file> [ttl]         Bulk-block IPs from a newline-separated file
  ${CYN}export${RST} [outfile]            Dump current blacklist to a text file

  ${CYN}purge${RST}                       Clean expired entries from state DB

${BLD}EXAMPLES${RST}
  sudo fw-blacklist init
  sudo fw-blacklist block 203.0.113.42
  sudo fw-blacklist block 198.51.100.0/24 7200 "scraper"
  sudo fw-blacklist unblock 203.0.113.42
  sudo fw-blacklist list
  sudo fw-blacklist scan
  sudo fw-blacklist monitor
  sudo fw-blacklist import /etc/fw-blacklist/known-bad.txt 86400

${BLD}CONFIG${RST} (edit top of script)
  DEFAULT_TTL          $DEFAULT_TTL s   — default block duration
  BANDWIDTH_THRESHOLD  $BANDWIDTH_THRESHOLD MB/s — hog detection threshold
  CONN_THRESHOLD       $CONN_THRESHOLD conns — simultaneous connection limit
  RATE_THRESHOLD       $RATE_THRESHOLD    — iptables hashlimit pps trigger
  MONITOR_INTERVAL     $MONITOR_INTERVAL s  — scan frequency in monitor mode

${BLD}STATE${RST}
  Expiry DB: $STATE_DIR/expiry.db
  Logs:      journalctl -t $LOG_TAG

EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
cmd="${1:-help}"
case "$cmd" in
    init)       init_firewall ;;
    teardown)   teardown_firewall ;;
    block)      block_ip "${2:?IP required}" "${3:-$DEFAULT_TTL}" "${4:-manual}" ;;
    unblock)    unblock_ip "${2:?IP required}" ;;
    list)       list_blocked ;;
    scan)       detect_bandwidth_hogs ;;
    monitor)    monitor_loop ;;
    import)     import_list "${2:?File required}" "${3:-$DEFAULT_TTL}" ;;
    export)     export_list "${2:-}" ;;
    purge)      purge_expired; echo "Purged." ;;
    help|--help|-h) usage ;;
    *)          echo "Unknown command: $cmd"; usage; exit 1 ;;
esac
