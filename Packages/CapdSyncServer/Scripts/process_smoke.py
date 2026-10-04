"""Exercise a built host with disposable synthetic enrollment and storage. Never contacts the NAS."""
import base64
import hashlib
import http.client
import json
import pathlib
import re
import secrets
import subprocess
import sys
import tempfile
import time
import uuid


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main(binary):
    check(subprocess.run([binary, "--help"], capture_output=True).returncode == 0, "help")
    check(subprocess.run([binary], capture_output=True).returncode != 0, "explicit paths required")
    with tempfile.TemporaryDirectory(prefix="capd-host-process-") as directory:
        root = pathlib.Path(directory)
        config_path = root / "enrollment.json"
        service, library, device = [str(uuid.uuid4()) for _ in range(3)]
        credential = secrets.token_hex(32)
        config = {"serviceID": service, "enrollments": [{"libraryID": library, "deviceID": device,
            "credentialSHA256": hashlib.sha256(credential.encode()).hexdigest(), "revoked": False}]}

        def save_config():
            temporary = root / "new-config.json"
            temporary.write_text(json.dumps(config))
            temporary.replace(config_path)

        save_config()
        log_path = root / "server.log"
        process = None
        log = None

        def stop():
            nonlocal process, log
            if process is not None:
                process.terminate()
                code = process.wait(timeout=15)
                check(code == 0, "graceful SIGTERM")
                process = None
            if log is not None:
                log.close()
                log = None

        def start():
            nonlocal process, log
            log = log_path.open("w")
            process = subprocess.Popen([binary, "--config", str(config_path), "--data-dir",
                str(root / "data"), "--port", "0"], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                check(process.poll() is None, "server startup")
                match = re.search(r"ready 127\.0\.0\.1:(\d+)", log_path.read_text())
                if match:
                    return int(match.group(1))
                time.sleep(0.05)
            raise AssertionError("server readiness timeout")

        def request(action, *, token=credential, asserted_library=library, asserted_device=device,
                    duplicate=None, raw=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
            body = raw if raw is not None else json.dumps({"version": 1, "expectedServiceID": service,
                "expectedLibraryID": asserted_library, "expectedDeviceID": asserted_device,
                "action": action}).encode()
            connection.putrequest("POST", "/v1/sync")
            connection.putheader("Content-Type", "application/json")
            if token is not None:
                connection.putheader("Authorization", "Bearer " + token)
            if duplicate:
                connection.putheader(duplicate, "Bearer invalid" if duplicate == "Authorization" else "application/json")
            connection.putheader("Content-Length", str(len(body)))
            connection.endheaders(body)
            response = connection.getresponse()
            data = response.read()
            status = response.status
            connection.close()
            return status, json.loads(data)

        try:
            port = start()
            baseline = {"baseline": {}}
            check(request(baseline, token=None)[0] == 401, "unauthorized")
            check(request(baseline, duplicate="Authorization")[0] == 400, "duplicate authorization")
            check(request(baseline, duplicate="Content-Type")[0] == 400, "duplicate content type")
            check(request(baseline, asserted_device=str(uuid.uuid4()))[0] == 403, "wrong device")
            check(request(baseline, asserted_library=str(uuid.uuid4()))[0] == 403, "wrong library")
            check(request(baseline)[1]["result"]["baseline"]["_0"]["captures"] == [], "assertions did not mutate")
            check(request(baseline, raw=b"x" * (16_777_216 + 1))[0] == 413, "bounded body")
            blob_bytes = b"synthetic image bytes"
            blob = {"digest": hashlib.sha256(blob_bytes).hexdigest(), "byteCount": len(blob_bytes)}
            upload = {"upload": {"_0": blob, "offset": 0, "chunk": base64.b64encode(blob_bytes).decode(), "final": True}}
            check(request(upload)[0] == 200, "blob upload")
            check(request({"download": {"_0": blob}})[1]["result"]["data"]["_0"] == base64.b64encode(blob_bytes).decode(), "blob download")
            capture_id = str(uuid.uuid4())
            capture = {"id": capture_id, "source": {"kind": "image", "blob": blob}, "createdAt": 0,
                "revision": 0, "deleted": False, "seenCount": 1, "note": "synthetic process capture",
                "noteRevision": 0, "noteOperationID": str(uuid.uuid4()), "noteConflicts": [], "rating": 3,
                "manualTags": [], "generated": {"tags": []}}
            operation = {"id": str(uuid.uuid4()), "deviceID": device, "sequence": 1,
                "captureID": capture_id, "baseRevision": 0, "mutation": {"create": {"_0": capture}}}
            action = {"apply": {"_0": operation}}
            first = request(action)
            check(first[0] == 200, "apply")
            check(request(action) == first, "exact receipt on retry")
            page = request({"changes": {"cursor": 0, "limit": 100}})[1]["result"]["page"]["_0"]
            check(len(page["changes"]) == 1, "exactly one feed entry")
            state = request(baseline)[1]["result"]["baseline"]["_0"]
            check(state["captures"][0]["seenCount"] == 1, "exactly one mutation")
            config["enrollments"][0]["revoked"] = True
            save_config()
            check(request(baseline)[0] == 401, "live revocation")
            config["enrollments"][0]["revoked"] = False
            config["serviceID"] = str(uuid.uuid4())
            save_config()
            check(request(baseline)[0] == 503, "service reload fails closed")
            config["serviceID"] = service
            save_config()
            stop()
            port = start()
            check(request(baseline)[1]["result"]["baseline"]["_0"] == state, "restart persistence")
            check(request(action) == first, "receipt survives restart")
            check(request({"download": {"_0": blob}})[0] == 200, "blob survives restart")
            stop()
            config["serviceID"] = str(uuid.uuid4())
            save_config()
            failed = subprocess.run([binary, "--config", str(config_path), "--data-dir", str(root / "data"), "--port", "0"],
                capture_output=True, timeout=15)
            check(failed.returncode != 0, "changed service cannot reuse data root")
            check(credential not in log_path.read_text(), "no credentials in logs")
            print("PASS: auth, assertions, header/body bounds, apply/feed/exact retry, blobs, revocation, restart and SIGTERM")
        finally:
            stop()


if __name__ == "__main__":
    main(str(pathlib.Path(sys.argv[1]).resolve()))
