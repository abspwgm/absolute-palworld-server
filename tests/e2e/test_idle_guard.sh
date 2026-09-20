#!/bin/bash
# =============================================================================
# E2E Test: Idle guard (UPDATE_IF_IDLE)
# Verifies, in the real image, that the player count comes from a real Steam
# A2S_INFO query and that palworld-updater acts on it.
# =============================================================================
# CI has no Palworld client, so a *busy* server cannot be produced for real. The
# busy cases therefore point QUERY_PORT at something other than the game server:
# a fake A2S responder reporting players, and a closed port. Both exercise the
# real get_player_count, the real is_server_idle and the real updater - only the
# thing being queried is substituted.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="idle_guard"
CONTAINER="palworld-server"
UPDATER="/opt/palworld/scripts/palworld-updater"
FAKE_REMOTE="/tmp/fake_a2s_server.py"

run_updater() { # run_updater [env assignments...]
    docker exec "$@" "${CONTAINER}" "${UPDATER}" 2>&1 || true
}

test_idle_guard() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"

    # This test runs straight after restart_update, which restarts the
    # container, so it has to wait for the server to come back before asserting
    # anything. The obvious way - waiting for a log marker - does not work here:
    # "LogNet:" never appears in this image's captured output, which is why
    # test_server_start only warns about it rather than requiring it.
    #
    # So readiness is defined as the thing this test actually needs: the query
    # port answering. That is a capability rather than a log string, it cannot
    # drift when Unreal changes its logging, and if it never becomes true the
    # failure is exactly the one worth reporting.
    log_info "Waiting for the A2S responder to come back after the restart"
    local waited=0
    local ready=0
    while [[ ${waited} -lt 300 ]]; do
        if docker exec "${CONTAINER}" bash -c \
            'source /opt/palworld/scripts/common && get_player_count' >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done

    if [[ ${ready} -ne 1 ]]; then
        log_error "The query port never answered in ${waited}s after the restart"
        log_error "If SERVER_PUBLIC is false the server does not register with"
        log_error "Steam, and the A2S responder never runs - check the compose file."
        log_error "=== container state ==="
        docker ps -a --filter name="${CONTAINER}" --format '{{.Status}}' 2>&1 || true
        docker logs "${CONTAINER}" --tail 40 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "The A2S responder answered after ${waited}s"

    # --- a real A2S query against the real server -------------------------
    # The stub this replaces always answered 0 without asking anything (#4), so
    # the point here is that a genuine query succeeds inside the image.
    local count
    count="$(docker exec "${CONTAINER}" bash -c \
        'source /opt/palworld/scripts/common && get_player_count' 2>/dev/null | tr -d '\r')"

    if [[ "${count}" == "0" ]]; then
        log_success "A real A2S query against the live server returned 0 players"
    else
        log_error "Expected 0 players from the live server, got '${count}'"
        log_error "If this is empty, the query port did not answer at all:"
        docker exec "${CONTAINER}" bash -c \
            'source /opt/palworld/scripts/common && get_query_port' 2>&1 || true
        docker logs "${CONTAINER}" --tail 30 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # An empty server must not block the update on idle grounds.
    if run_updater | grep -q "Players are connected, skipping update"; then
        log_error "The updater skipped the update on an empty server"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "The updater does not skip the update on an empty server"

    # --- a server reporting players must block the update -----------------
    docker cp "${SCRIPT_DIR}/../fake_a2s_server.py" "${CONTAINER}:${FAKE_REMOTE}"

    # The fake prints the port it bound to, then serves one query flow.
    local fake_port
    fake_port="$(docker exec -d "${CONTAINER}" bash -c \
        "nohup python3 ${FAKE_REMOTE} challenge 3 > /tmp/fake_a2s.port 2>/dev/null &" \
        && sleep 2 \
        && docker exec "${CONTAINER}" cat /tmp/fake_a2s.port 2>/dev/null | tr -d '\r')"

    if [[ -z "${fake_port}" ]]; then
        log_error "The fake A2S responder did not report a port"
        docker exec "${CONTAINER}" cat /tmp/fake_a2s.port 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_info "Fake A2S responder reporting 3 players on port ${fake_port}"

    if run_updater -e "QUERY_PORT=${fake_port}" | grep -q "Players are connected, skipping update"; then
        log_success "The updater skipped the update while 3 players were reported"
    else
        log_error "The updater did not skip the update while players were reported"
        run_updater -e "QUERY_PORT=${fake_port}"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- an unanswerable query must fail closed ---------------------------
    # Port 1 is closed, so the count is unknown. The guard must refuse the
    # update rather than assume the server is empty.
    if run_updater -e "QUERY_PORT=1" | grep -q "Players are connected, skipping update"; then
        log_success "An unanswerable query fails closed: the update was skipped"
    else
        log_error "An unanswerable query did not fail closed"
        run_updater -e "QUERY_PORT=1"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    log_test_pass "${TEST_NAME}"
    return 0
}

test_idle_guard
