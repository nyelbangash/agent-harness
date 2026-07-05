#!/bin/sh
# External liveness watchdog for the harness daemon.
# Polls /healthz and alerts on state transitions (down/recovered) plus
# at most one reminder per hour while down, and after 10 min of stale code.
# NTFY_TOPIC is baked into the launchd environment by mix harness.install.

HEALTHZ="${HEALTHZ:-http://127.0.0.1:4040/healthz}"
STATE_FILE="${STATE_FILE:-${HOME}/.harness/watchdog_state}"
TITLE="Harness Watchdog"

notify() {
  msg="$1"
  osascript -e "display notification \"${msg}\" with title \"${TITLE}\""
  if [ -n "${NTFY_TOPIC}" ]; then
    curl -s -X POST "https://ntfy.sh/${NTFY_TOPIC}" \
      -H "Title: ${TITLE}" \
      -d "${msg}" || true
  fi
}

main() {
  now=$(date +%s)

  body=$(curl -fsS --max-time 10 "${HEALTHZ}" 2>/dev/null)
  if [ $? -eq 0 ]; then
    current=up
  else
    current=down
    body=""
  fi

  if [ "${current}" = "up" ]; then
    stale_code=$(printf '%s' "${body}" | jq -r '.stale_code // false' 2>/dev/null) || stale_code=false
  else
    stale_code=false
  fi

  if [ -f "${STATE_FILE}" ]; then
    read -r prev_status prev_ts prev_stale_ts < "${STATE_FILE}"
    prev_stale_ts="${prev_stale_ts:-0}"
  else
    prev_status=up; prev_ts=0; prev_stale_ts=0
  fi

  if [ "${current}" = "up" ] && [ "${stale_code}" = "true" ]; then
    if [ "${prev_stale_ts}" -eq 0 ]; then
      new_stale_ts="${now}"
    else
      stale_age=$((now - prev_stale_ts))
      new_stale_ts="${prev_stale_ts}"
      if [ "${stale_age}" -ge 600 ]; then
        notify "Server running stale code — reload failed or restart needed"
        new_stale_ts="${now}"
      fi
    fi
  else
    new_stale_ts=0
  fi

  case "${current}:${prev_status}" in
    down:up | down:)
      notify "Harness is DOWN — check logs at ~/.harness/logs/"
      printf 'down %s 0\n' "${now}" > "${STATE_FILE}"
      ;;
    down:down)
      age=$((now - prev_ts))
      if [ "${age}" -ge 3600 ]; then
        notify "Harness still DOWN (reminder)"
        printf 'down %s 0\n' "${now}" > "${STATE_FILE}"
      fi
      ;;
    up:down)
      notify "Harness RECOVERED"
      printf 'up %s %s\n' "${now}" "${new_stale_ts}" > "${STATE_FILE}"
      ;;
    up:*)
      printf 'up %s %s\n' "${now}" "${new_stale_ts}" > "${STATE_FILE}"
      ;;
  esac
}

main
