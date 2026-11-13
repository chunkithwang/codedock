# codedock Project Memory

## Architecture: Bridge + Server Permission Routing

Two files must stay in sync for permission/blocking events:
- `Sources/CodedockBridge/main.swift` — `isPermission` flag (controls socket blocking)
- `Sources/Codedock/HookServer.swift` — `routeKind(for:)` (controls UI routing)

**Always update both** when adding new CLI source support. See rule:
`.omg/rules/learned/hookserver-and-bridge-permission-routing-must-stay-in-sync.md`

---

## Gemini-Based CLI Sources

Both `--source gemini` (agy) and `--source google-antigravity` share hook
payload structure. They both:
- Send `hook_event_name: "PreToolUse"` in JSON (not `"BeforeTool"`)
- Omit `cwd` — bridge injects it from `FileManager.default.currentDirectoryPath`
- Need `PreToolUse` treated as a blocking permission event

Use `isGeminiBasedSource = (source == "gemini" || source == "google-antigravity")`
as a named variable rather than duplicating inline checks.

See rules:
- `.omg/rules/learned/agy-hook-event-name-is-pretooluse.md`
- `.omg/rules/learned/gemini-bridge-inject-cwd.md`
- `.omg/rules/learned/gemini-and-google-antigravity-are-both-gemini-based.md`
- `.omg/rules/learned/google_antigravity_toolcall_payload.md`
- `.omg/rules/learned/terminal_focus_stealing_bridge_delay.md`

---

## Testing agy Hook Events

**Never run `agy` from within the agent's `run_command` tool** — it hangs (no TTY).

To test bridge+server pipeline end-to-end, pipe a mock payload:
```bash
CODEDOCK_DEBUG=1 echo '{"hook_event_name":"PreToolUse","session_id":"test","tool_name":"Bash","tool_input":{"command":"rm -rf bar"}}' \
  | /Users/matthewgold/.codedock/codedock-bridge --source gemini --event BeforeTool
```

Instruct the user to run `agy` from their own interactive terminal for real tests.

See rule: `.omg/rules/learned/agy-cannot-run-in-background-agent-shell.md`

---

## Build & Deploy

```bash
./build.sh               # arm64-only build + bundle
cp -R .build/release/codedock.app /Applications/codedock.app
pkill -x codedock; open /Applications/codedock.app
```

Bridge binary auto-extracts from app bundle to `~/.codedock/codedock-bridge` on first launch.

See rule:
- `.omg/rules/learned/macos_app_bundle_overwrite.md`
