from flask import Flask, request
import base64
import hashlib
from threading import Lock

app = Flask(__name__)
lock = Lock()

def compute_checksum_bytes(data_bytes):
    return hashlib.sha256(data_bytes).hexdigest()

state = {
    "version": 0,
    "data": b""
}
state["checksum"] = compute_checksum_bytes(state["data"])

@app.get("/state")
def get_state_meta():
    return {
        "version": state["version"],
        "checksum": state["checksum"]
    }

@app.get("/state/full")
def get_state_full():
    return {
        "version": state["version"],
        "checksum": state["checksum"],
        "data_b64": base64.b64encode(state["data"]).decode()
    }

@app.post("/state")
def update_state():
    incoming = request.json

    if not incoming or "version" not in incoming or "data_b64" not in incoming:
        return {"error": "invalid payload"}, 400

    with lock:
        if incoming["version"] != state["version"]:
            return {"error": "version mismatch"}, 409

        data_bytes = base64.b64decode(incoming["data_b64"])
        checksum = compute_checksum_bytes(data_bytes)

        state["data"] = data_bytes
        state["checksum"] = checksum
        state["version"] += 1

        return {
            "version": state["version"],
            "checksum": state["checksum"]
        }

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5678)