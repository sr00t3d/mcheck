#!/usr/bin/env bash
# ==============================================================================
#  mcheck.sh — DNSBL / RBL Reputation & Custom Mail Gateway Monitor CLI
# ==============================================================================
#  Author  : Percio Castelo (Percio Andrade) <percio@perciocastelo.com.br>
#  Website : https://perciocastelo.com.br
#  Project : https://perciocastelo.com.br/projetos/en/mcheck.html
#  Repo    : https://github.com/sr00t3d/mcheck
#  License : Apache-2.0
#  Version : 2.0.0
# ==============================================================================

set -uo pipefail

readonly SCRIPT_NAME="mcheck.sh"
readonly SCRIPT_VERSION="2.0.0"

# Verified active 2026 IPv4 DNSBLs (obsolete zones like SORBS/APEWS/Manitu removed)
DEFAULT_RBLS=(
  "zen.spamhaus.org"
  "cbl.abuseat.org"
  "b.barracudacentral.org"
  "bl.spamcop.net"
  "psbl.surriel.com"
  "dnsbl-1.uceprotect.net"
  "dnsbl-2.uceprotect.net"
  "dnsbl-3.uceprotect.net"
  "bl.mailspike.net"
  "z.mailspike.net"
  "ips.backscatterer.org"
  "all.s5h.net"
  "bl.0spam.org"
  "rbl.interserver.net"
  "bl.blocklist.de"
  "bl.nordspam.com"
)

# Runtime options
ACTION=""
TARGET_INPUT=""
GATEWAYS_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/mcheck/gateways.conf"
RBL_FILE=""
DNS_RESOLVER=""
TIMEOUT_SEC=2
ONLY_LISTED=0
EXIT_CODE_MODE=0
FORMAT="table"
QUIET=0
NO_COLOR=0
GW_ARG=""

# State
TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
declare -a RBLS=()
declare -a RESULTS=()      # 0x1f-delimited: label|ip|rbl|state|return_code
TOTAL_CHECKS=0
LISTED_COUNT=0
BLOCKED_COUNT=0
CLEAN_COUNT=0
ERROR_COUNT=0

# Colors
RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
OK="[OK]" ATT="[!]" FAIL="[ERR]"

init_colors() {
  if [[ "$NO_COLOR" -eq 0 && -t 1 && -z "${NO_COLOR:-}" && "$FORMAT" == "table" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
    OK="${GREEN}[OK]${RESET}"
    ATT="${YELLOW}[!]${RESET}"
    FAIL="${RED}[ERR]${RESET}"
  else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
    OK="[OK]" ATT="[!]" FAIL="[ERR]"
  fi
}

show_help() {
  cat <<'USAGE'
mcheck.sh v2.0.0 — DNSBL / RBL Reputation & Custom Mail Gateway Monitor CLI

Usage:
  mcheck.sh -i <ip-or-domain> [options]
  mcheck.sh -m | --my-ip [options]
  mcheck.sh -g | --check-gateways [--gateways-file <path>] [options]
  mcheck.sh --add-gateway <host-or-ip>
  mcheck.sh --remove-gateway <host-or-ip>
  mcheck.sh --list-gateways

Actions:
  -i, --ip <ip|domain>       Check an IPv4 address or domain (resolves A/MX records) against active DNSBLs
  -m, --my-ip                Check the current host's public egress IPv4
  -g, --check-gateways       Check all registered custom gateways against active DNSBLs
  --add-gateway <host|ip>    Register a custom SMTP gateway in gateways.conf
  --remove-gateway <host|ip> Remove a custom SMTP gateway from gateways.conf
  --list-gateways            List all registered custom gateways

Options:
  --gateways-file <path>     Custom gateways file (default: ~/.config/mcheck/gateways.conf)
  --rbl-file <path>          Custom DNSBL list file (one zone per line)
  --resolver <ip>            Custom DNS resolver (recommended for Spamhaus non-public queries)
  --timeout <sec>            DNS query timeout per RBL in seconds (default: 2)
  --only-listed              Show only LISTED / QUERY_BLOCKED hits in table output
  --exit-code                Exit with code 2 if any IP is LISTED on any DNSBL (ideal for cron/NOC)
  -o, --output <fmt>         Output format: table (default), json, csv
  -q, --quiet                Suppress banner header
  --no-color                 Disable ANSI colors
  -V, --version              Show version and exit
  -h, --help                 Show this help and exit

Examples:
  mcheck.sh -i 1.1.1.1
  mcheck.sh -i 127.0.0.2 --only-listed --exit-code
  mcheck.sh -m -o json
  mcheck.sh --add-gateway relay01.example.com
  mcheck.sh --check-gateways -o csv
USAGE
}

need_cmd() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf '[ERR] Missing required command: %s\n' "$cmd" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

reverse_ipv4() {
  local ip="$1"
  awk -F. '{printf "%s.%s.%s.%s", $4, $3, $2, $1}' <<<"$ip"
}

load_rbls() {
  if [[ -n "$RBL_FILE" ]]; then
    [[ -r "$RBL_FILE" ]] || { printf '%s Cannot read --rbl-file: %s\n' "$FAIL" "$RBL_FILE" >&2; exit 1; }
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ -z "$line" ]] && continue
      RBLS+=("$line")
    done < "$RBL_FILE"
  else
    RBLS=("${DEFAULT_RBLS[@]}")
  fi
}

resolve_to_ipv4s() {
  local target="$1"
  if is_ipv4 "$target"; then
    printf '%s\n' "$target"
    return 0
  fi
  local ips=""
  ips="$(dig +time="$TIMEOUT_SEC" +tries=1 +short A "$target" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u || true)"
  if [[ -z "$ips" ]]; then
    # Try MX hosts if bare domain has no A record
    local mx_host
    while IFS= read -r mx_host; do
      [[ -z "$mx_host" ]] && continue
      ips+=$'\n'"$(dig +time="$TIMEOUT_SEC" +tries=1 +short A "$mx_host" 2>/dev/null | grep -E '^[0-9.]+$' || true)"
    done < <(dig +time="$TIMEOUT_SEC" +tries=1 +short MX "$target" 2>/dev/null | awk '{print $2}' | sed 's/\.$//' || true)
    ips="$(printf '%s\n' "$ips" | grep -E '^[0-9.]+$' | sort -u || true)"
  fi
  printf '%s\n' "$ips"
}

check_ip_against_rbls() {
  local label="$1" ip="$2"
  local rev rbl query ans state code
  rev="$(reverse_ipv4 "$ip")"

  local -a dig_extra=()
  [[ -n "$DNS_RESOLVER" ]] && dig_extra=("@${DNS_RESOLVER}")

  for rbl in "${RBLS[@]}"; do
    query="${rev}.${rbl}"
    ans="$(dig +time="$TIMEOUT_SEC" +tries=1 +short A "$query" "${dig_extra[@]}" 2>/dev/null || true)"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if printf '%s' "$ans" | grep -q ';;'; then
      state="TIMEOUT"
      code=""
      ERROR_COUNT=$((ERROR_COUNT + 1))
    elif [[ -z "$ans" ]]; then
      state="CLEAN"
      code=""
      CLEAN_COUNT=$((CLEAN_COUNT + 1))
    else
      code="$(printf '%s\n' "$ans" | grep -E '^127\.' | head -n1 || true)"
      if [[ -z "$code" ]]; then
        state="CLEAN"
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
      elif [[ "$code" =~ ^127\.255\.255\. ]]; then
        # Spamhaus / CBL open-resolver query error codes (not an actual listing)
        state="QUERY_BLOCKED"
        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
      else
        state="LISTED"
        LISTED_COUNT=$((LISTED_COUNT + 1))
      fi
    fi

    RESULTS+=("${label}"$'\x1f'"${ip}"$'\x1f'"${rbl}"$'\x1f'"${state}"$'\x1f'"${code}")
  done
}

action_add_gateway() {
  local gw="$GW_ARG"
  gw="$(printf '%s' "$gw" | tr -d '[:space:]')"
  gw="${gw,,}"
  if [[ -z "$gw" ]] || ! printf '%s' "$gw" | grep -Eq '^[a-z0-9][a-z0-9.-]+$'; then
    printf '%s Invalid gateway host or IP: %s\n' "$FAIL" "${gw:-<empty>}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$GATEWAYS_FILE")"
  touch "$GATEWAYS_FILE"
  chmod 600 "$GATEWAYS_FILE"
  if grep -Fxq "$gw" "$GATEWAYS_FILE" 2>/dev/null; then
    printf '%s Gateway already registered: %s (%s)\n' "$ATT" "$gw" "$GATEWAYS_FILE"
    return 0
  fi
  printf '%s\n' "$gw" >> "$GATEWAYS_FILE"
  printf '%s Added custom gateway: %s -> %s\n' "$OK" "$gw" "$GATEWAYS_FILE"
}

action_remove_gateway() {
  local gw="$GW_ARG"
  gw="$(printf '%s' "$gw" | tr -d '[:space:]')"
  gw="${gw,,}"
  if [[ ! -f "$GATEWAYS_FILE" ]]; then
    printf '%s Gateways file not found: %s\n' "$ATT" "$GATEWAYS_FILE"
    return 0
  fi
  local tmpf
  tmpf="$(mktemp)"
  grep -Fxv "$gw" "$GATEWAYS_FILE" > "$tmpf" || true
  cat "$tmpf" > "$GATEWAYS_FILE"
  rm -f "$tmpf"
  printf '%s Removed custom gateway: %s (from %s)\n' "$OK" "$gw" "$GATEWAYS_FILE"
}

action_list_gateways() {
  if [[ ! -r "$GATEWAYS_FILE" ]]; then
    printf '%s No custom gateways configured yet (%s). Add one with: %s --add-gateway <host|ip>\n' "$ATT" "$GATEWAYS_FILE" "$SCRIPT_NAME"
    return 0
  fi
  local count=0 line
  printf 'Custom Gateways (%s):\n' "$GATEWAYS_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue
    count=$((count + 1))
    printf '  %2d. %s\n' "$count" "$line"
  done < "$GATEWAYS_FILE"
  [[ "$count" -eq 0 ]] && printf '  (empty)\n'
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

csv_escape() {
  local s="$1"
  s="${s//$'\n'/ ; }"
  s="${s//$'\r'/}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

render_output() {
  local row label ip rbl state code
  case "$FORMAT" in
    json)
      local items="" first=1
      for row in "${RESULTS[@]}"; do
        IFS=$'\x1f' read -r label ip rbl state code <<<"$row"
        [[ "$ONLY_LISTED" -eq 1 && "$state" == "CLEAN" ]] && continue
        [[ "$first" -eq 0 ]] && items+=","
        first=0
        items+="{\"target\":\"$(json_escape "$label")\",\"ip\":\"$(json_escape "$ip")\",\"rbl\":\"$(json_escape "$rbl")\",\"state\":\"$(json_escape "$state")\",\"code\":\"$(json_escape "$code")\"}"
      done
      cat <<EOF
{
  "tool": "${SCRIPT_NAME}",
  "version": "${SCRIPT_VERSION}",
  "timestamp": "$(json_escape "$TIMESTAMP_UTC")",
  "rbls_checked": ${#RBLS[@]},
  "total_checks": ${TOTAL_CHECKS},
  "clean": ${CLEAN_COUNT},
  "listed": ${LISTED_COUNT},
  "query_blocked": ${BLOCKED_COUNT},
  "timeouts": ${ERROR_COUNT},
  "results": [${items}]
}
EOF
      ;;
    csv)
      printf 'target,ip,rbl,state,return_code\n'
      for row in "${RESULTS[@]}"; do
        IFS=$'\x1f' read -r label ip rbl state code <<<"$row"
        [[ "$ONLY_LISTED" -eq 1 && "$state" == "CLEAN" ]] && continue
        printf '%s,%s,%s,%s,%s\n' \
          "$(csv_escape "$label")" "$(csv_escape "$ip")" "$(csv_escape "$rbl")" \
          "$(csv_escape "$state")" "$(csv_escape "$code")"
      done
      ;;
    table)
      if [[ "$QUIET" -eq 0 ]]; then
        printf '%s================================================================================%s\n' "$CYAN" "$RESET"
        printf ' %s%s v%s%s | DNSBL Reputation Audit (%d RBLs) | %s\n' "$BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$RESET" "${#RBLS[@]}" "$TIMESTAMP_UTC"
        printf '%s================================================================================%s\n' "$CYAN" "$RESET"
        printf '%-22s %-15s %-26s %-14s %s\n' "TARGET" "IP" "DNSBL" "STATE" "CODE"
        printf '%-22s %-15s %-26s %-14s %s\n' "----------------------" "---------------" "--------------------------" "--------------" "---------------"
      fi
      for row in "${RESULTS[@]}"; do
        IFS=$'\x1f' read -r label ip rbl state code <<<"$row"
        [[ "$ONLY_LISTED" -eq 1 && "$state" == "CLEAN" ]] && continue
        local color=""
        case "$state" in
          CLEAN)         color="$GREEN" ;;
          LISTED)        color="$RED" ;;
          QUERY_BLOCKED|TIMEOUT) color="$YELLOW" ;;
        esac
        printf '%-22s %-15s %-26s %s%-14s%s %s\n' "$label" "$ip" "$rbl" "$color" "$state" "$RESET" "${code:--}"
      done
      if [[ "$QUIET" -eq 0 ]]; then
        printf '\nSummary: %d checks | %d CLEAN | %d LISTED | %d QUERY_BLOCKED | %d TIMEOUT\n' \
          "$TOTAL_CHECKS" "$CLEAN_COUNT" "$LISTED_COUNT" "$BLOCKED_COUNT" "$ERROR_COUNT"
      fi
      ;;
  esac
}

main() {
  need_cmd dig awk grep sort tr

  [[ "$#" -eq 0 ]] && { show_help; exit 1; }

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h|--help)            show_help; exit 0 ;;
      -V|--version)         printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      -i|--ip|-ip)          ACTION="ip"; TARGET_INPUT="${2:-}"; shift 2 ;;
      -m|--my-ip|-myip)     ACTION="myip"; shift ;;
      -g|--check-gateways|-gateway|-a|--all) ACTION="gateways"; shift ;;
      --add-gateway)        ACTION="add-gw"; GW_ARG="${2:-}"; shift 2 ;;
      --remove-gateway)     ACTION="remove-gw"; GW_ARG="${2:-}"; shift 2 ;;
      --list-gateways)      ACTION="list-gw"; shift ;;
      --gateways-file)      GATEWAYS_FILE="${2:-$GATEWAYS_FILE}"; shift 2 ;;
      --rbl-file)           RBL_FILE="${2:-}"; shift 2 ;;
      --resolver)           DNS_RESOLVER="${2:-}"; shift 2 ;;
      --timeout)            TIMEOUT_SEC="${2:-2}"; shift 2 ;;
      --only-listed)        ONLY_LISTED=1; shift ;;
      --exit-code)          EXIT_CODE_MODE=1; shift ;;
      -q|--quiet)           QUIET=1; shift ;;
      --no-color)           NO_COLOR=1; shift ;;
      -o|--output)          FORMAT="${2:-table}"; shift 2 ;;
      --output=*)           FORMAT="${1#*=}"; shift ;;
      --*)                  printf '[ERR] Unknown option: %s (use -h for help)\n' "$1" >&2; exit 1 ;;
      *)
        if [[ -z "$ACTION" ]]; then
          ACTION="ip"; TARGET_INPUT="$1"; shift
        else
          printf '[ERR] Unexpected argument: %s\n' "$1" >&2; exit 1
        fi ;;
    esac
  done

  case "$FORMAT" in
    table|json|csv) ;;
    *) printf '[ERR] Invalid output format: %s (expected table, json, or csv)\n' "$FORMAT" >&2; exit 1 ;;
  esac

  init_colors

  case "$ACTION" in
    add-gw)    action_add_gateway; exit 0 ;;
    remove-gw) action_remove_gateway; exit 0 ;;
    list-gw)   action_list_gateways; exit 0 ;;
  esac

  load_rbls

  case "$ACTION" in
    ip)
      [[ -n "$TARGET_INPUT" ]] || { printf '%s Missing IP or domain for -i.\n' "$FAIL" >&2; exit 1; }
      local ip_list ip
      ip_list="$(resolve_to_ipv4s "$TARGET_INPUT")"
      [[ -n "$ip_list" ]] || { printf '%s Could not resolve IPv4 for %s\n' "$FAIL" "$TARGET_INPUT" >&2; exit 1; }
      while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        check_ip_against_rbls "$TARGET_INPUT" "$ip"
      done <<<"$ip_list"
      ;;
    myip)
      need_cmd curl
      local myip
      myip="$(curl -fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --connect-timeout 4 --max-time 8 https://ifconfig.me 2>/dev/null || true)"
      myip="$(printf '%s' "$myip" | tr -d '[:space:]')"
      is_ipv4 "$myip" || { printf '%s Could not obtain public IPv4.\n' "$FAIL" >&2; exit 1; }
      check_ip_against_rbls "self" "$myip"
      ;;
    gateways)
      if [[ ! -r "$GATEWAYS_FILE" ]]; then
        printf '%s No custom gateways file found at %s. Register gateways with: %s --add-gateway <host|ip>\n' "$FAIL" "$GATEWAYS_FILE" "$SCRIPT_NAME" >&2
        exit 1
      fi
      local gw ip_list ip found_any=0
      while IFS= read -r gw || [[ -n "$gw" ]]; do
        gw="${gw%$'\r'}"
        gw="${gw%%#*}"
        gw="$(printf '%s' "$gw" | tr -d '[:space:]')"
        [[ -z "$gw" ]] && continue
        found_any=1
        ip_list="$(resolve_to_ipv4s "$gw")"
        if [[ -z "$ip_list" ]]; then
          printf '%s Could not resolve gateway: %s\n' "$ATT" "$gw" >&2
          continue
        fi
        while IFS= read -r ip; do
          [[ -z "$ip" ]] && continue
          check_ip_against_rbls "$gw" "$ip"
        done <<<"$ip_list"
      done < "$GATEWAYS_FILE"
      [[ "$found_any" -eq 1 ]] || { printf '%s Gateways file %s is empty.\n' "$FAIL" "$GATEWAYS_FILE" >&2; exit 1; }
      ;;
    *)
      printf '%s No action specified. Use -h for help.\n' "$FAIL" >&2
      exit 1 ;;
  esac

  render_output

  if [[ "$EXIT_CODE_MODE" -eq 1 && "$LISTED_COUNT" -gt 0 ]]; then
    exit 2
  fi
  exit 0
}

main "$@"
