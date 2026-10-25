#!/usr/bin/env python3
"""Render a Wings config.yml from the panel's node configuration JSON.

Usage:  api_call GET /nodes/<id>/configuration | render-config.py <output-path>

The input shape is Pterodactyl's Node::getConfiguration() response:
{debug, uuid, token_id, token, api{host,port,ssl{enabled,cert,key},upload_limit},
 system{data,sftp{bind_port}}, allowed_mounts, remote}

Only the Python standard library is used; the output schema is fixed and
shallow, so a tiny hand-rolled emitter is sufficient and avoids a PyYAML
requirement on production nodes.
"""
import json
import os
import sys


def quoted(value) -> str:
    return json.dumps(str(value))


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <output-path>", file=sys.stderr)
        return 2

    cfg = json.load(sys.stdin)
    ssl = cfg.get("api", {}).get("ssl", {})
    sftp = cfg.get("system", {}).get("sftp", {})

    lines = [
        "debug: " + ("true" if cfg.get("debug") else "false"),
        "uuid: " + quoted(cfg["uuid"]),
        "token_id: " + quoted(cfg["token_id"]),
        "token: " + quoted(cfg["token"]),
        "api:",
        "  host: " + quoted(cfg["api"]["host"]),
        "  port: " + str(cfg["api"]["port"]),
        "  ssl:",
        "    enabled: " + ("true" if ssl.get("enabled") else "false"),
        "    cert: " + quoted(ssl.get("cert", "")),
        "    key: " + quoted(ssl.get("key", "")),
        "  upload_limit: " + str(cfg["api"].get("upload_limit", 100)),
        "system:",
        "  data: " + quoted(cfg["system"]["data"]),
        "  sftp:",
        "    bind_port: " + str(sftp["bind_port"]),
        "allowed_mounts: " + json.dumps(cfg.get("allowed_mounts", [])),
        "remote: " + quoted(cfg["remote"]),
    ]

    out = sys.argv[1]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(out, 0o600)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
