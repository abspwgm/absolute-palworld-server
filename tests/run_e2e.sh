#!/bin/bash
# =============================================================================
# E2E Test Runner - Executes all end-to-end tests
# =============================================================================
# Usage: ./tests/run_e2e.sh [test_name]
#   - No arguments: runs all tests
#   - With argument: runs specific test (e.g., ./tests/run_e2e.sh server_start)
# =============================================================================

# Don't use set -e - we want to capture logs even on failures
# set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
E2E_DIR="${SCRIPT_DIR}/e2e"

# Preconditions, and the vocabulary for saying which one failed.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/preflight.sh"

# Test configuration
CONTAINER_NAME="palworld-server"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.test.yml"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"  # 10 minutes default
STARTUP_WAIT="${STARTUP_WAIT:-300}"  # 5 minutes for server startup
USE_BIND_MOUNTS="${USE_BIND_MOUNTS:-false}"  # Use local data folder for debugging
LOGS_DIR="${PROJECT_ROOT}/data/logs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# Create logs directory immediately
mkdir -p "${LOGS_DIR}"

# Master log file for all output
MASTER_LOG="${LOGS_DIR}/e2e_run_$(date +%Y%m%d_%H%M%S).log"

# Error handler - captures state on unexpected errors
on_error() {
    local exit_code=$?
    local line_no=$1
    echo "[ERROR] Script failed at line ${line_no} with exit code ${exit_code}" | tee -a "${MASTER_LOG}"
    echo "[ERROR] Capturing emergency logs..." | tee -a "${MASTER_LOG}"

    # Try to capture container logs
    {
        echo "========================================"
        echo "EMERGENCY LOG CAPTURE"
        echo "Failed at line: ${line_no}"
        echo "Exit code: ${exit_code}"
        echo "Timestamp: $(date)"
        echo "========================================"
        echo ""
        echo "=== Docker PS ==="
        docker ps -a 2>&1 || echo "docker ps failed"
        echo ""
        echo "=== Container Logs ==="
        docker logs "${CONTAINER_NAME}" 2>&1 || echo "No container logs available"
        echo ""
        echo "=== Docker Compose Logs ==="
        docker compose -f "${COMPOSE_FILE}" logs 2>&1 || echo "No compose logs available"
    } >> "${LOGS_DIR}/emergency_$(date +%Y%m%d_%H%M%S).log" 2>&1

    echo "[ERROR] Emergency logs saved to ${LOGS_DIR}/" | tee -a "${MASTER_LOG}"
}

# Set up error trap
trap 'on_error ${LINENO}' ERR

# -----------------------------------------------------------------------------
# Logging (all output goes to both console and master log)
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_warn() {
    echo -e "${YELLOW}[SKIP]${NC} $*" | tee -a "${MASTER_LOG}"
}

log_header() {
    echo "" | tee -a "${MASTER_LOG}"
    echo -e "${BLUE}========================================${NC}" | tee -a "${MASTER_LOG}"
    echo -e "${BLUE}$*${NC}" | tee -a "${MASTER_LOG}"
    echo -e "${BLUE}========================================${NC}" | tee -a "${MASTER_LOG}"
}

# -----------------------------------------------------------------------------
# Setup and Teardown
# -----------------------------------------------------------------------------
cleanup_existing() {
    log_info "Cleaning up any existing containers"

    cd "${PROJECT_ROOT}"

    # Stop and remove any existing containers
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
    docker compose down -v 2>/dev/null || true
    docker rm -f palworld-server 2>/dev/null || true
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

    # Remove any orphaned networks
    docker network prune -f 2>/dev/null || true

    # Wait for ports to be released
    sleep 2
}

setup_test_environment() {
    log_header "Setting up test environment"

    # First cleanup any existing resources
    cleanup_existing

    cd "${PROJECT_ROOT}"

    # Create data directories
    mkdir -p data/config data/server data/logs

    # Export USE_BIND_MOUNTS for docker-compose only if it's "true"
    # When unset, docker-compose will use the default named volumes
    if [[ "${USE_BIND_MOUNTS}" == "true" ]]; then
        export USE_BIND_MOUNTS
    else
        unset USE_BIND_MOUNTS
    fi

    # Build the container
    log_info "Building Docker image"
    docker compose -f "${COMPOSE_FILE}" build --no-cache

    log_success "Test environment ready"
}

cleanup_test_environment() {
    log_header "Cleaning up test environment"

    cd "${PROJECT_ROOT}"

    # Export logs before cleanup (in case we're exiting unexpectedly)
    if docker inspect "${CONTAINER_NAME}" &>/dev/null; then
        export_logs "cleanup_final"
    fi

    # Stop and remove containers
    docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

    # Remove test volumes (only if not using bind mounts)
    if [[ "${USE_BIND_MOUNTS}" != "true" ]]; then
        docker volume rm palworld-test-config palworld-test-server 2>/dev/null || true
    fi

    log_success "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Container Management
# -----------------------------------------------------------------------------
start_container() {
    log_info "Starting test container"

    cd "${PROJECT_ROOT}"

    # Start container with test config
    docker compose -f "${COMPOSE_FILE}" up -d

    # Wait for container to be running
    local attempts=0
    while [[ $(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null) != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to start"
            docker compose -f "${COMPOSE_FILE}" logs
            return 1
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    log_success "Container started"
}

stop_container() {
    log_info "Stopping test container"

    cd "${PROJECT_ROOT}"
    docker compose -f "${COMPOSE_FILE}" down 2>/dev/null || true

    log_success "Container stopped"
}

get_container_logs() {
    docker logs "${CONTAINER_NAME}" 2>&1
}

export_logs() {
    local test_name="${1:-final}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="${LOGS_DIR}/${timestamp}_${test_name}.log"

    log_info "Exporting logs to ${log_file}"
    mkdir -p "${LOGS_DIR}"

    {
        echo "========================================"
        echo "Test: ${test_name}"
        echo "Timestamp: $(date)"
        echo "========================================"
        echo ""
        echo "=== Container Logs ==="
        docker logs "${CONTAINER_NAME}" 2>&1 || echo "No container logs available"
        echo ""
        echo "=== Container Inspect ==="
        docker inspect "${CONTAINER_NAME}" 2>&1 || echo "Container not found"
    } > "${log_file}" 2>&1

    log_success "Logs exported to ${log_file}"
}

# -----------------------------------------------------------------------------
# Test Execution
# -----------------------------------------------------------------------------
run_test() {
    local test_name="$1"
    local test_script="${E2E_DIR}/test_${test_name}.sh"

    if [[ ! -f "${test_script}" ]]; then
        log_warn "Test not found: ${test_name}"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        TEST_RESULT["${test_name}"]="not_run"
        return 0
    fi

    log_header "Running test: ${test_name}"

    # Make script executable
    chmod +x "${test_script}"

    # Run test with timeout
    local start_time
    start_time=$(date +%s)

    if timeout "${TEST_TIMEOUT}" bash "${test_script}"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Test passed: ${test_name} (${duration}s)"

        # Export logs for passed tests too (for debugging)
        export_logs "${test_name}_PASSED"

        TESTS_PASSED=$((TESTS_PASSED + 1))
        TEST_RESULT["${test_name}"]="pass"
        return 0
    else
        local exit_code=$?
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        # 77: the test could not apply here and says why (the automake
        # convention). Not run, never failed; the verdict records the rung as
        # not_run, so it cannot read "ready" on a run that skipped it.
        if [[ ${exit_code} -eq 77 ]]; then
            log_warn "Not run: ${test_name} (${duration}s)"
            TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
            TEST_RESULT["${test_name}"]="not_run"
            return 0
        fi

        if [[ ${exit_code} -eq 124 ]]; then
            log_error "Test timed out: ${test_name} (${duration}s)"
        else
            log_error "Test failed: ${test_name} (exit code: ${exit_code}, ${duration}s)"
        fi

        # Capture container logs on failure
        log_info "=== Container Logs (last 100 lines) ==="
        docker logs "${CONTAINER_NAME}" --tail 100 2>&1 || true
        log_info "=== End Container Logs ==="

        # Export full logs to file for debugging
        export_logs "${test_name}_FAILED"

        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("${test_name}")
        TEST_RESULT["${test_name}"]="fail"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Test Suite
# -----------------------------------------------------------------------------
ALL_TESTS=(
    "server_start"
    "server_query"
    "authenticated"
    "backup"
    "graceful_shutdown"
    "restart_update"
)

# -----------------------------------------------------------------------------
# The ready ladder (standard 2.10)
# -----------------------------------------------------------------------------
# A rung passes only when every test that proves it ran and passed. The verdict
# is the highest rung reached with every rung below it passed too; verdict.json
# is what the fleet board reads, and it never claims more.
#
# The authenticated rung is a stand-in, and the verdict names it (2.10): an
# admin session on the REST API, not a player joining - no headless Palworld
# client exists.
#
# The discoverable rung is not applicable, not failed, and the verdict says why
# (.absolute/policy.yml, ready_ladder). tests/e2e/test_discoverable.sh is the
# check for a host the internet can reach: `./tests/run_e2e.sh discoverable`.
LADDER=(up reachable discoverable authenticated recoverable)
declare -A RUNG_TESTS=(
    [up]="server_start"
    [reachable]="server_query"
    [discoverable]=""
    [authenticated]="authenticated"
    [recoverable]="backup graceful_shutdown restart_update"
)
AUTHENTICATED_STAND_IN="REST API admin session (info, players); not a player join"
NOT_APPLICABLE_REASON="Palworld lists servers in Pocketpair's lobby, which lists only servers the internet can reach; CI runners cannot be reached, and Palworld answers no Steam query"
declare -A TEST_RESULT=()
VERDICT_FILE="${LOGS_DIR}/verdict.json"

# What the run needs from its environment rather than from the image. When one
# is missing the run is inconclusive, not failed (2.11): a runner that cannot
# reach Steam says nothing about whether the server works.
check_preconditions() {
    if ! docker info >/dev/null 2>&1; then
        echo "the Docker daemon is not reachable"
        return 1
    fi
    # The image is built in this run, and the Dockerfile's first network
    # instruction fetches SteamCMD from here. Probe that, not Steam's web API:
    # nothing in this suite calls the web API, so an outage there used to mark
    # runs inconclusive that would have passed.
    #
    # probe_url keeps the status code and curl's exit code, so the reason
    # reaching verdict.json distinguishes a rate limit from a runner with no
    # egress from an outage on Valve's side (2.11). tests/test_preflight.sh
    # holds it to that.
    local probe
    if ! probe="$(probe_url "${STEAMCMD_INSTALLER_URL}" 20)"; then
        echo "${probe}"
        return 1
    fi
    local free_kb
    free_kb="$(df -Pk "${PROJECT_ROOT}" | awk 'NR == 2 {print $4}')"
    if [[ "${free_kb}" =~ ^[0-9]+$ ]] && (( free_kb < 5 * 1024 * 1024 )); then
        echo "the runner has under 5 GB free for the install and its backups"
        return 1
    fi
    return 0
}

rung_status() {
    local test status="pass"
    [[ -z "${RUNG_TESTS[$1]}" ]] && { echo "not_applicable"; return; }
    for test in ${RUNG_TESTS[$1]}; do
        case "${TEST_RESULT[${test}]:-not_run}" in
            pass) ;;
            fail) echo "fail"; return ;;
            *) status="not_run" ;;
        esac
    done
    echo "${status}"
}

# write_verdict <verdict> [reason] ; verdict.json, plus a job summary in CI.
# Written while the container still exists: it holds the Steam build tested.
write_verdict() {
    local verdict="$1" reason="${2:-}" reached="null" rung status rungs="" build
    for rung in "${LADDER[@]}"; do
        status="$(rung_status "${rung}")"
        rungs+="${rungs:+, }\"${rung}\": \"${status}\""
    done
    if [[ "${verdict}" != "inconclusive" ]]; then
        for rung in "${LADDER[@]}"; do
            status="$(rung_status "${rung}")"
            [[ "${status}" == "not_applicable" ]] && continue
            [[ "${status}" == "pass" ]] || break
            reached="\"${rung}\""
        done
    fi
    build="$(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER_NAME}" sed -n 's/.*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' \
        /opt/palworld/server/steamapps/appmanifest_2394010.acf 2>/dev/null | head -1)" || true
    local build_json="null"
    [[ "${build}" =~ ^[0-9]+$ ]] && build_json="\"${build}\""
    reason="${reason//\\/\\\\}"
    reason="${reason//\"/\\\"}"
    cat > "${VERDICT_FILE}" <<EOF
{
  "schema": 1,
  "game": "palworld",
  "verdict": "${verdict}",
  "reason": "${reason}",
  "reached": ${reached},
  "rungs": {${rungs}},
  "stand_ins": {"authenticated": "${AUTHENTICATED_STAND_IN}"},
  "not_applicable": {"discoverable": "${NOT_APPLICABLE_REASON}"},
  "steam_build": ${build_json},
  "commit": "${GITHUB_SHA:-$(git -C "${PROJECT_ROOT}" rev-parse HEAD 2>/dev/null)}",
  "event": "${GITHUB_EVENT_NAME:-local}",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    log_info "Verdict: ${verdict}${reason:+ (${reason})}; reached ${reached//\"/}; build ${build:-unknown}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "### Ready ladder: **${verdict}**${reason:+ — ${reason}}"
            echo ""
            echo "| Rung | Result |"
            echo "|---|---|"
            for rung in "${LADDER[@]}"; do
                echo "| ${rung} | $(rung_status "${rung}") |"
            done
            echo ""
            echo "Steam build: ${build:-unknown}. Authenticated rung: ${AUTHENTICATED_STAND_IN}. Discoverable: not applicable (${NOT_APPLICABLE_REASON})."
        } >> "${GITHUB_STEP_SUMMARY}"
    fi
}

# Ready means every applicable rung passed: one that failed, or never ran, is
# not proven.
ladder_verdict() {
    local verdict="ready" rung status
    for rung in "${LADDER[@]}"; do
        status="$(rung_status "${rung}")"
        [[ "${status}" == "pass" || "${status}" == "not_applicable" ]] || verdict="degraded"
    done
    [[ "$(rung_status up)" == "pass" ]] || verdict="down"
    echo "${verdict}"
}

run_all_tests() {
    local specific_test="$1"

    # Before anything is built or started: a run that cannot test is
    # inconclusive (2.11), and returns 3 so CI can tell it apart from a failure.
    local missing
    if [[ -z "${specific_test}" ]] && ! missing="$(check_preconditions)"; then
        log_warn "Inconclusive before starting: ${missing}"
        write_verdict "inconclusive" "${missing}"
        return 3
    fi

    # Setup
    setup_test_environment

    # Trap cleanup on exit
    trap cleanup_test_environment EXIT

    # Start container for tests
    start_container

    # Run tests
    if [[ -n "${specific_test}" ]]; then
        run_test "${specific_test}"
    else
        for test in "${ALL_TESTS[@]}"; do
            run_test "${test}" || true  # Continue even if test fails
        done
    fi

    # Export final logs
    export_logs "final_summary"

    # A verdict describes the whole ladder, so a single-test debug run writes none.
    if [[ -z "${specific_test}" ]]; then
        write_verdict "$(ladder_verdict)"
    fi

    # Print summary
    print_summary
}

print_summary() {
    log_header "Test Summary"

    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

    echo ""
    echo -e "  ${GREEN}Passed:${NC}  ${TESTS_PASSED}"
    echo -e "  ${RED}Failed:${NC}  ${TESTS_FAILED}"
    echo -e "  ${YELLOW}Skipped:${NC} ${TESTS_SKIPPED}"
    echo -e "  Total:   ${total}"
    echo ""

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo -e "${RED}Failed tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  - ${test}"
        done
        echo ""
    fi

    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}TESTS FAILED${NC}"
        echo -e "${RED}========================================${NC}"
        return 1
    else
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        echo -e "${GREEN}========================================${NC}"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_header "Absolute Palworld Server - E2E Test Suite"
    log_info "Master log: ${MASTER_LOG}"

    # Check dependencies
    if ! command -v docker &> /dev/null; then
        log_error "Docker is required but not installed"
        exit 1
    fi

    if ! command -v docker compose &> /dev/null; then
        log_error "Docker Compose is required but not installed"
        exit 1
    fi

    # Run tests
    local result=0
    run_all_tests "$1" || result=$?

    log_info "Logs saved to: ${LOGS_DIR}/"
    log_info "Master log: ${MASTER_LOG}"

    # Keep window open if running interactively
    if [[ -t 0 ]]; then
        echo ""
        echo "Press Enter to close..."
        read -r
    fi

    return ${result}
}

# Run main
main "$@"
