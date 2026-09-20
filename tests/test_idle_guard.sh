#!/bin/bash
# =============================================================================
# Unit test: is_server_idle
# =============================================================================
# Needs no Docker and no game server. get_player_count is the only seam that
# talks to the server, so these cases redefine it and drive the guard's logic.
#
# Guards #4. The parsing itself is covered by tests/test_a2s_player_count.sh;
# this covers the decision the updater and the backup script actually act on.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

# idle_with <count|unknown> <running|stopped> ; sets IDLE
idle_with() {
    local count="$1" running="$2"
    if (
        export PALWORLD_SCRIPTS_PATH="${REPO_ROOT}/scripts"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/common"

        if [[ "${count}" == "unknown" ]]; then
            get_player_count() { return 1; }
        else
            get_player_count() { echo "${count}"; }
        fi
        if [[ "${running}" == "running" ]]; then
            is_server_running() { return 0; }
        else
            is_server_running() { return 1; }
        fi

        is_server_idle
    ) > /dev/null 2>&1; then IDLE=yes; else IDLE=no; fi
}

check() { # check <expected_idle> <description>
    if [[ "${IDLE}" == "$1" ]]; then pass "$2"; else fail "$2 (expected idle=$1, got ${IDLE})"; fi
}

idle_with 0 running
check yes "an empty running server is idle"

# The bug this test exists for: a connected player must block the update.
idle_with 1 running
check no "one connected player means the server is not idle"

idle_with 12 running
check no "twelve connected players mean the server is not idle"

# Fail closed: we cannot prove the server is empty, so do not claim it is.
idle_with unknown running
check no "an unanswered query on a running server fails closed (not idle)"

# With no server up, nobody can be connected.
idle_with unknown stopped
check yes "an unanswered query with the server stopped reports idle"

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All idle guard checks passed"
    exit 0
fi
echo "${failures} idle guard check(s) failed"
exit 1
