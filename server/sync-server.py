from flask import Flask, request
import base64
import hashlib
import zipfile
import io
import os
import re
from datetime import datetime, timedelta, timezone
from threading import Lock
from pathlib import Path

app = Flask(__name__)
lock = Lock()

VERSIONS_DIR = Path(__file__).parent / "versions"
VERSIONS_DIR.mkdir(exist_ok=True)

RETENTION_DAYS = 90

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def compute_checksum(data_bytes: bytes) -> str:
    return hashlib.sha256(data_bytes).hexdigest()

def version_filename(version: int, updated_by: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    safe_client = re.sub(r"[^\w\-]", "_", updated_by or "unknown")
    return f"v{version:06d}_{ts}_{safe_client}.zip"

def parse_version_number(filename: str) -> int:
    """Extract the version integer from a version filename."""
    m = re.match(r"v(\d+)_", filename)
    return int(m.group(1)) if m else -1

def save_version(data_bytes: bytes, version: int, updated_by: str) -> None:
    fname = version_filename(version, updated_by)
    path = VERSIONS_DIR / fname
    path.write_bytes(data_bytes)

def cleanup_old_versions() -> None:
    """Delete version files older than RETENTION_DAYS, but never the newest."""
    files = sorted(VERSIONS_DIR.glob("v*.zip"))
    if not files:
        return

    cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    newest = files[-1]

    for f in files[:-1]:  # never touch newest
        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc)
        if mtime < cutoff:
            f.unlink(missing_ok=True)

def load_latest_version() -> tuple[int, bytes]:
    """
    Scan versions/ for the highest-numbered zip.
    Returns (version, data_bytes) or (0, b"") if none found.
    """
    files = sorted(VERSIONS_DIR.glob("v*.zip"), key=lambda f: parse_version_number(f.name))
    if not files:
        return 0, b""
    latest = files[-1]
    version = parse_version_number(latest.name)
    data = latest.read_bytes()
    return version, data

def validate_zip(data_bytes: bytes) -> bool:
    """Return True if data_bytes is a valid zip archive."""
    try:
        with zipfile.ZipFile(io.BytesIO(data_bytes)):
            return True
    except zipfile.BadZipFile:
        return False

# ---------------------------------------------------------------------------
# Boot: resume from disk
# ---------------------------------------------------------------------------

version_number, blob = load_latest_version()
blob_checksum = compute_checksum(blob)

if version_number > 0:
    print(f"[boot] resumed from disk at version {version_number} ({len(blob):,} bytes)")
else:
    print("[boot] no prior state found, starting fresh")

state = {
    "version":  version_number,
    "data":     blob,
    "checksum": blob_checksum,
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/state")
def get_state_meta():
    return {
        "version":  state["version"],
        "checksum": state["checksum"],
    }

@app.get("/state/full")
def get_state_full():
    return {
        "version":  state["version"],
        "checksum": state["checksum"],
        "data_b64": base64.b64encode(state["data"]).decode(),
    }

@app.post("/state")
def update_state():
    incoming = request.json

    if not incoming or "version" not in incoming or "data_b64" not in incoming:
        return {"error": "invalid payload"}, 400

    with lock:
        if incoming["version"] != state["version"]:
            return {"error": "version mismatch"}, 409

        try:
            data_bytes = base64.b64decode(incoming["data_b64"])
        except Exception:
            return {"error": "invalid base64"}, 400

        if not validate_zip(data_bytes):
            return {"error": "payload is not a valid zip archive"}, 400

        checksum = compute_checksum(data_bytes)
        new_version = state["version"] + 1
        updated_by = incoming.get("updated_by", "unknown")

        # Persist to disk before updating in-memory state
        save_version(data_bytes, new_version, updated_by)
        cleanup_old_versions()

        state["data"]     = data_bytes
        state["checksum"] = checksum
        state["version"]  = new_version

        print(f"[push] version {new_version} from {updated_by} ({len(data_bytes):,} bytes)")

        return {
            "version":  state["version"],
            "checksum": state["checksum"],
        }

# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5678)
