#!/bin/bash
# =============================================================================
# Unit test: palworld-updater retries a transient SteamCMD failure
# =============================================================================
# Needs no Docker. A fake steamcmd.sh fails with exit 8 ("Missing configuration",
# the cold-client error) a set number of times, then installs the server binary.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

# run_case <fail_times> <retries> ; sets RC and CALLS
run_case() {
    local fail_times="$1" retries="$2"
    rm -rf "${WORK:?}"/*
    mkdir -p "${WORK}/steamcmd" "${WORK}/server" "${WORK}/log"
    echo 0 > "${WORK}/calls"
    cat > "${WORK}/steamcmd/steamcmd.sh" <<FAKE
#!/bin/bash
calls=\$(( \$(cat "${WORK}/calls") + 1 ))
echo "\${calls}" > "${WORK}/calls"
if [[ \${calls} -le ${fail_times} ]]; then
    echo "ERROR! Failed to install app '2394010' (Missing configuration)"
    exit 8
fi
touch "${WORK}/server/PalServer.sh"
echo "Success! App '2394010' fully installed."
exit 0
FAKE
    chmod +x "${WORK}/steamcmd/steamcmd.sh"

    (
        export PALWORLD_SCRIPTS_PATH="${REPO_ROOT}/scripts"
        export STEAMCMD_PATH="${WORK}/steamcmd"
        export PALWORLD_SERVER_PATH="${WORK}/server"
        export LOG_PATH="${WORK}/log"
        export STEAMCMD_RETRIES="${retries}"
        export STEAMCMD_RETRY_DELAY=0
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/palworld-updater"
        run_update
    ) > "${WORK}/out.txt" 2>&1
    RC=$?
    CALLS="$(cat "${WORK}/calls")"
}

run_case 2 3
if [[ ${RC} -eq 0 && ${CALLS} -eq 3 ]]; then pass "two transient failures, then success (3 attempts)"
else fail "expected rc=0 calls=3, got rc=${RC} calls=${CALLS}"; cat "${WORK}/out.txt"; fi

run_case 0 3
if [[ ${RC} -eq 0 && ${CALLS} -eq 1 ]]; then pass "no retry when the first attempt succeeds"
else fail "expected rc=0 calls=1, got rc=${RC} calls=${CALLS}"; fi

run_case 99 3
if [[ ${RC} -ne 0 && ${CALLS} -eq 3 ]]; then pass "gives up after STEAMCMD_RETRIES attempts"
else fail "expected rc!=0 calls=3, got rc=${RC} calls=${CALLS}"; fi

run_case 99 1
if [[ ${RC} -ne 0 && ${CALLS} -eq 1 ]]; then pass "STEAMCMD_RETRIES=1 disables retrying"
else fail "expected rc!=0 calls=1, got rc=${RC} calls=${CALLS}"; fi

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "All updater retry checks passed"
