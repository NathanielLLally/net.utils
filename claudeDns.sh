#!/usr/bin/env bash
# cf-dns-update.sh — Cloudflare DNS record updater
# Usage: ./cf-dns-update.sh [OPTIONS]
# Requires: curl, jq

set -euo pipefail

# ─── Config (override via env or flags) ───────────────────────────────────────
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
RECORD_NAME="${RECORD_NAME:-}"
RECORD_TYPE="${RECORD_TYPE:-A}"
RECORD_CONTENT="${RECORD_CONTENT:-}"
RECORD_TTL="${RECORD_TTL:-1}"          # 1 = auto
RECORD_PROXIED="${RECORD_PROXIED:-false}"
AUTO_IP="${AUTO_IP:-false}"            # auto-detect public IP

CF_API="https://api.cloudflare.com/client/v4"

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }
need() { command -v "$1" &>/dev/null || err "'$1' is required but not installed."; }

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

usage() {
  cat <<EOF
Usage: CF_API_TOKEN=<token> CF_ACCOUNT_ID=<account> $0 [OPTIONS]

Options:
  -n, --name        <name>       Record name (e.g. sub.example.com)      [required for DNS ops]
  -t, --type        <type>       Record type: A, AAAA, CNAME, TXT, MX... [default: A]
  -c, --content     <value>      Record content / IP / target             [required unless --auto-ip]
  -z, --zone        <zone_id>    Zone ID (overrides CF_ZONE_ID env)
  -a, --account     <account_id> Account ID (overrides CF_ACCOUNT_ID env)
  -k, --token       <api_token>  API token (overrides CF_API_TOKEN env)
  --ttl             <seconds>    TTL in seconds (1 = auto)                [default: 1]
  --proxied                      Enable Cloudflare proxy (orange cloud)
  --auto-ip                      Use current public IP as content (A records)
  --list-zones                   List all zones in the account
  --list                         List all DNS records for the zone
  --delete                       Delete the matching record instead
  -h, --help                     Show this help

Environment variables:
  CF_API_TOKEN    Cloudflare API token with DNS edit permissions
  CF_ACCOUNT_ID   Account ID from the Cloudflare dashboard
  CF_ZONE_ID      Zone ID (optional if using --list-zones to find it)
  RECORD_NAME     Equivalent to --name
  RECORD_TYPE     Equivalent to --type
  RECORD_CONTENT  Equivalent to --content
  RECORD_TTL      Equivalent to --ttl
  RECORD_PROXIED  Set to 'true' to enable proxy

Examples:
  # List all zones in account
  CF_API_TOKEN=abc CF_ACCOUNT_ID=xyz ./cf-dns-update.sh --list-zones

  # List DNS records for a zone
  ./cf-dns-update.sh --list -z <zone_id>

  # Dynamic DNS — update A record to current public IP
  ./cf-dns-update.sh -n home.example.com -z <zone_id> --auto-ip

  # Set a CNAME with proxy
  ./cf-dns-update.sh -n www.example.com -t CNAME -c example.com -z <zone_id> --proxied

  # Set a TXT record
  ./cf-dns-update.sh -n _dmarc.example.com -t TXT -c "v=DMARC1; p=none" -z <zone_id>

  # Delete a record
  ./cf-dns-update.sh -n old.example.com -t A -z <zone_id> --delete
EOF
  exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
ACTION="upsert"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)        RECORD_NAME="$2";    shift 2 ;;
    -t|--type)        RECORD_TYPE="$2";    shift 2 ;;
    -c|--content)     RECORD_CONTENT="$2"; shift 2 ;;
    -z|--zone)        CF_ZONE_ID="$2";     shift 2 ;;
    -a|--account)     CF_ACCOUNT_ID="$2";  shift 2 ;;
    -k|--token)       CF_API_TOKEN="$2";   shift 2 ;;
    --ttl)            RECORD_TTL="$2";     shift 2 ;;
    --proxied)        RECORD_PROXIED=true; shift ;;
    --auto-ip)        AUTO_IP=true;        shift ;;
    --delete)         ACTION="delete";     shift ;;
    --list)           ACTION="list";       shift ;;
    --list-zones)     ACTION="list-zones"; shift ;;
    -h|--help)        usage ;;
    *) err "Unknown option: $1" ;;
  esac
done

# ─── Preflight ────────────────────────────────────────────────────────────────
need curl
need jq

[[ -z "$CF_API_TOKEN" ]] && err "CF_API_TOKEN is not set. Use --token or export CF_API_TOKEN=..."

cf_curl() {
  curl -sf \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

check_response() {
  local resp="$1" context="${2:-API call}"
  local ok; ok=$(echo "$resp" | jq -r '.success')
  if [[ "$ok" != "true" ]]; then
    err "$context failed: $(echo "$resp" | jq -r '[.errors[].message] | join(", ")')"
  fi
}

# ─── Actions ──────────────────────────────────────────────────────────────────

list_zones() {
  [[ -z "$CF_ACCOUNT_ID" ]] && err "CF_ACCOUNT_ID is not set. Use --account or export CF_ACCOUNT_ID=..."

  log "Fetching zones for account $CF_ACCOUNT_ID ..."
  local page=1 total_pages=1

  # Print header
  printf "%-40s %-36s %-10s %s\n" "NAME" "ZONE ID" "STATUS" "PLAN"
  printf '%0.s─' {1..100}; echo

  while [[ $page -le $total_pages ]]; do
    local resp
    resp=$(cf_curl "$CF_API/zones?account.id=$CF_ACCOUNT_ID&per_page=50&page=$page")
    check_response "$resp" "list zones"

    total_pages=$(echo "$resp" | jq -r '.result_info.total_pages')

    echo "$resp" | jq -r \
      '.result[] | [.name, .id, .status, .plan.name] | @tsv' \
    | while IFS=$'\t' read -r name id status plan; do
        printf "%-40s %-36s %-10s %s\n" "$name" "$id" "$status" "$plan"
      done

    (( page++ ))
  done
}

list_records() {
  [[ -z "$CF_ZONE_ID" ]] && err "CF_ZONE_ID is not set. Use --zone or --list-zones to find it."

  log "Fetching DNS records for zone $CF_ZONE_ID ..."
  local page=1 total_pages=1

  printf "%-8s %-45s %-50s %-6s %-8s %s\n" "TYPE" "NAME" "CONTENT" "TTL" "PROXIED" "ID"
  printf '%0.s─' {1..100}; echo

  while [[ $page -le $total_pages ]]; do
    local resp
    resp=$(cf_curl "$CF_API/zones/$CF_ZONE_ID/dns_records?per_page=100&page=$page")
    check_response "$resp" "list records"

    total_pages=$(echo "$resp" | jq -r '.result_info.total_pages')

    echo "$resp" | jq -r \
      '.result[] | [.type, .name, .content, (.ttl|tostring), (.proxied|tostring), .id] | @tsv' \
    | while IFS=$'\t' read -r type name content ttl proxied id; do
        printf "%-8s %-45s %-50s %-6s %-8s %s\n" "$type" "$name" "$content" "$ttl" "$proxied" "$id"
      done

    (( page++ ))
  done
}

get_record_id() {
  local name="$1" type="$2"
  cf_curl "$CF_API/zones/$CF_ZONE_ID/dns_records?name=$(urlencode "$name")&type=$type" \
    | jq -r '.result[0].id // empty'
}

upsert_record() {
  [[ -z "$CF_ZONE_ID"   ]] && err "CF_ZONE_ID is not set. Use --zone or --list-zones to find it."
  [[ -z "$RECORD_NAME"  ]] && err "--name is required"

  # Auto-detect public IP
  if [[ "$AUTO_IP" == "true" ]]; then
    log "Detecting public IP..."
    RECORD_CONTENT=$(curl -sf https://api.ipify.org || curl -sf https://ifconfig.me)
    [[ -z "$RECORD_CONTENT" ]] && err "Could not detect public IP"
    log "Public IP: $RECORD_CONTENT"
  fi

  [[ -z "$RECORD_CONTENT" ]] && err "--content is required (or use --auto-ip for A records)"

  local payload
  payload=$(jq -n \
    --arg type    "$RECORD_TYPE" \
    --arg name    "$RECORD_NAME" \
    --arg content "$RECORD_CONTENT" \
    --argjson ttl     "$RECORD_TTL" \
    --argjson proxied "$RECORD_PROXIED" \
    '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')

  local record_id
  record_id=$(get_record_id "$RECORD_NAME" "$RECORD_TYPE")

  local resp method url
  if [[ -n "$record_id" ]]; then
    log "Updating existing record $record_id ($RECORD_TYPE $RECORD_NAME → $RECORD_CONTENT) ..."
    method="PUT"
    url="$CF_API/zones/$CF_ZONE_ID/dns_records/$record_id"
  else
    log "Creating new record ($RECORD_TYPE $RECORD_NAME → $RECORD_CONTENT) ..."
    method="POST"
    url="$CF_API/zones/$CF_ZONE_ID/dns_records"
  fi

  resp=$(cf_curl -X "$method" "$url" -d "$payload")
  check_response "$resp" "upsert record"

  local id name content
  id=$(echo "$resp"      | jq -r '.result.id')
  name=$(echo "$resp"    | jq -r '.result.name')
  content=$(echo "$resp" | jq -r '.result.content')
  log "Done. Record ID: $id | $name → $content"
}

delete_record() {
  [[ -z "$CF_ZONE_ID"   ]] && err "CF_ZONE_ID is not set. Use --zone or --list-zones to find it."
  [[ -z "$RECORD_NAME"  ]] && err "--name is required for --delete"

  local record_id
  record_id=$(get_record_id "$RECORD_NAME" "$RECORD_TYPE")
  [[ -z "$record_id" ]] && err "No $RECORD_TYPE record found for $RECORD_NAME"

  log "Deleting record $record_id ($RECORD_TYPE $RECORD_NAME) ..."
  local resp
  resp=$(cf_curl -X DELETE "$CF_API/zones/$CF_ZONE_ID/dns_records/$record_id")
  check_response "$resp" "delete record"
  log "Deleted."
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
case "$ACTION" in
  list-zones) list_zones   ;;
  list)       list_records ;;
  delete)     delete_record ;;
  upsert)     upsert_record ;;
esac
