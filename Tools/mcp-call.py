#!/usr/bin/env python3
"""mcp-call.py <mcp server executable> <tool> [json arguments]: calls one tool of a stdio MCP server and prints
its answer. With no tool, lists the tools. For checking simple-recorder-mcp from a script."""
import json
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    server = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def request(identifier, method, params=None):
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}}) + "\n")
        server.stdin.flush()
        return json.loads(server.stdout.readline())

    request(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "mcp-call", "version": "1"}})
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    if len(sys.argv) < 3:
        for tool in request(2, "tools/list")["result"]["tools"]:
            print(tool["name"], "-", tool["description"])
        return 0
    arguments = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    result = request(2, "tools/call", {"name": sys.argv[2], "arguments": arguments})["result"]
    for content in result["content"]:
        print(content["text"])
    server.stdin.close()
    return 1 if result.get("isError") else 0


if __name__ == "__main__":
    sys.exit(main())
