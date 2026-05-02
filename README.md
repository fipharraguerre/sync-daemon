# talespire-sync

A minimal directory sync tool for keeping a [TaleSpire](https://talespire.com/) Symbiote state directory consistent across multiple Windows machines. Built for small groups playing together who want shared toolset state without cloud accounts or complex infrastructure.

## How it works

A lightweight Flask server (`sync-server.py`) acts as the single source of truth, holding the current state as a versioned zip archive. Each client (`talespire-sync.ps1`) polls the server every N seconds and either pushes a local change or pulls a remote one.

Conflict resolution is intentional and simple: **last writer wins**. The server uses an optimistic version counter — a push is rejected with `409` if the client's version is stale, at which point the client pulls instead. There is no merge, no diff, no manual resolution. For a single shared config directory edited by one person at a time, this is sufficient.

## Design principles

- **Minimal surface area.** Two files, no dependencies beyond Flask and vanilla PowerShell. Easy to read, easy to audit, easy to hand to friends.
- **Server is dumb, clients are dumb.** The server stores one zip blob and a version number. Clients poll and push. No websockets, no pub/sub, no message queues.
- **No unnecessary polling.** The client hashes the local directory contents each tick and only pushes when something has changed. The server is not hit unnecessarily.
- **Remote always wins on conflict.** When a push is rejected (409), the client discards its local state and pulls. This avoids interactive prompts, which matters for the eventual `.exe` distribution.
- **Graceful degradation.** If the server is unreachable, the client logs and skips the tick. It does not crash or corrupt the local files.

## Server

Requires Python 3 and Flask:

```bash
pip install flask
python sync-server.py
```

Runs on port `5678` by default. On startup the server scans the `versions/` directory (created automatically alongside `sync-server.py`) and resumes from the last saved state. A restart is transparent to clients.

### Version history

Every successful push is saved as a zip file under `versions/`, named `v{version}_{timestamp}_{client}.zip`. Files older than 90 days are deleted automatically after each push, but the most recent version is always kept regardless of age. Since the synced contents are primarily text, the zip files are small — many versions accumulate with negligible disk use.

## Client

The client syncs the TaleSpire Symbiote `.localstorage` directory by default. No configuration is needed for standard TaleSpire installations.

Run with standard PowerShell 5+. No modules required:

```powershell
powershell -ExecutionPolicy Bypass -File talespire-sync.ps1
```

To sync a different directory, pass it as a parameter:

```powershell
powershell -ExecutionPolicy Bypass -File talespire-sync.ps1 -SyncDir "C:\path\to\your\directory"
```

To point at a different server, edit the config block at the top of `talespire-sync.ps1`:

```powershell
$ApiBase   = "https://your-server"
$PollEvery = 30   # seconds
```

Can be compiled to a standalone `.exe` with [ps2exe](https://github.com/MScholtes/PS2EXE) (no ExecutionPolicy dependency):

```powershell
Install-Module ps2exe
Invoke-ps2exe talespire-sync.ps1 talespire-sync.exe
```

## Known limitations

- **Last writer wins, silently.** If two clients push within the same poll window, one will lose its changes without warning. In practice this means: don't edit the Symbiote toolset simultaneously.
- **No authentication.** The endpoint is public. Anyone with the URL can read or overwrite the directory. Acceptable for a private VPS among friends; not for anything sensitive.
- **Merge on pull, not replace.** When pulling, the client unzips and overwrites matching files but leaves unrecognised local files untouched. This is intentional — files written by TaleSpire or other tools into the same directory are not clobbered.

## To-do

- [ ] **Auth header.** Add a shared secret (e.g. `X-Sync-Token`) checked on every request server-side. One env variable on the server, one config line on the client.
- [ ] **Compile to `.exe`.** Package with `ps2exe` for distribution to non-technical players. No ExecutionPolicy concerns, no PowerShell window required.
