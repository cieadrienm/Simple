#!/usr/bin/env python3
"""osc-send.py <port> <address> [arguments...]: sends one OSC message to this Mac.

Arguments which look like integers are sent as int, other numbers as float, anything else as a string.
"""
import socket
import struct
import sys


def osc_string(text):
    data = text.encode() + b"\0"
    return data + b"\0" * (-len(data) % 4)


def message(address, arguments):
    tags, values = ",", b""
    for argument in arguments:
        try:
            values += struct.pack(">i", int(argument))
            tags += "i"
        except ValueError:
            try:
                values += struct.pack(">f", float(argument))
                tags += "f"
            except ValueError:
                values += osc_string(argument)
                tags += "s"
    return osc_string(address) + osc_string(tags) + values


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.sendto(message(sys.argv[2], sys.argv[3:]), ("127.0.0.1", int(sys.argv[1])))
