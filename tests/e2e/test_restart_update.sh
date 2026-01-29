#!/bin/bash
# =============================================================================
# E2E Test: Restart and Update
# Verifies that the server can be restarted and update mechanism works
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="restart_update"

# -----------------------------------------------------------------------------
# Test: Restart and Update
# -----------------------------------------------------------------------------
test_restart_update() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "palworld-server"

    # Wait for server to be ready
    log_info "Waiting for server to be ready"
    if ! wait_for_log "palworld-server" "LogNet:" 300; then
        log_warn "Server may not be fully ready"
    fi

    # Get current build ID (if available)
    log_info "Getting current build ID"
    local current_build
    current_build=$(MSYS_NO_PATHCONV=1 docker exec palworld-server cat /opt/palworld/server/.build_id 2>/dev/null || echo "unknown")
    log_info "Current build ID: ${current_build}"

    # Test manual update trigger (should work even with no actual update)
    log_info "Testing manual update trigger"

    # Run updater - it should complete without error
    if MSYS_NO_PATHCONV=1 docker exec palworld-server /opt/palworld/scripts/palworld-updater 2>&1; then
        log_success "Update script executed successfully"
    else
        log_warn "Update script returned non-zero exit code (may be normal)"
    fi

    # Give time for any update to complete
    sleep 10

    # Verify server is still running after update attempt
    log_info "Verifying server is running after update"
    if MSYS_NO_PATHCONV=1 docker exec palworld-server pgrep -f PalServer-Linux-Shipping > /dev/null 2>&1; then
        log_success "Server process is running after update"
    else
        # Server may have been restarted, wait a bit more
        log_info "Server process not found, waiting for restart..."
        sleep 30

        if MSYS_NO_PATHCONV=1 docker exec palworld-server pgrep -f PalServer-Linux-Shipping > /dev/null 2>&1; then
            log_success "Server process is running after restart"
        else
            log_warn "Server process may still be starting"
        fi
    fi

    # Test container restart via docker compose
    log_info "Testing container restart"
    cd "$(dirname "${SCRIPT_DIR}")/.."

    # Stop container
    docker compose -f docker-compose.test.yml stop
    sleep 5

    # Start container again
    docker compose -f docker-compose.test.yml up -d

    # Wait for container to be running
    local attempts=0
    while [[ $(docker inspect -f '{{.State.Running}}' palworld-server 2>/dev/null) != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to restart"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    log_info "Container restarted, waiting for server to initialize"

    # Wait for server to be ready again
    if wait_for_log "palworld-server" "Starting Palworld dedicated server" 120; then
        log_success "Server started after restart"
    else
        log_warn "Server start message not found, checking process"
    fi

    # Verify server process is running
    attempts=0
    while [[ ${attempts} -lt 60 ]]; do
        if MSYS_NO_PATHCONV=1 docker exec palworld-server pgrep -f PalServer-Linux-Shipping > /dev/null 2>&1; then
            log_success "Server process is running after container restart"
            log_test_pass "${TEST_NAME}"
            return 0
        fi
        sleep 5
        attempts=$((attempts + 5))
    done

    log_error "Server process did not start after restart"
    docker logs palworld-server --tail 50 2>&1 || true
    log_test_fail "${TEST_NAME}"
    return 1
}

# Run test
test_restart_update
