#!/usr/bin/env python3
"""A fake Steam A2S server, for testing a2s-player-count without a game server.

Usage: fake_a2s_server.py <mode> <player_count>
Prints the port it bound to on stdout, then serves exactly one query flow.

Modes:
  challenge  answer with an A2S_INFO challenge first, as a real server does
  direct     answer the first request with the info reply straight away
  truncated  answer with a reply that stops mid-way through
  garbage    answer with bytes that are not an A2S reply at all
  silent     accept the request and never answer
"""

import socket
import struct
import sys

HEADER = b"\xff\xff\xff\xff"


def info_reply(players):
    body = HEADER + b"I" + struct.pack("<B", 17)
    body += b"Fake Palworld Server\x00"
    body += b"Palworld\x00"          # map
    body += b"Pal\x00"               # folder
    body += b"Palworld\x00"          # game
    # The A2S appid field is only 16 bits, so it cannot hold Palworld's real
    # app id (2394010); servers send a truncated value here. The parser skips
    # this field rather than reading it, so any 16-bit value exercises it.
    body += struct.pack("<H", 2394010 & 0xFFFF)
    body += struct.pack("<B", players)    # players  <- what we assert on
    body += struct.pack("<B", 32)         # max players
    body += struct.pack("<B", 0)          # bots
    return body


def main(argv):
    mode, players = argv[1], int(argv[2])

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1], flush=True)

    _, addr = sock.recvfrom(4096)

    if mode == "silent":
        return 0
    if mode == "garbage":
        sock.sendto(b"definitely not a2s", addr)
        return 0
    if mode == "truncated":
        sock.sendto(info_reply(players)[:12], addr)
        return 0
    if mode == "challenge":
        sock.sendto(HEADER + b"A" + struct.pack("<I", 0x11223344), addr)
        _, addr = sock.recvfrom(4096)

    sock.sendto(info_reply(players), addr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
