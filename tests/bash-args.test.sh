#!/usr/bin/env bash
# Argument-handling tests for the bash scripts in scripts/linux/.
#
# These tests never touch a real disk: they only exercise the validation that
# runs before any privileged or destructive work, which is exactly the guard
# layer that must not regress. Each script rejects bad input and exits non-zero
# before it ever reaches sgdisk.
#
# Deliberately dependency-free (no bats) so CI needs nothing beyond bash.
#
# Usage: ./tests/bash-args.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$(dirname "$SCRIPT_DIR")/scripts/linux"

PASS=0
FAIL=0

pass() { printf '\033[32m  [PASS]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
failed() { printf '\033[31m  [FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# assert_exit <expected_code> <description> <command...>
assert_exit() {
    local expected="$1" desc="$2"
    shift 2
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [ "$actual" -eq "$expected" ]; then
        pass "$desc (exit $actual)"
    else
        failed "$desc (expected exit $expected, got $actual)"
    fi
}

# assert_output_contains <needle> <description> <command...>
assert_output_contains() {
    local needle="$1" desc="$2"
    shift 2
    local output
    output="$("$@" 2>&1)" || true
    if printf '%s' "$output" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        failed "$desc (output did not contain '$needle')"
    fi
}

echo "=== convert-linux-to-uefi.sh ==="
CONVERT="$LINUX_DIR/convert-linux-to-uefi.sh"

assert_exit 1 "rejects missing --disk" \
    bash "$CONVERT"
assert_output_contains "--disk is required" "explains that --disk is required" \
    bash "$CONVERT"
assert_exit 1 "rejects a non-existent device" \
    bash "$CONVERT" --disk /nonexistent-device
assert_output_contains "not a valid block device" "explains the device is invalid" \
    bash "$CONVERT" --disk /nonexistent-device
assert_exit 1 "rejects --disk with no value" \
    bash "$CONVERT" --disk
assert_exit 1 "rejects an unknown option" \
    bash "$CONVERT" --bogus-option
assert_output_contains "Unknown option" "names the unknown option" \
    bash "$CONVERT" --bogus-option
assert_exit 1 "shows usage for --help" \
    bash "$CONVERT" --help
assert_output_contains "--esp-size" "documents --esp-size in usage" \
    bash "$CONVERT" --help
assert_output_contains "--confirm" "documents --confirm in usage" \
    bash "$CONVERT" --help

echo
echo "=== restore-partition-table.sh ==="
RESTORE="$LINUX_DIR/restore-partition-table.sh"

assert_exit 1 "rejects missing --disk" \
    bash "$RESTORE"
assert_output_contains "--disk is required" "explains that --disk is required" \
    bash "$RESTORE"
assert_exit 1 "rejects a non-existent device" \
    bash "$RESTORE" --disk /nonexistent-device
assert_exit 1 "rejects --backup with no value" \
    bash "$RESTORE" --disk /nonexistent-device --backup
assert_exit 1 "rejects an unknown option" \
    bash "$RESTORE" --bogus-option
assert_exit 1 "shows usage for --help" \
    bash "$RESTORE" --help
assert_output_contains "--list" "documents --list in usage" \
    bash "$RESTORE" --help

echo
echo "=== check-uefi-readiness.sh ==="
CHECK="$LINUX_DIR/check-uefi-readiness.sh"

assert_exit 1 "fails on an invalid explicit disk" \
    bash "$CHECK" /nonexistent-device

echo
echo "=== verify-uefi-migration.sh ==="
VERIFY="$LINUX_DIR/verify-uefi-migration.sh"

# The verifier is expected to report failure in this container (no UEFI, no ESP);
# what matters is that it runs to completion and returns the documented code.
assert_exit 1 "reports a failed migration when nothing is migrated" \
    bash "$VERIFY" /nonexistent-device

echo
echo "=== shebang and executable bit ==="
for f in "$LINUX_DIR"/*.sh; do
    name=$(basename "$f")
    if [ -x "$f" ]; then
        pass "$name is executable"
    else
        failed "$name is not executable"
    fi
    if head -n1 "$f" | grep -q '^#!/usr/bin/env bash$'; then
        pass "$name has the expected shebang"
    else
        failed "$name has an unexpected shebang"
    fi
done

echo
echo "======================================"
printf 'Passed: %d, Failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All bash argument tests passed."
exit 0
