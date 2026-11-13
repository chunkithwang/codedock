import XCTest
@testable import Codedock
import CodedockCore

/// Locks in the wire-level pieces of Google Antigravity support (#215). Google
/// Antigravity is a Gemini-based IDE/CLI and a SEPARATE product from the existing
/// "antigravity" source (a Claude-Code fork reading .antigravity/settings.json).
/// These assertions guard the parts that don't need a live Antigravity install:
/// source recognition + aliasing (must NOT collide with the fork), the new
/// `.antigravityNamed` HookFormat, the Claude-style PascalCase event list, and the
/// named-config wrapper the installer writes to ~/.gemini/config/hooks.json.
final class GoogleAntigravitySupportTests: XCTestCase {

    // MARK: - Source recognition / aliasing (no collision with the Claude fork)

    func testGoogleAntigravityIsRecognizedAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("google-antigravity"), "google-antigravity")
    }

    func testGoogleAntigravityAliasesNormalizeToGoogleAntigravity() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("googleantigravity"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("google antigravity"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity-ide"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity-cli"), "google-antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("agy"), "google-antigravity")
        // Prefix-match path: any future "google-antigravity-*" sub-brand folds in.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("google-antigravity-pro"), "google-antigravity")
    }

    func testExistingAntigravityForkAliasesStayPointedAtTheFork() {
        // CRITICAL: retargeting these would break existing AntiGravity-fork users.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity"), "antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("ag"), "antigravity")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("anti-gravity"), "antigravity")
        // A bare "antigravity-something" still resolves to the fork, NOT Google's.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("antigravity-pro"), "antigravity")
    }

    func testGoogleAntigravityDisplayLabel() {
        var snapshot = SessionSnapshot()
        snapshot.source = "google-antigravity"
        XCTAssertEqual(snapshot.sourceLabel, "Google Antigravity")
    }

    // MARK: - EventNormalizer (Antigravity uses Claude-style PascalCase)

    func testAntigravityEventNamesPassThroughNormalizerUnchanged() {
        // Antigravity hooks.json uses PreToolUse/PostToolUse/Stop — already internal
        // names — so they must survive normalize() verbatim (NOT the Gemini
        // Before/After mapping, which targets settings.json, not hooks.json).
        XCTAssertEqual(EventNormalizer.normalize("PreToolUse"), "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize("PostToolUse"), "PostToolUse")
        XCTAssertEqual(EventNormalizer.normalize("Stop"), "Stop")
    }

    func testBeforeToolNormalizesToPermissionRequest() {
        XCTAssertEqual(EventNormalizer.normalize("BeforeTool"), "PermissionRequest")
    }

    // MARK: - HookFormat round-trip

    func testHookFormatAntigravityNamedRoundTripsThroughStorageValue() {
        XCTAssertEqual(HookFormat.antigravityNamed.storageValue, "antigravityNamed")
        XCTAssertEqual(HookFormat(storageValue: "antigravityNamed"), .antigravityNamed)
        XCTAssertEqual(HookFormat(storageValue: "antigravitynamed"), .antigravityNamed) // case-insensitive
    }

    // MARK: - Default events

    func testAntigravityDefaultEventsAreClaudeStylePascalCase() {
        let names = ConfigInstaller.defaultEvents(for: .antigravityNamed).map { $0.0 }
        XCTAssertEqual(names, ["PreToolUse", "PostToolUse", "Stop"])
    }

    // MARK: - Named-config writer (~/.gemini/config/hooks.json shape)

    func testAntigravityNamedWriterEmitsNamedConfigWrapperWithEventFlag() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("hooks.json").path
        let cli = CLIConfig(
            name: "Google Antigravity",
            source: "google-antigravity",
            configPath: configPath,
            configKey: "codedock",
            format: .antigravityNamed,
            events: ConfigInstaller.defaultEvents(for: .antigravityNamed)
        )

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))

        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Outer object MUST be keyed by the named-config wrapper "codedock"
        // (NOT a bare "hooks" key — Antigravity would not recognize that).
        let wrapper = try XCTUnwrap(root["codedock"] as? [String: Any])
        XCTAssertNil(root["hooks"], "Antigravity must NOT use the bare hooks root key")

        // Tool-use events use grouped handlers.
        for event in ["PreToolUse", "PostToolUse"] {
            let entries = try XCTUnwrap(wrapper[event] as? [[String: Any]], "missing event \(event)")
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry["matcher"] as? String, "*")
            let hookList = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
            let hook = try XCTUnwrap(hookList.first)
            XCTAssertEqual(hook["type"] as? String, "command")
            XCTAssertNotNil(hook["timeout"])
            let command = try XCTUnwrap(hook["command"] as? String)
            // stdin lacks hook_event_name, so the command MUST carry --event.
            XCTAssertTrue(command.contains("codedock-bridge --source google-antigravity"))
            XCTAssertTrue(command.contains("--event \(event)"))
        }

        // Stop is a flat command handler in Antigravity 2.8.1+. Grouping it
        // under `hooks` makes Antigravity reject the entire hooks.json file.
        let stopEntry = try XCTUnwrap((wrapper["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual(stopEntry["type"] as? String, "command")
        XCTAssertNotNil(stopEntry["timeout"])
        let stopCommand = try XCTUnwrap(stopEntry["command"] as? String)
        XCTAssertTrue(stopCommand.contains("codedock-bridge --source google-antigravity"))
        XCTAssertTrue(stopCommand.contains("--event Stop"))
        XCTAssertNil(stopEntry["hooks"], "Stop must not use the grouped tool-event shape")
        XCTAssertNil(stopEntry["matcher"], "Stop must not include a tool matcher")
    }

    func testAntigravityInstallMigratesLegacyWrappersAndInvalidStopShape() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("hooks.json").path
        let cli = CLIConfig(
            name: "Google Antigravity",
            source: "google-antigravity",
            configPath: configPath,
            configKey: "codedock",
            format: .antigravityNamed,
            events: ConfigInstaller.defaultEvents(for: .antigravityNamed)
        )
        let original = """
        {
          "codeisland": {
            "Stop": [{"hooks": [{"type": "command", "command": "~/.codeisland/codeisland-bridge --source google-antigravity --event Stop", "timeout": 5}]}]
          },
          "codedock": {
            "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.codedock/codedock-bridge --source google-antigravity --event PreToolUse", "timeout": 86400}]}],
            "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.codedock/codedock-bridge --source google-antigravity --event PostToolUse", "timeout": 5}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "~/.codedock/codedock-bridge --source google-antigravity --event Stop", "timeout": 5}]}]
          },
          "third-party": {
            "Stop": [{"type": "command", "command": "/usr/bin/true", "timeout": 5}]
          }
        }
        """
        XCTAssertTrue(fm.createFile(atPath: configPath, contents: Data(original.utf8)))

        XCTAssertFalse(
            ConfigInstaller.isHooksInstalled(for: cli, fm: fm),
            "legacy grouped Stop must trigger startup repair"
        )
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertTrue(ConfigInstaller.isHooksInstalled(for: cli, fm: fm))

        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["codeisland"], "legacy wrapper would keep the whole file invalid")
        XCTAssertNotNil(root["third-party"], "unrelated named configs must be preserved")

        let wrapper = try XCTUnwrap(root["codedock"] as? [String: Any])
        let stopEntry = try XCTUnwrap((wrapper["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual(stopEntry["type"] as? String, "command")
        XCTAssertNotNil(stopEntry["command"])
        XCTAssertNil(stopEntry["hooks"])
    }

    func testGoogleAntigravityPreToolUseRoutesToPermission() async throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "test-sess",
            "_source": "google-antigravity",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf foo"]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))
        
        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .permission)
    }

    func testGeminiSourcePreToolUseRoutesToPermission() async throws {
        // agy CLI uses --source gemini and sends hook_event_name: "PreToolUse" in
        // its JSON payload, overriding the --event BeforeTool fallback.
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "test-gemini-sess",
            "_source": "gemini",
            "tool_name": "run_command",
            "tool_input": ["CommandLine": "rm -rf bar"]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .permission,
            "agy CLI (--source gemini) PreToolUse must be treated as a blocking permission event")
    }

    func testAgyToolCallParsing() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "conversationId": "3ff64dc8-11bd-4f7e-9a97-495badd58069",
            "_source": "gemini",
            "toolCall": [
                "name": "run_command",
                "args": [
                    "CommandLine": "ls -la"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        XCTAssertEqual(event.toolName, "run_command")
        XCTAssertEqual(event.toolInput?["CommandLine"] as? String, "ls -la")
        XCTAssertEqual(event.toolDescription, "ls -la")
    }
}
