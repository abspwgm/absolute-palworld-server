#!/bin/bash
# =============================================================================
# Unit Test: admin password resolution (no Docker required)
# RCON authenticates with AdminPassword, so an empty or well-known one is a
# remote console open to anyone who can reach the port. Exercises
# resolve_admin_password from scripts/common with plain bash.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_helpers.sh"

CHECKS_FAILED=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

check() {
    local description="$1"
    shift
    if "$@"; then
        log_success "${description}"
    else
        log_error "${description}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

# Run resolve_admin_password in a clean subshell. Results land in ${WORK_DIR}:
# resolved (the password), output (everything logged).
resolve_with() {
    local enabled="$1"
    local password="$2"
    (
        TEST_ROOT="${WORK_DIR}/root"
        mkdir -p "${TEST_ROOT}/config"
        RCON_ENABLED="${enabled}"
        ADMIN_PASSWORD="${password}"
        source "${PROJECT_DIR}/scripts/common"
        resolve_admin_password > "${WORK_DIR}/output" 2>&1
        printf '%s' "${ADMIN_PASSWORD}" > "${WORK_DIR}/resolved"
    )
}

password_file() { echo "${WORK_DIR}/root/config/admin_password"; }
resolved() { cat "${WORK_DIR}/resolved"; }
file_password() { tr -d '\n' < "$(password_file)"; }
reset_state() { rm -rf "${WORK_DIR}/root" "${WORK_DIR}/resolved" "${WORK_DIR}/output"; }

log_test_start "admin_password (unit)"

# Every denylisted default (and empty) must be replaced by a generated password
for default in "" changeme password your_secure_password admin adminpassword rcon ChangeMe; do
    reset_state
    resolve_with true "${default}"
    check "default '${default}': password file written" test -f "$(password_file)"
    check "default '${default}': file is mode 600" test "$(stat -c '%a' "$(password_file)" 2>/dev/null)" == "600"
    check "default '${default}': generated length >= 24" test "$(file_password | wc -c)" -ge 24
    check "default '${default}': resolved password matches file" test "$(resolved)" == "$(file_password)"
    check "default '${default}': resolved password is not the default" test "$(resolved)" != "${default}"
    check "default '${default}': value is never logged" bash -c "! grep -qF '$(resolved)' '${WORK_DIR}/output'"
    check "default '${default}': log says where the file is" grep -q "admin_password" "${WORK_DIR}/output"
done

# A user-supplied password is used unchanged and no file is written
reset_state
resolve_with true 'My-Own_S3cret'
check "custom password used unchanged" test "$(resolved)" == 'My-Own_S3cret'
check "custom password: no file written" test ! -e "$(password_file)"

# A generated password is reused on the next start rather than churning
reset_state
resolve_with true ""
FIRST="$(resolved)"
resolve_with true ""
check "generated password is reused on restart" test "$(resolved)" == "${FIRST}"

# RCON disabled: nothing is generated, nothing is written
reset_state
resolve_with false changeme
check "rcon disabled: no file written" test ! -e "$(password_file)"
check "rcon disabled: password untouched" test "$(resolved)" == "changeme"

if [[ ${CHECKS_FAILED} -gt 0 ]]; then
    log_test_fail "admin_password (unit): ${CHECKS_FAILED} check(s) failed"
    exit 1
fi

log_test_pass "admin_password (unit)"
exit 0
