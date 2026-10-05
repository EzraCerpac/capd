#!/usr/bin/env python3
"""Synthetic subprocess proof: sole sync host, real private socket, MCP stdio.
No live defaults. Arguments are built test executables only. Never prints credentials/data.
"""
import hashlib, http.client, json, os, pathlib, re, secrets, select, shutil, signal, subprocess, sys, tempfile, time, uuid

host_binary, stdio_binary = sys.argv[1:3]
root = pathlib.Path(tempfile.mkdtemp(prefix="capd-probe-", dir="/private/tmp"))
os.chmod(root, 0o700)
service, library, device, writer = (str(uuid.uuid4()) for _ in range(4))
mac, bridge = secrets.token_hex(32), secrets.token_hex(32)
def digest(value): return hashlib.sha256(value.encode()).hexdigest()
def private_json(path, value):
    path.write_text(json.dumps(value))
    os.chmod(path, 0o600)
policy = dict(version=1, serviceID=service, libraryID=library, resource="https://synthetic.example.invalid/mcp", principalID="process-fixture", credentialSHA256=digest(bridge), scopes=["capd:read", "capd:write"], writerDeviceID=writer, revoked=False)
private_json(root / "sync.json", dict(serviceID=service, enrollments=[dict(libraryID=library, deviceID=device, credentialSHA256=digest(mac), revoked=False)]))
private_json(root / "bridge.json", policy)
(root / "token").write_text(bridge)
os.chmod(root / "token", 0o600)
socket = root / "authority.sock"
log = open(root / "host.log", "w")
host = subprocess.Popen([host_binary, "--config", str(root / "sync.json"), "--data-dir", str(root / "data"), "--port", "0", "--mcp-bridge-config", str(root / "bridge.json"), "--mcp-socket", str(socket)], stdout=log, stderr=log)
client = None
try:
    end = time.monotonic() + 15
    port = None
    while time.monotonic() < end:
        assert host.poll() is None, "Synthetic host startup failed"
        text = (root / "host.log").read_text()
        match = re.search(r"capd-sync-server ready 127\.0\.0\.1:(\d+)", text)
        if match and "capd-mcp-bridge ready private socket" in text:
            port = int(match[1]); break
        time.sleep(0.02)
    assert port and socket.stat().st_mode & 0o777 == 0o600, "Private listener readiness failed"
    def baseline():
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=6)
        try:
            conn.request("POST", "/v1/sync", json.dumps(dict(version=1, expectedServiceID=service, expectedLibraryID=library, expectedDeviceID=device, action=dict(baseline={}))), {"Content-Type": "application/json", "Authorization": "Bearer " + mac})
            response = conn.getresponse()
            assert response.status == 200, "Ordinary sync request failed"
            return json.loads(response.read())["result"]["baseline"]["_0"]
        finally: conn.close()
    # MCP cannot initialize absent storage; the enrolled synthetic device does so.
    baseline()
    client = subprocess.Popen([stdio_binary, "--credential-file", str(root / "token"), "--socket", str(socket)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    counter = 0
    def rpc(method, params=None):
        global counter
        counter += 1
        value = dict(jsonrpc="2.0", id=counter, method=method, params=params or {})
        client.stdin.write(json.dumps(value).encode() + b"\n"); client.stdin.flush()
        assert select.select([client.stdout], [], [], 8)[0], "Bounded stdio response missing"
        reply = json.loads(client.stdout.readline())
        assert reply.get("id") == counter, "Response identity mismatch"
        return reply
    initialized = rpc("initialize", dict(protocolVersion="2025-06-18", capabilities={}, clientInfo=dict(name="synthetic-probe", version="1")))
    assert "result" in initialized, "Initialization failed"
    listed = rpc("tools/list")["result"]["tools"]
    assert len(listed) == 5 and all(t["securitySchemes"] == [dict(type="noauth")] for t in listed), "Tool scope/auth presentation failed"
    def call(name, args): return rpc("tools/call", dict(name=name, arguments=args))
    capture, operation = str(uuid.uuid4()), str(uuid.uuid4())
    arguments = dict(operation_id=operation, sequence=1, id=capture, kind="text", created_at="2026-10-04T10:00:00Z", text="synthetic-process-fixture")
    created = call("create_capture", arguments)
    assert created["result"]["isError"] is False, "Synthetic create failed"
    assert call("create_capture", arguments)["result"]["isError"] is False, "Exact write retry failed"
    assert len(baseline()["captures"]) == 1, "Shared authority sync visibility failed"
    assert call("get_capture", dict(id=capture))["result"]["isError"] is False, "Synthetic get failed"
    assert call("search_captures", dict(query="synthetic", limit=1))["result"]["isError"] is False, "Synthetic search failed"
    assert call("list_recent", dict(limit=1))["result"]["isError"] is False, "Synthetic recent failed"
    edit = dict(operation_id=str(uuid.uuid4()), sequence=2, id=capture, base_revision=1, note="synthetic-note", add_tags=["synthetic"], rating=4)
    assert call("edit_capture", edit)["result"]["isError"] is False, "Synthetic edit failed"
    # Every request re-reads the policy; neither transport nor stdio caches a grant.
    policy["revoked"] = True
    private_json(root / "bridge.json", policy)
    assert "error" in rpc("tools/list"), "Revoked bridge credential was accepted"
    assert len(baseline()["captures"]) == 1, "Revocation changed ordinary sync"
    print("PASS: private socket0600, initialized MCP, five tools, exact retry, same-authority sync visibility, fresh revocation; synthetic only")
except Exception:
    text = (root / "host.log").read_text().replace(mac, "[redacted]").replace(bridge, "[redacted]")
    print(text, file=sys.stderr)
    raise
finally:
    if client:
        client.terminate()
        try: client.wait(timeout=3)
        except subprocess.TimeoutExpired: client.kill(); client.wait()
    host.send_signal(signal.SIGTERM)
    try: host.wait(timeout=5)
    except subprocess.TimeoutExpired: host.kill(); host.wait()
    log.close()
    if host.returncode == 0:
        assert not socket.exists(), "Graceful shutdown left a socket placeholder"
    shutil.rmtree(root)
