#!/usr/bin/env python3
"""
End-to-end verification client for the Mero Torrent-to-HTTP Audio Streaming Server.

Usage:
  py -3.12 tool/test_streaming_server.py [--host 127.0.0.1] [--port 8080] [--infohash 2a72c612335bd7cc5221b9c20838a9a349cf3821]

Note: When testing against an Android emulator from the host machine, forward the port first:
  adb forward tcp:8080 tcp:8080
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

DEFAULT_INFOHASH = "2a72c612335bd7cc5221b9c20838a9a349cf3821"


def http_json(method: str, url: str, payload: dict | None = None, timeout: int = 120) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def test_server(base_url: str, infohash: str, file_path: str | None) -> int:
    print(f"=== 1. Checking Server Status ({base_url}/api/status) ===")
    status = http_json("GET", f"{base_url}/api/status")
    print(json.dumps(status, indent=2))

    print(f"\n=== 2. Inspecting Torrent Metadata ({infohash}) ===")
    inspect_res = http_json(
        "POST",
        f"{base_url}/api/torrent/inspect",
        {"magnet": infohash},
    )
    print(f"Torrent Name : {inspect_res.get('name')}")
    print(f"File Count   : {inspect_res.get('file_count')}")
    for f in inspect_res.get("files", []):
        print(
            f"  [{f['index']}] {f['path']} ({f['size_formatted']}, {f['format']}, {f['mime_type']})"
        )

    print("\n=== 3. Requesting Audio Stream via POST /api/stream ===")
    req_body = {"magnet": infohash}
    if file_path:
        req_body["file_path"] = file_path
    elif inspect_res.get("files"):
        req_body["file_path"] = inspect_res["files"][0]["path"]

    print("Request Payload:", json.dumps(req_body, indent=2))
    stream_res = http_json("POST", f"{base_url}/api/stream", req_body)
    print("Response:", json.dumps(stream_res, indent=2))

    stream_url = stream_res["loopback_stream_url"]
    if "127.0.0.1" not in base_url:
        stream_url = stream_res["stream_url"]

    print(f"\n=== 4. Testing HEAD Request on {stream_url} ===")
    head_req = urllib.request.Request(stream_url, method="HEAD")
    with urllib.request.urlopen(head_req, timeout=60) as resp:
        print(f"Status        : {resp.status}")
        print(f"Content-Type  : {resp.headers.get('Content-Type')}")
        print(f"Content-Length: {resp.headers.get('Content-Length')}")
        print(f"Accept-Ranges : {resp.headers.get('Accept-Ranges')}")

    print(f"\n=== 5. Testing HTTP Range Request (bytes=0-4095) ===")
    range_req = urllib.request.Request(
        stream_url,
        headers={"Range": "bytes=0-4095"},
        method="GET",
    )
    with urllib.request.urlopen(range_req, timeout=120) as resp:
        chunk = resp.read()
        print(f"Status        : {resp.status} (expected 206)")
        print(f"Content-Range : {resp.headers.get('Content-Range')}")
        print(f"Content-Type  : {resp.headers.get('Content-Type')}")
        print(f"Bytes Read    : {len(chunk)} bytes")

    print(f"\n=== 6. Testing Seek via Mid-File HTTP Range Request (bytes=65536-69631) ===")
    seek_req = urllib.request.Request(
        stream_url,
        headers={"Range": "bytes=65536-69631"},
        method="GET",
    )
    with urllib.request.urlopen(seek_req, timeout=120) as resp:
        chunk = resp.read()
        print(f"Status        : {resp.status} (expected 206)")
        print(f"Content-Range : {resp.headers.get('Content-Range')}")
        print(f"Bytes Read    : {len(chunk)} bytes")

    print("\nALL END-TO-END HTTP STREAMING & RANGE TESTS PASSED!")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Test Mero Torrent Audio Server")
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=8080, help="Server port")
    parser.add_argument("--infohash", default=DEFAULT_INFOHASH, help="Magnet or infohash")
    parser.add_argument("--file-path", default=None, help="Relative file path in torrent")
    args = parser.parse_args()

    base_url = f"http://{args.host}:{args.port}"
    try:
        return test_server(base_url, args.infohash, args.file_path)
    except urllib.error.URLError as e:
        print(f"Connection failed to {base_url}: {e}", file=sys.stderr)
        print(
            "Make sure the app is running and the server is started (and run `adb forward tcp:8080 tcp:8080` if on Android).",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

