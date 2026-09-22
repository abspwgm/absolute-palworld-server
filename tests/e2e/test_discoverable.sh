#!/bin/bash
# =============================================================================
# E2E Test: Discoverable (ready ladder rung 3, standard 2.10)
# The server is in Palworld's community server list - the list players browse
# in game - at this machine's public address and game port, under its
# configured name, with its configured slots and its live player count.
# =============================================================================
# server_query proves the ports are bound. That is "reachable", not
# "discoverable": a bound port nobody is told about is a server nobody can find.
#
# Palworld's community browser is not Steam's. A public (-publiclobby) server
# registers with Pocketpair's own lobby service, api.palworldgame.com, and the
# game lists servers from there: Steam's master server does not list it (one
# E2E run asked ISteamApps/GetServersAtAddress and got nothing), and it does not
# answer a Steam server-browser query (A2S_INFO) on its bound query port (three
# runs, six queries each, no reply; GameDig reads Palworld over REST for the
# same reason). So this rung reads the list the game reads, the way the game
# reads it: server/search by name, then the entry at this runner's address and
# game port.
#
# A2S is still tried once: if a future Palworld answers it, the name, slots and
# player count it advertises are checked too.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="discoverable"
CONTAINER="palworld-server"
LOBBY_API="https://api.palworldgame.com"
GAME_PORT=8211     # SERVER_PORT in docker-compose.test.yml
# What docker-compose.test.yml configures, and so what a browser must show.
EXPECTED_NAME="E2E Test Server"
EXPECTED_SLOTS=4   # MAX_PLAYERS in docker-compose.test.yml
# Registration follows startup by seconds; allow for a slow lobby service.
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

# lobby_search ; the community list's entries under the configured name, as
# the game asks for them, or nothing if the lobby service did not answer.
lobby_search() {
    curl -sf -m 20 -A "X-UnrealEngine-Agent" -G "${LOBBY_API}/server/search" \
        --data-urlencode "q=${EXPECTED_NAME}" --data-urlencode "platform=steam" 2>/dev/null || true
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
    # the list shows is GitHub's, not ours.
    local public
    public="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" 2>/dev/null \
        | sed -n 's/^SERVER_PUBLIC=//p' | head -1)"
    if [[ "${public,,}" != "true" ]]; then
        log_warn "Not run: the server is private (SERVER_PUBLIC=${public:-unset}), so it is not listed in a server browser"
        log_warn "Set E2E_SERVER_PUBLIC=true only on a disposable network: a public server is listed in Palworld's community browser under this machine's public IP"
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
        log_warn "Not run: could not learn this runner's public address, so its listing cannot be found"
        exit 77
    fi

    local attempt answer entry="" answered=0
    for (( attempt = 1; attempt <= LISTING_ATTEMPTS; attempt++ )); do
        answer="$(lobby_search)"
        if jq -e '.server_list | type == "array"' <<< "${answer}" >/dev/null 2>&1; then
            answered=1
            entry="$(jq -c --arg ip "${address}" --argjson port "${GAME_PORT}" \
                '[.server_list[] | select(.address == $ip and .port == $port)] | first // empty' <<< "${answer}")"
            [[ -n "${entry}" ]] && break
        fi
        log_info "Not in the community server list yet (attempt ${attempt}/${LISTING_ATTEMPTS}); retrying"
        sleep "${LISTING_INTERVAL}"
    done

    if [[ ${answered} -eq 0 ]]; then
        log_warn "Not run: Palworld's lobby service (${LOBBY_API}) did not answer, so the listing could not be checked"
        exit 77
    fi
    if [[ -z "${entry}" ]]; then
        log_error "The community server list has no '${EXPECTED_NAME}' at this runner's address on port ${GAME_PORT}"
        log_error "Entries under that name: $(jq -c '[.server_list[] | {name, port, max_players, version}]' <<< "${answer}" 2>/dev/null)"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    local listed_name listed_slots listed_players listed_version failed=0
    listed_name="$(jq -r '.name' <<< "${entry}")"
    listed_slots="$(jq -r '.max_players' <<< "${entry}")"
    listed_players="$(jq -r '.current_players' <<< "${entry}")"
    listed_version="$(jq -r '.version' <<< "${entry}")"
    log_info "The community list shows: name='${listed_name}' players=${listed_players}/${listed_slots} version=${listed_version}"

    if [[ "${listed_name}" == "${EXPECTED_NAME}" ]]; then
        log_success "Listed under the configured name"
    else
        log_error "Expected name '${EXPECTED_NAME}', the list shows '${listed_name}'"
        failed=1
    fi
    if [[ "${listed_slots}" == "${EXPECTED_SLOTS}" ]]; then
        log_success "It advertises the configured ${EXPECTED_SLOTS} slots"
    else
        log_error "Expected ${EXPECTED_SLOTS} slots, the list shows ${listed_slots}"
        failed=1
    fi

    # The count the idle guard reads, through the same function it calls,
    # against the count players see in the list. Two views of one fact.
    local counted
    counted="$(MSYS_NO_PATHCONV=1 docker exec "${CONTAINER}" bash -c 'source /opt/palworld/scripts/common && get_player_count' 2>/dev/null)" || true
    if [[ "${counted}" =~ ^[0-9]+$ ]] && [[ "${counted}" == "${listed_players}" ]]; then
        log_success "The listed player count (${listed_players}) matches the one the idle guard reads over the REST API"
    else
        log_error "The list says ${listed_players} players; the idle guard's count from the REST API says '${counted:-<nothing>}'"
        failed=1
    fi
    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi

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
