#!/bin/bash
# =============================================================================
# E2E Test: Graceful Shutdown (ready ladder rung 5, recoverable)
# A stop saves the world first - confirmed by the server itself - and the
# container then exits on its own, not by SIGKILL.
# =============================================================================
# This test used to pass whatever happened. It grepped for words like
# "shutdown" and "stopping", which supervisor prints on its own, and its last
# branch was "Could not fully verify graceful shutdown ... Still pass". Behind
# it, the wrapper had no signal trap at all: supervisor's SIGINT killed the
# wrapper, the game was orphaned without a save, and all three timeouts in the
# shutdown ladder were 120s, so SIGKILL raced the save anyway. The Rust image
# had the same bug and the same test.
#
# The wrapper's output goes to the container's stdout (supervisord.conf), so it
# is read from `docker logs`, which also works once the container has stopped.
# It used to go to a file, and reading that back gave this test nothing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="graceful_shutdown"
CONTAINER="palworld-server"
# Must exceed the ladder: save + exit (120s) < supervisor (150s) < compose (180s).
BUDGET=200

wrapper_log() {
    docker logs "${CONTAINER}" 2>&1 || true
}

restart_for_following_tests() {
    log_info "Starting the container again for the tests that follow"
    docker start "${CONTAINER}" >/dev/null 2>&1 || {
        cd "$(dirname "${SCRIPT_DIR}")/.."
        docker compose -f docker-compose.test.yml up -d
    }
    local attempts=0
    while [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to restart"
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    log_success "Container restarted"
}

test_graceful_shutdown() {
    log_test_start "${TEST_NAME}"
    assert_container_running "${CONTAINER}"

    log_info "Waiting for server to be ready"
    if ! wait_for_log "${CONTAINER}" "LogNet:" 300; then
        log_warn "Server may not be fully ready"
    fi
    sleep 10
    assert_process_running "${CONTAINER}" "PalServer-Linux-Shipping"

    local saves_before
    saves_before="$(wrapper_log | grep -c "World saved (the server confirmed over the REST API)" || true)"

    log_info "Sending the stop signal Docker sends (SIGINT via supervisor)"
    docker kill --signal=INT "${CONTAINER}" >/dev/null || true

    local waited=0
    while [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == "true" ]]; do
        if [[ ${waited} -ge ${BUDGET} ]]; then
            log_error "Container still running ${waited}s after SIGINT"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    local exit_code failed=0
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}" 2>/dev/null)"
    log_info "Container exited after ${waited}s with code ${exit_code}"

    if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == "true" ]]; then
        failed=1
    elif [[ "${exit_code}" == "137" ]]; then
        log_error "Container was SIGKILLed (137): the save window was cut short"
        failed=1
    else
        log_success "Container stopped on its own"
    fi

    local saves_after
    saves_after="$(wrapper_log | grep -c "World saved (the server confirmed over the REST API)" || true)"
    if [[ "${saves_after}" -gt "${saves_before}" ]]; then
        log_success "The server confirmed the save before it stopped"
    else
        log_error "No confirmed save on shutdown"
        log_error "=== the wrapper's last lines ==="
        wrapper_log | tail -25 || true
        log_error "=== end ==="
        failed=1
    fi

    # Bring the container back whatever the verdict, or every later test fails
    # on this one's behalf.
    if ! restart_for_following_tests; then
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_test_pass "${TEST_NAME}"
    return 0
}

test_graceful_shutdown
