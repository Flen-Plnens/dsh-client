# DSH Client

> A Flutter client for DeepSeek Harness.

DSH Client is a native Flutter desktop client that talks to a
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) server
directly over its wire protocol (HTTP RPC + WebSocket event streams) — no
embedded browser, no WebView shell. Point it at your Harness service address
(e.g. `http://127.0.0.1:3080`) and connect.

## Features

Implemented and verified in the current release:

- **Harness session connection** — service address, `host.describe` handshake,
  dual WebSocket downlinks, connection status and automatic reconnection
- **Session browsing & search** — workspace/session lists, live titles,
  content + name search
- **Model selection** — model catalog picker with **reasoning effort**
  (Off / High / Max)
- **Messaging** — regular `queue` prompts and `steer` (long-press send),
  pending-queue management (remove / edit / steer)
- **question / approval** — answer model questions, allow-once or reject
  approvals
- **Commands** — slash commands (`/...`) with a command picker and inline
  execution status
- **Goals** — set / edit / pause / resume / complete / clear a long-running
  goal
- **Subagent sessions** — child-session panel, open and interrupt
- **Markdown & code blocks** — rendered messages with syntax highlighting
- **Image input path** — pick images from disk and attach them to messages
  (requires a vision-capable model)
- **Workspace & session management** — create / rename / delete / reorder
  workspaces, archive / fork / rename / export (ZIP) sessions

## Requirements

- **Windows x64** (portable Release build)
- A running **DeepSeek Harness** server (verified against `0.1.0-rc.6`);
  default service address `http://127.0.0.1:3080`
- **Flutter SDK** — only needed to build from source (developers)

## Download

**Windows x64 portable release** — download the ZIP from the
[GitHub Releases](https://github.com/Flen-Plnens/dsh-client/releases) page,
extract it anywhere, and run `dsh_client.exe`. The ZIP contains the full
Release directory (executable, runtime DLLs, and `data/`), so it runs
standalone — no installation required.

## Build from source

```sh
flutter pub get
flutter build windows --release
```

The Release bundle is produced at
`build/windows/x64/runner/Release/`. A convenience packaging script is also
provided:

```sh
pwsh -File scripts/build_windows_release.ps1
```

which zips the Release into `build/releases/DSH-Client-<version>-windows-x64.zip`
with a SHA-256 checksum.

## Known limitations

- Requires a reachable DeepSeek Harness server. LAN/remote connections need
  the server started with `--trusted-host`; the rc.6 protocol has no
  authentication layer (the trust fence is a reachability policy, not
  identity).
- Image attachments are rejected by the server when the selected model has no
  native image input — the client shows a hint to switch to a vision-capable
  model.
- Archived sessions cannot be un-archived (rc.6 exposes no `unarchive` RPC).
- Streaming output renders as plain text; Markdown is rendered on the final
  message.
- The protocol is not versioned and DeepSeek Harness is still in developer
  preview — this client is verified against `0.1.0-rc.6`.

## License

No license has been chosen for this project yet. Please contact the
maintainer before contributing or redistributing.

## Development

Detailed development notes — implementation status, protocol research, known
issues and roadmap — are kept in a local `DEVELOPMENT.md` file that is not
published with this repository.