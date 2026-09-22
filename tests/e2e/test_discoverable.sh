#!/bin/bash
# =============================================================================
# E2E Test: Discoverable (ready ladder rung 3, standard 2.10)
# Steam lists the server publicly: its master server knows a Palworld server
# (app 2394010) on this machine's public address and game port.
# =============================================================================
# server_query proves the ports are bound. That is "reachable", not
# "discoverable": a bound port nobody is told about is a server nobody can find.
#
# Palworld does not answer a Steam server-browser query (A2S_INFO) on its query
# port. The port is bound, and it stays silent: three E2E runs with the server
# public (-publiclobby) got no reply, and GameDig queries Palworld over its REST
# API for the same reason. So this rung asks Steam instead, with the keyless
# ISteamApps/GetServersAtAddress, for what is registered at the address the
# runner reaches the internet from. That is the listing a player's browser is
# built from, which the old query only inferred.
#
# A2S is still tried once: if a future Palworld answers it, the name, slots and
# player count it advertises are checked as before.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="discoverable"
CONTAINER="palworld-server"
APP_ID=2394010
GAME_PORT=8211     # SERVER_PORT in docker-compose.test.yml
# What docker-compose.test.yml configures, and so what a browser must show.
EXPECTED_NAME="E2E Test Server"
EXPECTED_SLOTS=4   # MAX_PLAYERS in docker-compose.test.yml
# Registration follows startup by seconds; allow for a slow master server.
LISTING_ATTEMPTS=12
LISTING_INTERVAL=15

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

# steam_listing <ip> ; Steam's answer for that address, or nothing if Steam
# did not answer.
steam_listing() {
    curl -sf -m 20 "https://api.steampowered.com/ISteamApps/GetServersAtAddress/v1/?addr=$1" 2>/dev/null || true
}

# check_a2s ; the old browser-query checks, for a server that answers.
# Returns 0 if it answered and agreed, 1 if it answered and disagreed, 2 if
# it did not answer.
check_a2s() {
    QUERY_PORT=27015
    QUERY_HOST="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CONTAINER}" 2>/dev/null | awk '{print $1}')"
    [[ "${QUERY_HOST}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 2
    HEX="$(a2s_info)" || true
    [[ "${HEX:0:10}" == "ffffffff49" ]] || return 2

    # Header (4 x FF), type 'I', protocol, then name, map, folder, game,
    # a 16-bit app id, players, max players, bots.
    local protocol name map folder game players max_players bots failed=0
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
    log_info "The browser query sees: protocol=${protocol} name='${name}' map='${map}' folder='${folder}' game='${game}' players=${players}/${max_players} bots=${bots}"

    if [[ "${name}" != "${EXPECTED_NAME}" ]]; then
        log_error "Expected name '${EXPECTED_NAME}', the browser query shows '${name}'"
        failed=1
    fi
    if [[ "${max_players}" -ne ${EXPECTED_SLOTS} ]]; then
        log_error "Expected ${EXPECTED_SLOTS} slots, the browser query shows ${max_players}"
        failed=1
    fi
    local counted
    counted="$(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" bash -c 'source /opt/palworld/scripts/common && get_player_count' 2>/dev/null)" || true
    if [[ ! "${counted}" =~ ^[0-9]+$ ]] || [[ "${counted}" -ne "${players}" ]]; then
        log_error "The browser query says ${players} players; the REST API says '${counted:-<nothing>}'"
        failed=1
    fi
    return "${failed}"
}

test_discoverable() {
    log_test_start "${TEST_NAME}"
    assert_container_running "${CONTAINER}"

    # A private server is found by its address, not in a browser, so the rung
    # is proven on a public server. Not run, not failed, when private; the
    # workflow makes it public only on a GitHub-hosted runner, where the address
    # Steam lists is GitHub's, not ours.
    local public
    public="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" 2>/dev/null \
        | sed -n 's/^SERVER_PUBLIC=//p' | head -1)"
    if [[ "${public,,}" != "true" ]]; then
        log_warn "Not run: the server is private (SERVER_PUBLIC=${public:-unset}), so it is not listed in a server browser"
        log_warn "Set E2E_SERVER_PUBLIC=true only on a disposable network: a public server registers with Steam under this machine's public IP"
        exit 77
    fi

    if ! wait_for_log "${CONTAINER}" "Running Palworld dedicated server" 300; then
        log_warn "Server may not be fully ready"
    fi

    # The address the runner reaches the internet from, which is the address
    # the server registered from. Not printed: it identifies the machine.
    local address="" source
    for source in https://api.ipify.org https://checkip.amazonaws.com; do
        address="$(curl -sf -m 10 "${source}" 2>/dev/null | tr -d '[:space:]')" || true
        [[ "${address}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && break
        address=""
    done
    if [[ -z "${address}" ]]; then
        # An observer that cannot see is not a server that failed (2.11).
        log_warn "Not run: could not learn this runner's public address, so Steam cannot be asked about it"
        exit 77
    fi

    local attempt answer listed="" answered=0
    for (( attempt = 1; attempt <= LISTING_ATTEMPTS; attempt++ )); do
        answer="$(steam_listing "${address}")"
        if jq -e '.response.success == true' <<< "${answer}" >/dev/null 2>&1; then
            answered=1
            listed="$(jq -r --argjson app "${APP_ID}" --argjson port "${GAME_PORT}" \
                '[.response.servers[]? | select(.appid == $app and .gameport == $port)] | first // empty | .steamid // "unknown"' \
                <<< "${answer}")"
            [[ -n "${listed}" ]] && break
        fi
        log_info "Steam does not list the server yet (attempt ${attempt}/${LISTING_ATTEMPTS}); retrying"
        sleep "${LISTING_INTERVAL}"
    done

    if [[ ${answered} -eq 0 ]]; then
        log_warn "Not run: Steam's Web API did not answer, so the listing could not be checked"
        exit 77
    fi
    if [[ -z "${listed}" ]]; then
        log_error "Steam lists no Palworld server (app ${APP_ID}) on game port ${GAME_PORT} at this runner's address"
        log_error "What Steam lists there: $(jq -c '[.response.servers[]? | {appid, gameport, lan, secure}]' <<< "${answer}" 2>/dev/null)"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "Steam lists the server publicly (app ${APP_ID}, game port ${GAME_PORT}, Steam ID ${listed})"

    local a2s=0
    check_a2s || a2s=$?
    case "${a2s}" in
        0) log_success "It also answers a browser query, with the configured name, ${EXPECTED_SLOTS} slots and the REST API's player count" ;;
        1) log_test_fail "${TEST_NAME}"; return 1 ;;
        *) log_info "No answer to a browser query (A2S) on 27015/udp, as expected: Palworld does not answer one" ;;
    esac

    log_test_pass "${TEST_NAME}"
    return 0
}

test_discoverable
