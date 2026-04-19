# talespire-sync

A minimal file sync tool for keeping a single [TaleSpire](https://talespire.com/) Symbiote state file consistent across multiple Windows machines. Built for small groups playing together who want shared toolset state without cloud accounts or complex infrastructure.

## How it works

A lightweight Flask server (`sync-server.py`) acts as the single source of truth, holding the current file as a versioned blob. Each client (`talespire-sync.ps1`) polls the server every N seconds and either pushes a local change or pulls a remote one.

Conflict resolution is intentional and simple: **last writer wins**. The server uses an optimistic version counter — a push is rejected with `409` if the client's version is stale, at which point the client pulls instead. There is no merge, no diff, no manual resolution. For a single shared config file edited by one person at a time, this is sufficient.

## Design principles

- **Minimal surface area.** Two files, no dependencies beyond Flask and vanilla PowerShell. Easy to read, easy to audit, easy to hand to friends.
- **Server is dumb, clients are dumb.** The server stores one blob and a version number. Clients poll and push. No websockets, no pub/sub, no message queues.
- **No polling on local changes.** The client hashes the local file each tick and only pushes when the checksum differs from the last synced state. The server is not hit unnecessarily.
- **Remote always wins on conflict.** When a push is rejected (409), the client discards its local state and pulls. This avoids interactive prompts, which matters for the eventual `.exe` distribution.
- **Graceful degradation.** If the server is unreachable, the client logs and skips the tick. It does not crash or corrupt the local file.

## Server

Requires Python 3 and Flask:

```bash
pip install flask
python sync-server.py
```

Runs on port `5678` by default. The server holds state **in memory only** — a restart resets it to version 0 and the first client to connect will re-bootstrap from its local file.

## Client

Edit the config block at the top of `talespire-sync.ps1`:

```powershell
$ApiBase   = "https://your-server"
$FilePath  = "C:\path\to\your\file"
$PollEvery = 30   # seconds
```

Run with standard PowerShell 5+. No modules required. Can be compiled to a standalone `.exe` with [ps2exe](https://github.com/MScholtes/PS2EXE):

```powershell
Install-Module ps2exe
Invoke-ps2exe talespire-sync.ps1 talespire-sync.exe
```

## Known limitations

- **Last writer wins, silently.** If two clients push within the same poll window, one will lose its changes without warning. In practice this means: don't edit the Symbiote toolset simultaneously.
- **No authentication.** The endpoint is public. Anyone with the URL can read or overwrite the file. Acceptable for a private VPS among friends; not for anything sensitive.
- **No persistence on the server.** A server restart requires one client to re-bootstrap. The file is not saved to disk server-side.

## To-do

- [ ] **Auth header.** Add a shared secret (e.g. `X-Sync-Token`) checked on every request server-side. One env variable on the server, one config line on the client.
- [ ] **Server-side persistence.** Write the blob to disk on every successful push and reload it on startup. Prevents data loss on VPS restarts.
- [ ] **Version history.** Keep a rolling window of N previous versions on the server, either as compressed snapshots or binary deltas. Useful as a last resort if a bad state gets pushed and propagated before anyone notices.
