#!/bin/bash
# =============================================================================
# Unit test: a2s-player-count
# =============================================================================
# Needs no Docker and no game server: tests/fake_a2s_server.py answers the query.
#
# Guards #4: get_player_count was a stub returning 0, so is_server_idle was
# always true and UPDATE_IF_IDLE / BACKUPS_IF_IDLE were no-ops.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERY="${REPO_ROOT}/scripts/a2s-player-count"
FAKE="${REPO_ROOT}/tests/fake_a2s_server.py"

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

# run_against <mode> <players> ; sets OUT and RC
run_against() {
    local mode="$1" players="$2" port
    exec 3< <(python3 "${FAKE}" "${mode}" "${players}" 2>/dev/null)
    read -r port <&3 || { fail "fake server did not report a port"; return; }
    OUT="$(python3 "${QUERY}" 127.0.0.1 "${port}" 2 2>/dev/null)"
    RC=$?
    exec 3<&-
}

expect_count() { # expect_count <mode> <players> <description>
    run_against "$1" "$2"
    if [[ ${RC} -eq 0 && "${OUT}" == "$2" ]]; then
        pass "$3"
    else
        fail "$3 (expected rc=0 out=$2, got rc=${RC} out='${OUT}')"
    fi
}

expect_failure() { # expect_failure <mode> <description>
    run_against "$1" 0
    if [[ ${RC} -ne 0 && -z "${OUT}" ]]; then
        pass "$2"
    else
        fail "$2 (expected non-zero rc and no output, got rc=${RC} out='${OUT}')"
    fi
}

# --- the normal flow: real servers challenge first ------------------------
expect_count challenge 0 "an empty server reports 0 players"
expect_count challenge 1 "one connected player is reported"
expect_count challenge 7 "seven connected players are reported"
expect_count challenge 32 "a full server reports every player"

# --- a server that skips the challenge -----------------------------------
expect_count direct 3 "a reply without a challenge is handled too"

# --- failures must be distinguishable from "nobody connected" ------------
# This is the point of exiting non-zero: the caller must be able to tell
# "0 players" apart from "the query did not work".
expect_failure silent    "a server that never answers fails rather than reporting 0"
expect_failure truncated "a truncated reply fails rather than reporting 0"
expect_failure garbage   "a non-A2S reply fails rather than reporting 0"

# --- nothing listening at all --------------------------------------------
OUT="$(python3 "${QUERY}" 127.0.0.1 1 1 2>/dev/null)"; RC=$?
if [[ ${RC} -ne 0 && -z "${OUT}" ]]; then
    pass "a closed port fails rather than reporting 0"
else
    fail "expected failure against a closed port, got rc=${RC} out='${OUT}'"
fi

# --- bad arguments -------------------------------------------------------
python3 "${QUERY}" 127.0.0.1 not-a-port >/dev/null 2>&1
if [[ $? -eq 2 ]]; then
    pass "a non-numeric port is a usage error"
else
    fail "a non-numeric port should exit 2"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All A2S player count checks passed"
    exit 0
fi
echo "${failures} A2S player count check(s) failed"
exit 1
