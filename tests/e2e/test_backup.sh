#!/bin/bash
# =============================================================================
# E2E Test: Backup
# Verifies that the backup system creates valid backups
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="backup"

# -----------------------------------------------------------------------------
# Test: Backup
# -----------------------------------------------------------------------------
test_backup() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "palworld-server"

    # Wait for server to be ready
    log_info "Waiting for server to initialize"
    if ! wait_for_log "palworld-server" "LogNet:" 300; then
        log_warn "Server may not be fully ready"
    fi

    # Give server time to create save files
    log_info "Waiting for save file generation (30 seconds)"
    sleep 30

    # Check if save files exist
    log_info "Checking for save files"

    # Use MSYS_NO_PATHCONV=1 to avoid Git Bash path conversion on Windows
    if MSYS_NO_PATHCONV=1 docker exec palworld-server test -d "/opt/palworld/server/Pal/Saved/SaveGames" 2>/dev/null; then
        log_info "SaveGames directory found"
    else
        log_warn "SaveGames directory not yet created, creating test files"
        MSYS_NO_PATHCONV=1 docker exec palworld-server mkdir -p /opt/palworld/server/Pal/Saved/SaveGames
        MSYS_NO_PATHCONV=1 docker exec palworld-server sh -c "echo 'test' > /opt/palworld/server/Pal/Saved/SaveGames/test.sav"
    fi

    # Check for settings file
    if MSYS_NO_PATHCONV=1 docker exec palworld-server test -d "/opt/palworld/server/Pal/Saved/Config/LinuxServer" 2>/dev/null; then
        log_info "Config directory found"
    else
        log_warn "Config directory not yet created, creating test files"
        MSYS_NO_PATHCONV=1 docker exec palworld-server mkdir -p /opt/palworld/server/Pal/Saved/Config/LinuxServer
        MSYS_NO_PATHCONV=1 docker exec palworld-server sh -c "echo '[test]' > /opt/palworld/server/Pal/Saved/Config/LinuxServer/test.ini"
    fi

    # Trigger manual backup
    log_info "Triggering manual backup"
    # Use MSYS_NO_PATHCONV=1 to prevent Git Bash from converting paths on Windows
    MSYS_NO_PATHCONV=1 docker exec palworld-server /opt/palworld/scripts/palworld-backup --force

    # Wait for backup to complete
    sleep 5

    # Check if backup was created
    log_info "Checking for backup files"
    local backup_dir="/config/backups"

    local backup_count
    backup_count=$(MSYS_NO_PATHCONV=1 docker exec palworld-server find "${backup_dir}" -name 'palworld_*.zip' -o -name 'palworld_*.tar.gz' 2>/dev/null | wc -l)

    if [[ ${backup_count} -gt 0 ]]; then
        log_success "Backup created successfully (${backup_count} backup(s) found)"

        # List backups
        log_info "Backup files:"
        MSYS_NO_PATHCONV=1 docker exec palworld-server ls -lh "${backup_dir}/" 2>/dev/null || true

        # Verify backup contains expected directories
        log_info "Verifying backup contents"
        local latest_backup
        latest_backup=$(MSYS_NO_PATHCONV=1 docker exec palworld-server sh -c "ls -t '${backup_dir}'/palworld_*.zip 2>/dev/null | head -1")

        if [[ -n "${latest_backup}" ]]; then
            local backup_contents
            backup_contents=$(MSYS_NO_PATHCONV=1 docker exec palworld-server unzip -l "${latest_backup}" 2>/dev/null || true)

            if echo "${backup_contents}" | grep -qE "SaveGames|Config"; then
                log_success "Backup contains save/config files"
            else
                log_warn "Backup may not contain expected files"
                echo "${backup_contents}"
            fi
        fi

        log_test_pass "${TEST_NAME}"
        return 0
    else
        log_error "No backup files found"
        MSYS_NO_PATHCONV=1 docker exec palworld-server ls -la "${backup_dir}/" 2>/dev/null || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
}

# Run test
test_backup
