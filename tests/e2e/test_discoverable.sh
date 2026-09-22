#!/bin/bash
# =============================================================================
# E2E Test: Discoverable (ready ladder rung 3, standard 2.10)
# The server answers a Steam server-browser query (A2S_INFO) the way a player's
# "add server" dialog sees it, and the player count it advertises agrees with
# the count the idle guard reads over the REST API.
# =============================================================================
# server_query proves the ports are bound. That is "reachable", not
# "discoverable": a bound port that answers nothing, or answers with the wrong
# name, is a server nobody can find.
#
# The cross-check below makes two independent views of the server's state
# agree: the one it advertises to the browser and the one it reports to an
# authenticated admin session.
#
# The query goes from the runner, outside the container, to the container's own
# address on the Docker network, with bash's /dev/udp. docker-compose.test.yml
# deliberately publishes no host ports (the shared runner would collide on
# them), so this is the path a machine on the same network would use; nothing
# in it runs inside the container being tested. A2S_INFO has required a
# challenge round trip since 2020; the first reply may be S2C_CHALLENGE (0x41).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="discoverable"
CONTAINER="palworld-server"
# What docker-compose.test.yml configures, and so what the browser must show.
EXPECTED_NAME="E2E Test Server"
EXPECTED_SLOTS=4   # MAX_PLAYERS in docker-compose.test.yml

A2S_QUERY='\xFF\xFF\xFF\xFFTSource Engine Query\x00'

# a2s_info ; the server's reply as a lowercase hex string, or nothing
a2s_info() {
    local fd reply challenge escaped=""
    exec {fd}<>"/dev/udp/${QUERY_HOST}/${QUERY_PORT}" || return 1
    # One printf per datagram: two writes would be two packets.
    printf '%b' "${A2S_QUERY}" >&"${fd}"
    reply="$(timeout 5 dd bs=1400 count=1 status=none <&"${fd}" | od -An -v -tx1 | tr -d ' \n')" || true
    if [[ "${reply:0:10}" == "ffffffff41" ]]; then
        challenge="${reply:10:8}"
        for (( i = 0; i < 8; i += 2 )); do escaped+="\\x${challenge:i:2}"; done
        printf '%b' "${A2S_QUERY}${escaped}" >&"${fd}"
        reply="$(timeout 5 dd bs=1400 count=1 status=none <&"${fd}" | od -An -v -tx1 | tr -d ' \n')" || true
    fi
    exec {fd}>&-
    printf '%s' "${reply}"
}

# cstring <var> ; reads a NUL-terminated string at POS in HEX into <var>
cstring() {
    local out=""
    while [[ ${POS} -lt ${#HEX} && "${HEX:POS:2}" != "00" ]]; do
        out+="\\x${HEX:POS:2}"
        POS=$(( POS + 2 ))
    done
    POS=$(( POS + 2 ))
    printf -v "$1" '%b' "${out}"
}

# byte <var> ; one unsigned byte at POS. A reply cut short reads as 0 rather
# than aborting the test under set -e; the assertions then say what is wrong.
byte() {
    local h="${HEX:POS:2}"
    printf -v "$1" '%d' "0x${h:-00}"
    POS=$(( POS + 2 ))
}

test_discoverable() {
    log_test_start "${TEST_NAME}"
    assert_container_running "${CONTAINER}"

    # A private server is found by its address, not in a browser - Valheim's
    # does not answer a server-browser query at all - so the rung is proven on
    # a public server. Not run, not failed, when private; the workflow makes it
    # public only on a GitHub-hosted runner, where that lists no address of ours.
    local public
    public="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" 2>/dev/null \
        | sed -n 's/^SERVER_PUBLIC=//p' | head -1)"
    if [[ "${public,,}" != "true" ]]; then
        log_warn "Not run: the server is private (SERVER_PUBLIC=${public:-unset}), so it is not listed in a server browser"
        log_warn "Set E2E_SERVER_PUBLIC=true only on a disposable network: a public server registers with Steam under this machine's public IP"
        exit 77
    fi

    if ! wait_for_log "${CONTAINER}" "LogNet:" 300; then
        log_warn "Server may not be fully ready"
    fi

    # The container's address on its Docker network (the first, if several).
    QUERY_PORT=27015
    QUERY_HOST="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CONTAINER}" 2>/dev/null | awk '{print $1}')"
    if [[ ! "${QUERY_HOST}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        log_error "Could not find the container's address on its Docker network"
        docker inspect -f '{{json .NetworkSettings.Networks}}' "${CONTAINER}" 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_info "Querying ${QUERY_HOST}:${QUERY_PORT}/udp from the runner"

    # The query port can lag the game port for a moment after startup.
    local attempt
    HEX=""
    for attempt in 1 2 3 4 5 6; do
        HEX="$(a2s_info)" || true
        [[ "${HEX:0:10}" == "ffffffff49" ]] && break
        log_info "No A2S_INFO reply yet (attempt ${attempt}); retrying"
        sleep 5
    done

    if [[ "${HEX:0:10}" != "ffffffff49" ]]; then
        log_error "The server did not answer a server-browser query on 27015/udp"
        log_error "Reply (hex): ${HEX:-<none>}"
        # Which UDP ports the server actually holds: whether the query port is
        # bound at all is the first thing to know about a silent query.
        log_error "UDP ports the container holds:"
        # Plain bash for the hex: the runner's awk is mawk, which has no strtonum.
        local ports="" addr
        while read -r _ addr _; do
            [[ "${addr}" == *:* ]] || continue
            ports+="$(( 16#${addr##*:} )) "
        done < <(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" sh -c 'cat /proc/net/udp /proc/net/udp6 2>/dev/null' | tail -n +2)
        log_error "  $(tr ' ' '\n' <<< "${ports}" | sort -un | tr '\n' ' ')"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Header (4 x FF), type 'I', protocol, then name, map, folder, game,
    # a 16-bit app id, players, max players, bots.
    local protocol name map folder game players max_players bots
    POS=10
    byte protocol
    cstring name
    cstring map
    cstring folder
    cstring game
    POS=$(( POS + 4 ))   # app id
    byte players
    byte max_players
    byte bots
    log_info "Browser sees: name='${name}' map='${map}' folder='${folder}' game='${game}' players=${players}/${max_players}"

    local failed=0
    if [[ "${name}" == "${EXPECTED_NAME}" ]]; then
        log_success "The browser shows the configured name"
    else
        log_error "Expected name '${EXPECTED_NAME}', the browser shows '${name}'"
        failed=1
    fi
    if [[ "${max_players}" -eq ${EXPECTED_SLOTS} ]]; then
        log_success "It advertises the configured ${EXPECTED_SLOTS} slots"
    else
        log_error "Expected ${EXPECTED_SLOTS} slots, the browser shows ${max_players}"
        failed=1
    fi

    # The count the idle guard reads, through the same function it calls,
    # against the count the server advertises. Two views of one fact.
    local logged
    logged="$(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" bash -c 'source /opt/palworld/scripts/common && get_player_count' 2>/dev/null)" || true
    if [[ "${logged}" =~ ^[0-9]+$ ]] && [[ "${logged}" -eq "${players}" ]]; then
        log_success "The advertised player count (${players}) matches the one the idle guard reads over the REST API"
    else
        log_error "The browser says ${players} players; the idle guard's count from the REST API says '${logged:-<nothing>}'"
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_test_pass "${TEST_NAME}"
    return 0
}

test_discoverable
