#!/bin/sh
# Test harness for ops/watchdog.sh — no external dependencies.
# Sources watchdog.sh for each test to exercise the main() function with stubbed builtins.
set -e

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "${TMPDIR_BASE}"' EXIT

STATE_FILE="${TMPDIR_BASE}/watchdog_state"
HOME="${TMPDIR_BASE}"
HEALTHZ="http://127.0.0.1:4040/healthz"
export HOME STATE_FILE HEALTHZ

pass=0
fail=0

check() {
  label="$1"
  expected="$2"
  actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $label"
    pass=$((pass + 1))
  else
    echo "  FAIL: $label — expected='$expected' got='$actual'"
    fail=$((fail + 1))
  fi
}

# Stub builtins — these are shell functions that override the external commands.
# They persist across multiple sources of watchdog.sh because sourcing runs in
# the current shell (same function namespace). watchdog.sh does not define
# osascript/curl/date, so the stubs below are never overwritten by the source.

NOTIFIED=""
STUB_EXIT=1
FAKE_NOW=1000

osascript() { NOTIFIED="${NOTIFIED}notified:$*|"; }
curl() { return "${STUB_EXIT}"; }
date() { echo "${FAKE_NOW}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Test 1: initial state (no state file), daemon down → alert ---
rm -f "${STATE_FILE}"
NOTIFIED=""
STUB_EXIT=1
FAKE_NOW=1000
# shellcheck source=ops/watchdog.sh
. "${SCRIPT_DIR}/watchdog.sh"
check "initial-down triggers notification" "1" "$(printf '%s' "${NOTIFIED}" | grep -c notified)"
check "state file written as down" "down" "$(awk '{print $1}' "${STATE_FILE}")"

# --- Test 2: down→down within 1 hour → suppressed ---
printf 'down 999\n' > "${STATE_FILE}"
NOTIFIED=""
FAKE_NOW=1000
STUB_EXIT=1
. "${SCRIPT_DIR}/watchdog.sh"
check "repeat within 1 hour is suppressed" "0" "$(printf '%s' "${NOTIFIED}" | grep -c notified)"

# --- Test 3: down→down after 1 hour → reminder fires ---
printf 'down 0\n' > "${STATE_FILE}"
FAKE_NOW=4000
NOTIFIED=""
STUB_EXIT=1
. "${SCRIPT_DIR}/watchdog.sh"
check "reminder fires after 1 hour" "1" "$(printf '%s' "${NOTIFIED}" | grep -c notified)"

# --- Test 4: down→up → recovery notice ---
printf 'down 0\n' > "${STATE_FILE}"
NOTIFIED=""
STUB_EXIT=0
FAKE_NOW=5000
. "${SCRIPT_DIR}/watchdog.sh"
check "recovery triggers notification" "1" "$(printf '%s' "${NOTIFIED}" | grep -c notified)"
check "state file written as up" "up" "$(awk '{print $1}' "${STATE_FILE}")"

# --- Test 5: up→up → silent ---
printf 'up 0\n' > "${STATE_FILE}"
NOTIFIED=""
STUB_EXIT=0
FAKE_NOW=6000
. "${SCRIPT_DIR}/watchdog.sh"
check "up→up is silent" "0" "$(printf '%s' "${NOTIFIED}" | grep -c notified)"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
