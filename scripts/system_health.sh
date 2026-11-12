#!/usr/bin/env bash
#
# system_health.sh - lightweight Linux host health check.
#
# Collects CPU, memory, disk (all real filesystems), load average and the top 5 processes by
# memory; appends a timestamped entry to a log file (with size-based rotation); prints
# [WARNING]/[CRITICAL] lines when thresholds are exceeded and exits with a monitoring-friendly code.
#
# Exit codes (Nagios-style):
#   0 OK        all metrics below warning thresholds
#   1 WARNING   at least one metric above its warning threshold
#   2 CRITICAL  at least one metric above its critical threshold
#   3 UNKNOWN   usage error or the script could not collect metrics
#
set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="${0##*/}"

# ---------- defaults (override with flags or env) ----------
CPU_WARN="${HEALTH_CPU_WARN:-90}"
MEM_WARN="${HEALTH_MEM_WARN:-85}"
DISK_WARN="${HEALTH_DISK_WARN:-80}"
CPU_CRIT="${HEALTH_CPU_CRIT:-95}"
MEM_CRIT="${HEALTH_MEM_CRIT:-95}"
DISK_CRIT="${HEALTH_DISK_CRIT:-90}"
LOG_FILE="${HEALTH_LOG_FILE:-./health_log.txt}"
MAX_LOG_BYTES="${HEALTH_MAX_LOG_BYTES:-1048576}" # 1 MiB
KEEP_LOGS="${HEALTH_KEEP_LOGS:-5}"
CPU_SAMPLE_SECONDS="${HEALTH_CPU_SAMPLE_SECONDS:-1}"
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}" # optional Slack/Discord-compatible webhook (bonus)
OUTPUT_JSON=false
QUIET=false

readonly EXIT_OK=0 EXIT_WARN=1 EXIT_CRIT=2 EXIT_UNKNOWN=3

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Collect host health metrics, append them to a log file and report threshold breaches.

Thresholds (percent, integers 1-100):
  --cpu N          CPU usage warning threshold          (default: ${CPU_WARN})
  --mem N          Memory usage warning threshold       (default: ${MEM_WARN})
  --disk N         Disk usage warning threshold         (default: ${DISK_WARN})
  --cpu-crit N     CPU usage critical threshold         (default: ${CPU_CRIT})
  --mem-crit N     Memory usage critical threshold      (default: ${MEM_CRIT})
  --disk-crit N    Disk usage critical threshold        (default: ${DISK_CRIT})

Output & logging:
  --json           Print the report as JSON (log entry is also written as one JSON line)
  --log-file PATH  Log file to append to               (default: ${LOG_FILE})
  --max-size BYTES Rotate the log when it exceeds this  (default: ${MAX_LOG_BYTES})
  --keep N         Number of rotated logs to keep       (default: ${KEEP_LOGS})
  -q, --quiet      Do not print the report to stdout (warnings still go to stderr)
  -h, --help       Show this help and exit
  -V, --version    Show version and exit

Environment:
  HEALTH_WEBHOOK_URL   If set, a Slack/Discord-compatible JSON message is POSTed on WARNING/CRITICAL.
  HEALTH_*             Every default above can be set via env (e.g. HEALTH_DISK_WARN=75).

Exit codes: 0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN (usage/collection error)

Examples:
  ${SCRIPT_NAME} --disk 80 --cpu 90 --mem 85
  ${SCRIPT_NAME} --json --log-file /var/log/system-health/health_log.txt
EOF
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_UNKNOWN"
}

trap 'die "unexpected error on line ${LINENO}"' ERR

is_percent() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 100)); }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --cpu | --mem | --disk | --cpu-crit | --mem-crit | --disk-crit)
        (($# >= 2)) || die "option $1 requires a value"
        is_percent "$2" || die "option $1 expects an integer 1-100, got '$2'"
        case "$1" in
          --cpu) CPU_WARN=$2 ;;
          --mem) MEM_WARN=$2 ;;
          --disk) DISK_WARN=$2 ;;
          --cpu-crit) CPU_CRIT=$2 ;;
          --mem-crit) MEM_CRIT=$2 ;;
          --disk-crit) DISK_CRIT=$2 ;;
        esac
        shift 2
        ;;
      --log-file)
        (($# >= 2)) || die "option $1 requires a value"
        LOG_FILE=$2
        shift 2
        ;;
      --max-size)
        if (($# < 2)) || ! is_uint "$2"; then die "option --max-size expects a byte count"; fi
        MAX_LOG_BYTES=$2
        shift 2
        ;;
      --keep)
        if (($# < 2)) || ! is_uint "$2" || (($2 < 1)); then die "option --keep expects an integer >= 1"; fi
        KEEP_LOGS=$2
        shift 2
        ;;
      --json) OUTPUT_JSON=true; shift ;;
      -q | --quiet) QUIET=true; shift ;;
      -h | --help) usage; exit "$EXIT_OK" ;;
      -V | --version) echo "${SCRIPT_NAME} ${VERSION}"; exit "$EXIT_OK" ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  # A critical threshold below its warning threshold is almost certainly a typo.
  local pair
  for pair in "cpu:${CPU_WARN}:${CPU_CRIT}" "mem:${MEM_WARN}:${MEM_CRIT}" "disk:${DISK_WARN}:${DISK_CRIT}"; do
    IFS=: read -r name warn crit <<<"$pair"
    ((crit >= warn)) || die "${name} critical threshold (${crit}) is lower than warning (${warn})"
  done
}

# ---------- helpers ----------
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# ---------- collectors (Linux /proc based, no extra packages) ----------
read_cpu_totals() {
  # Prints "<idle+iowait> <total>" from the aggregate cpu line of /proc/stat.
  local _cpu user nice system idle iowait irq softirq steal _rest
  read -r _cpu user nice system idle iowait irq softirq steal _rest </proc/stat
  echo "$((idle + iowait)) $((user + nice + system + idle + iowait + irq + softirq + steal))"
}

collect_cpu() {
  local idle1 total1 idle2 total2 didle dtotal
  read -r idle1 total1 <<<"$(read_cpu_totals)"
  sleep "$CPU_SAMPLE_SECONDS"
  read -r idle2 total2 <<<"$(read_cpu_totals)"
  didle=$((idle2 - idle1))
  dtotal=$((total2 - total1))
  if ((dtotal <= 0)); then
    CPU_PCT="0.0"
  else
    CPU_PCT=$(awk -v i="$didle" -v t="$dtotal" 'BEGIN { printf "%.1f", (1 - i / t) * 100 }')
  fi
}

collect_memory() {
  local total=0 avail=0 key value _unit
  while IFS=' ' read -r key value _unit; do
    case "$key" in
      MemTotal:) total=$value ;;
      MemAvailable:) avail=$value ;;
    esac
  done </proc/meminfo
  ((total > 0)) || die "could not read MemTotal from /proc/meminfo"
  MEM_TOTAL_MB=$((total / 1024))
  MEM_USED_MB=$(((total - avail) / 1024))
  MEM_PCT=$(awk -v t="$total" -v a="$avail" 'BEGIN { printf "%.1f", (t - a) / t * 100 }')
}

collect_load() {
  local _rest
  read -r LOAD1 LOAD5 LOAD15 _rest </proc/loadavg
  CPU_CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
}

collect_disks() {
  # One line per real filesystem: "<mountpoint>\t<use%>\t<size_kb>\t<used_kb>\t<fstype>"
  DISKS=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && DISKS+=("$line")
  done < <(
    df -P -T -k \
      -x tmpfs -x devtmpfs -x squashfs -x overlay -x proc -x sysfs -x cgroup -x cgroup2 \
      -x autofs -x efivarfs -x fuse.lxcfs -x nsfs 2>/dev/null \
      | awk 'NR > 1 { gsub("%", "", $6); printf "%s\t%s\t%s\t%s\t%s\n", $7, $6, $3, $4, $2 }' \
      || true
  )
  ((${#DISKS[@]} > 0)) || die "df returned no filesystems"
}

collect_top_processes() {
  # "<pid>\t<user>\t<%mem>\t<rss_mb>\t<command>" for the top 5 processes by memory
  TOP_PROCS=()
  local pid user pmem rss comm
  while IFS=' ' read -r pid user pmem rss comm; do
    TOP_PROCS+=("${pid}"$'\t'"${user}"$'\t'"${pmem}"$'\t'"$((rss / 1024))"$'\t'"${comm}")
  done < <(ps -eo pid=,user=,%mem=,rss=,comm= --sort=-%mem | head -n 5)
}

# ---------- evaluation ----------
STATUS=$EXIT_OK
MESSAGES=()

raise() {
  local level=$1 msg=$2
  MESSAGES+=("[${level}] ${msg}")
  if [[ "$level" == "CRITICAL" ]]; then
    STATUS=$EXIT_CRIT
  elif ((STATUS < EXIT_WARN)); then
    STATUS=$EXIT_WARN
  fi
}

# Compare a decimal value against integer thresholds.
check() {
  local label=$1 value=$2 warn=$3 crit=$4 int
  int=$(awk -v v="$value" 'BEGIN { printf "%d", v }')
  if ((int >= crit)); then
    raise CRITICAL "${label} ${value}% >= critical threshold ${crit}%"
  elif ((int >= warn)); then
    raise WARNING "${label} ${value}% >= warning threshold ${warn}%"
  fi
}

evaluate() {
  check "CPU usage" "$CPU_PCT" "$CPU_WARN" "$CPU_CRIT"
  check "Memory usage" "$MEM_PCT" "$MEM_WARN" "$MEM_CRIT"
  local d mount pct _rest
  for d in "${DISKS[@]}"; do
    IFS=$'\t' read -r mount pct _rest <<<"$d"
    check "Disk usage on ${mount}" "$pct" "$DISK_WARN" "$DISK_CRIT"
  done
}

status_name() {
  case "$1" in
    0) echo OK ;;
    1) echo WARNING ;;
    2) echo CRITICAL ;;
    *) echo UNKNOWN ;;
  esac
}

# ---------- rendering ----------
render_text() {
  local d p mount pct size used fstype pid user pmem rss comm m
  printf '===== %s | host=%s | status=%s =====\n' "$TIMESTAMP" "$HOSTNAME_FQDN" "$(status_name "$STATUS")"
  printf 'CPU usage    : %s%% (%s cores)\n' "$CPU_PCT" "$CPU_CORES"
  printf 'Memory usage : %s%% (%s / %s MB)\n' "$MEM_PCT" "$MEM_USED_MB" "$MEM_TOTAL_MB"
  printf 'Load average : %s %s %s (1m 5m 15m)\n' "$LOAD1" "$LOAD5" "$LOAD15"
  printf 'Disk usage   :\n'
  for d in "${DISKS[@]}"; do
    IFS=$'\t' read -r mount pct size used fstype <<<"$d"
    printf '  %-28s %3s%%  %8s MB used of %8s MB  (%s)\n' "$mount" "$pct" "$((used / 1024))" "$((size / 1024))" "$fstype"
  done
  printf 'Top 5 processes by memory:\n'
  printf '  %-8s %-12s %6s %9s  %s\n' PID USER %MEM RSS_MB COMMAND
  for p in "${TOP_PROCS[@]}"; do
    IFS=$'\t' read -r pid user pmem rss comm <<<"$p"
    printf '  %-8s %-12s %6s %9s  %s\n' "$pid" "$user" "$pmem" "$rss" "$comm"
  done
  for m in "${MESSAGES[@]}"; do
    printf '%s\n' "$m"
  done
}

render_json() {
  local d p mount pct size used fstype pid user pmem rss comm m first
  printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,' \
    "$TIMESTAMP" "$(json_escape "$HOSTNAME_FQDN")" "$(status_name "$STATUS")" "$STATUS"
  printf '"cpu":{"usage_percent":%s,"cores":%s},' "$CPU_PCT" "$CPU_CORES"
  printf '"memory":{"usage_percent":%s,"used_mb":%s,"total_mb":%s},' "$MEM_PCT" "$MEM_USED_MB" "$MEM_TOTAL_MB"
  printf '"load":{"1m":%s,"5m":%s,"15m":%s},' "$LOAD1" "$LOAD5" "$LOAD15"
  printf '"thresholds":{"cpu":{"warn":%s,"crit":%s},"mem":{"warn":%s,"crit":%s},"disk":{"warn":%s,"crit":%s}},' \
    "$CPU_WARN" "$CPU_CRIT" "$MEM_WARN" "$MEM_CRIT" "$DISK_WARN" "$DISK_CRIT"
  printf '"disks":['
  first=true
  for d in "${DISKS[@]}"; do
    IFS=$'\t' read -r mount pct size used fstype <<<"$d"
    $first || printf ','
    first=false
    printf '{"mount":"%s","usage_percent":%s,"size_kb":%s,"used_kb":%s,"fstype":"%s"}' \
      "$(json_escape "$mount")" "$pct" "$size" "$used" "$(json_escape "$fstype")"
  done
  printf '],"top_processes":['
  first=true
  for p in "${TOP_PROCS[@]}"; do
    IFS=$'\t' read -r pid user pmem rss comm <<<"$p"
    $first || printf ','
    first=false
    printf '{"pid":%s,"user":"%s","mem_percent":%s,"rss_mb":%s,"command":"%s"}' \
      "$pid" "$(json_escape "$user")" "$pmem" "$rss" "$(json_escape "$comm")"
  done
  printf '],"alerts":['
  first=true
  for m in "${MESSAGES[@]}"; do
    $first || printf ','
    first=false
    printf '"%s"' "$(json_escape "$m")"
  done
  printf ']}\n'
}

# ---------- log handling ----------
rotate_logs() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size i
  size=$(wc -c <"$LOG_FILE")
  ((size >= MAX_LOG_BYTES)) || return 0
  rm -f "${LOG_FILE}.${KEEP_LOGS}"
  for ((i = KEEP_LOGS - 1; i >= 1; i--)); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

write_log() {
  local dir
  dir=$(dirname -- "$LOG_FILE")
  mkdir -p -- "$dir" || die "cannot create log directory ${dir}"
  rotate_logs
  # flock prevents interleaved entries if two runs overlap (e.g. cron + manual run).
  {
    flock -w 10 9 || die "could not lock ${LOG_FILE}"
    if $OUTPUT_JSON; then
      printf '%s' "$REPORT_JSON" >>"$LOG_FILE"
    else
      printf '%s\n\n' "$REPORT_TEXT" >>"$LOG_FILE"
    fi
  } 9>>"${LOG_FILE}.lock"
}

notify_webhook() {
  [[ -n "$WEBHOOK_URL" && "$STATUS" -ne "$EXIT_OK" ]] || return 0
  command -v curl >/dev/null 2>&1 || { echo "[WARNING] curl not found, webhook skipped" >&2; return 0; }
  local text payload
  text="$(status_name "$STATUS") on ${HOSTNAME_FQDN}: $(printf '%s; ' "${MESSAGES[@]}")"
  text=$(json_escape "$text")
  # "text" is read by Slack, "content" by Discord.
  payload=$(printf '{"text":"%s","content":"%s"}' "$text" "$text")
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null \
    || echo "[WARNING] webhook delivery failed" >&2
}

main() {
  parse_args "$@"
  [[ -r /proc/stat && -r /proc/meminfo ]] || die "this script requires Linux (/proc)"

  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)

  collect_cpu
  collect_memory
  collect_load
  collect_disks
  collect_top_processes
  evaluate

  REPORT_TEXT=$(render_text)
  REPORT_JSON=$(render_json)$'\n'

  write_log

  if ! $QUIET; then
    if $OUTPUT_JSON; then
      printf '%s' "$REPORT_JSON"
    else
      printf '%s\n' "$REPORT_TEXT"
    fi
  fi
  # Threshold breaches always reach stderr so cron mail / journald capture them even with --quiet.
  if ((${#MESSAGES[@]} > 0)) && { $QUIET || $OUTPUT_JSON; }; then
    printf '%s\n' "${MESSAGES[@]}" >&2
  fi

  notify_webhook
  trap - ERR
  exit "$STATUS"
}

main "$@"
