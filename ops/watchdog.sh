#!/bin/sh
# External liveness watchdog for the harness daemon.
# Polls /healthz and alerts on state transitions (down/recovered) plus
# at most one reminder per hour while down.
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

  if curl -fsS --max-time 10 "${HEALTHZ}" >/dev/null 2>&1; then
    current=up
  else
    current=down
  fi

  if [ -f "${STATE_FILE}" ]; then
    read -r prev_status prev_ts < "${STATE_FILE}"
  else
    prev_status=up
    prev_ts=0
  fi

  case "${current}:${prev_status}" in
    down:up | down:)
      notify "Harness is DOWN — check logs at ~/.harness/logs/"
      printf 'down %s\n' "${now}" > "${STATE_FILE}"
      ;;
    down:down)
      age=$((now - prev_ts))
      if [ "${age}" -ge 3600 ]; then
        notify "Harness still DOWN (reminder)"
        printf 'down %s\n' "${now}" > "${STATE_FILE}"
      fi
      ;;
    up:down)
      notify "Harness RECOVERED"
      printf 'up %s\n' "${now}" > "${STATE_FILE}"
      ;;
    up:*)
      printf 'up %s\n' "${now}" > "${STATE_FILE}"
      ;;
  esac
}

main
