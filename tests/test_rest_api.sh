#!/bin/bash
# =============================================================================
# Unit test: the REST API client, the player count, and what the idle guard and
# the backup schedule do with each answer
# =============================================================================
# Needs no Docker and no game server. A stand-in answers /v1/api/* the way
# PalServer does where it matters: HTTP basic auth as "admin" with the admin
# password, 401 otherwise, and JSON bodies.
#
# get_player_count was a placeholder that always said 0: the idle guard never
# held an update and "skip backups while players are on" never skipped.

set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
FAKE_PID=""
cleanup() {
    [[ -n "${FAKE_PID}" ]] && kill "${FAKE_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

PASSWORD='correct-horse-battery-staple'

cat > "${WORK}/fake_rest.py" <<'FAKE'
import base64, json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

password = os.environ["FAKE_PASSWORD"]
players = int(os.environ["FAKE_PLAYERS"])
expected = "Basic " + base64.b64encode(f"admin:{password}".encode()).decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self):
        if self.headers.get("Authorization") != expected:
            self.reply(401, {"message": "Unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self.authorised():
            return
        if self.path == "/v1/api/players":
            self.reply(200, {"players": [{"name": f"p{i}", "playerId": str(i)} for i in range(players)]})
        elif self.path == "/v1/api/info":
            self.reply(200, {"version": "v0.6.0", "servername": "E2E Test Server", "description": "", "worldguid": "0"})
        else:
            self.reply(404, {"message": "not found"})

    def do_POST(self):
        if not self.authorised():
            return
        if self.path == "/v1/api/save":
            with open(os.environ["FAKE_SAVES"], "a") as f:
                f.write("saved\n")
            self.reply(200, {})
        else:
            self.reply(404, {"message": "not found"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["FAKE_PORT_FILE"] + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.environ["FAKE_PORT_FILE"] + ".tmp", os.environ["FAKE_PORT_FILE"])
server.serve_forever()
FAKE

FAKE_PASSWORD="${PASSWORD}" FAKE_PLAYERS=2 FAKE_SAVES="${WORK}/saves" FAKE_PORT_FILE="${WORK}/port" \
    python3 "${WORK}/fake_rest.py" > /dev/null 2>&1 &
FAKE_PID=$!
for _ in $(seq 1 50); do [[ -s "${WORK}/port" ]] && break; sleep 0.1; done
PORT="$(cat "${WORK}/port" 2>/dev/null)"
[[ -n "${PORT}" ]] || { echo "[FAIL] the stand-in never opened its port"; exit 1; }

# in_image <port> <password> <command...> ; runs a command with common sourced
in_image() {
    local port="$1" password="$2"
    shift 2
    (
        export TEST_ROOT="${WORK}/root" PALWORLD_SCRIPTS_PATH="${PROJECT_DIR}/scripts"
        export REST_API_ENABLED=true REST_API_PORT="${port}" ADMIN_PASSWORD="${password}"
        mkdir -p "${TEST_ROOT}/config"
        # shellcheck source=/dev/null
        source "${PROJECT_DIR}/scripts/common"
        "$@"
    )
}

# --- the count, and unknown ------------------------------------------------
count="$(in_image "${PORT}" "${PASSWORD}" get_player_count 2>/dev/null)"
[[ "${count}" == "2" ]] && pass "get_player_count reads the live count (2), not the old constant 0" \
    || fail "expected 2 players, got '${count}'"

if count="$(in_image 1 "${PASSWORD}" get_player_count 2>/dev/null)"; then
    fail "an unreachable REST API produced a count: '${count}'"
else
    [[ -z "${count}" ]] && pass "an unreachable REST API is unknown: no count, and a non-zero exit" \
        || fail "an unreachable REST API printed '${count}'"
fi
if in_image "${PORT}" "not-the-password" get_player_count >/dev/null 2>&1; then
    fail "a refused password produced a count"
else
    pass "a refused password (401) is unknown too"
fi

# The function is called directly: a child bash would not inherit it.
idle_rc() { in_image "$1" "${PASSWORD}" is_server_idle >/dev/null 2>&1; echo $?; }
[[ "$(idle_rc "${PORT}")" == "1" ]] && pass "is_server_idle says players are on (1)" || fail "expected is_server_idle 1"
[[ "$(idle_rc 1)" == "2" ]] && pass "is_server_idle says unknown (2) when it cannot read the count" || fail "expected is_server_idle 2"

# --- the save ----------------------------------------------------------------
rm -f "${WORK}/saves"
if in_image "${PORT}" "${PASSWORD}" save_world >/dev/null 2>&1 && [[ -s "${WORK}/saves" ]]; then
    pass "save_world asks the server to save and succeeds only on its answer"
else
    fail "save_world did not reach the server's save endpoint"
fi
if in_image 1 "${PASSWORD}" save_world >/dev/null 2>&1; then
    fail "save_world claimed success with the REST API unreachable"
else
    pass "save_world fails when the server cannot confirm"
fi

# --- the callers ---------------------------------------------------------------
# The real decision code, with only its side effects stubbed.
updater_decision() {
    in_image "$1" "${PASSWORD}" bash -c "
        source '${PROJECT_DIR}/scripts/palworld-updater' >/dev/null 2>&1
        is_server_running() { return 0; }
        check_for_update() { echo REACHED_UPDATE; return 1; }
        FORCE_UPDATE=false UPDATE_IF_IDLE=true
        main 2>&1" | grep -q REACHED_UPDATE && echo update || echo hold
}
backup_decision() {
    in_image "$1" "${PASSWORD}" bash -c "
        source '${PROJECT_DIR}/scripts/palworld-backup' >/dev/null 2>&1
        is_server_running() { return 0; }
        create_backup() { echo BACKED_UP; return 0; }
        cleanup_old_backups() { :; }
        FORCE_BACKUP=false BACKUPS_ENABLED=true BACKUPS_IF_IDLE=true
        main 2>&1" | grep -q BACKED_UP && echo backup || echo skip
}

[[ "$(updater_decision "${PORT}")" == "hold" ]] && pass "the idle guard holds an update while 2 players are on" \
    || fail "the idle guard let an update through with players on"
[[ "$(updater_decision 1)" == "hold" ]] && pass "the idle guard holds when the count cannot be read (standard 5.2)" \
    || fail "the idle guard updated on an unknown player count"
[[ "$(backup_decision "${PORT}")" == "skip" ]] && pass "BACKUPS_IF_IDLE skips a backup while players are on" \
    || fail "a backup ran with players on and BACKUPS_IF_IDLE=true"
[[ "$(backup_decision 1)" == "backup" ]] && pass "an unknown count still takes the backup" \
    || fail "an unknown count skipped the backup"

# --- the password stays off command lines ------------------------------------
if grep -qE 'curl[^|]*-u[[:space:]]' "${PROJECT_DIR}/scripts/common"; then
    fail "curl is given the password on its command line, where ps can read it"
else
    pass "the password reaches curl on stdin, not on a command line"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All REST API checks passed"
    exit 0
fi
echo "${failures} REST API check(s) failed"
exit 1
