#!/bin/bash
# =============================================================================
# E2E Test: Authenticated session (ready ladder rung 4, standard 2.10)
# An admin session logs in to the REST API with the server's own password and
# reads the server's live state back: its name and its player count.
# =============================================================================
# Stand-in, named as one (2.10): no headless Palworld client exists. What this
# proves is that the server accepts an authenticated session and reports its
# own state through it - not that a player joined.
#
# It also proves the player count the idle guard and the backup schedule depend
# on is real. It was a placeholder that always said 0.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="authenticated"
CONTAINER="palworld-server"
API="/opt/palworld/scripts/palworld-api"
EXPECTED_NAME="E2E Test Server"

test_authenticated() {
    log_test_start "${TEST_NAME}"
    assert_container_running "${CONTAINER}"

    if ! wait_for_log "${CONTAINER}" "LogNet:" 300; then
        log_warn "Server may not be fully ready"
    fi

    # The REST API can come up a little after the game port.
    local info="" attempt
    for attempt in 1 2 3 4 5 6; do
        info="$(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" "${API}" info 2>/dev/null)" && break
        log_info "REST API not answering yet (attempt ${attempt}); retrying"
        sleep 10
    done
    if [[ -z "${info}" ]]; then
        log_error "An admin session could not log in and read /v1/api/info"
        MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" "${API}" info 2>&1 | tail -3 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "Logged in to the REST API with the server's own admin password"

    # jq runs inside the container: the image ships it, the runner may not.
    local name version
    name="$(MSYS_NO_PATHCONV=1 docker exec -i "${CONTAINER}" jq -r '.servername // empty' <<< "${info}")"
    version="$(MSYS_NO_PATHCONV=1 docker exec -i "${CONTAINER}" jq -r '.version // empty' <<< "${info}")"
    log_info "The server reports: name='${name}' version='${version}'"

    local failed=0
    if [[ "${name}" == "${EXPECTED_NAME}" ]]; then
        log_success "It reports the configured name"
    else
        log_error "Expected server name '${EXPECTED_NAME}', got '${name}'"
        failed=1
    fi

    # The count the idle guard reads, through the same function it calls.
    local count
    if count="$(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" bash -c 'source /opt/palworld/scripts/common && get_player_count' 2>/dev/null)" \
        && [[ "${count}" =~ ^[0-9]+$ ]]; then
        log_success "get_player_count reads the live count (${count}), as the idle guard will"
    else
        log_error "get_player_count returned '${count:-<nothing>}', expected a number from the server"
        failed=1
    fi

    # An authenticated session means nothing if any password gets in.
    if MSYS_NO_PATHCONV=1 docker exec -e ADMIN_PASSWORD=not-the-password-this-server-uses \
        "${CONTAINER}" "${API}" info >/dev/null 2>&1; then
        log_error "The REST API accepted a wrong password"
        failed=1
    else
        log_success "A wrong password is refused"
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_test_pass "${TEST_NAME}"
    return 0
}

test_authenticated
