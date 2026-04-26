#!/usr/bin/env bash
set -euo pipefail

warn_threshold="${DISK_WARN_THRESHOLD:-80}"
crit_threshold="${DISK_CRIT_THRESHOLD:-90}"

if ! [[ "$warn_threshold" =~ ^[0-9]+$ ]] || ! [[ "$crit_threshold" =~ ^[0-9]+$ ]]; then
  echo "ERROR: DISK_WARN_THRESHOLD and DISK_CRIT_THRESHOLD must be integers"
  exit 2
fi

if (( warn_threshold < 0 || warn_threshold > 100 || crit_threshold < 0 || crit_threshold > 100 )); then
  echo "ERROR: disk thresholds must be in range 0..100"
  exit 2
fi

paths=(
  "VOL_DB_PATH:${VOL_DB_PATH:-}"
  "VOL_MATOMO_DATA:${VOL_MATOMO_DATA:-}"
  "BACKUP_DIR:${BACKUP_DIR:-}"
)

exit_code=0

for item in "${paths[@]}"; do
  var_name="${item%%:*}"
  path_value="${item#*:}"

  if [[ -z "$path_value" ]]; then
    echo "CRITICAL: $var_name is empty"
    exit_code=2
    continue
  fi

  if [[ ! -d "$path_value" ]]; then
    echo "CRITICAL: directory not found for $var_name: $path_value"
    exit_code=2
    continue
  fi

  usage="$(df -P "$path_value" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"

  if ! [[ "$usage" =~ ^[0-9]+$ ]]; then
    echo "CRITICAL: unable to detect disk usage for $var_name: $path_value"
    exit_code=2
    continue
  fi

  if (( usage >= crit_threshold )); then
    echo "CRITICAL: $var_name usage is ${usage}% at $path_value (threshold: ${crit_threshold}%)"
    exit_code=2
  elif (( usage >= warn_threshold )); then
    echo "WARNING: $var_name usage is ${usage}% at $path_value (threshold: ${warn_threshold}%)"
    if (( exit_code < 1 )); then
      exit_code=1
    fi
  else
    echo "OK: $var_name usage is ${usage}% at $path_value"
  fi
done

exit "$exit_code"
