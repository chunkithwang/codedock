import XCTest
@testable import Codedock
import CodedockCore

final class AppStateMonitoredActivityTests: XCTestCase {
    func testAllLongRunningSourcesDoNotExpireWithoutCompletionEvidence() {
        let now = Date()

        for source in SessionSnapshot.supportedSources.sorted() {
            var session = SessionSnapshot()
            session.source = source
            session.status = .processing
            session.lastActivity = now.addingTimeInterval(-3_600)

            XCTAssertFalse(
                AppState.shouldMarkMonitoredProcessingIdle(
                    session: session,
                    now: now,
                    finishedTurnTimestamp: nil
                ),
                "\(source) must remain active while its monitored process is alive"
            )
        }
    }

    func testClaudeDesktopDoesNotUseTheOldThirtySecondBlindTimeout() {
        let now = Date()
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.anthropic.claudefordesktop"
        session.status = .processing
        session.lastActivity = now.addingTimeInterval(-600)

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(
            AppState.shouldMarkMonitoredProcessingIdle(
                session: session,
                now: now,
                finishedTurnTimestamp: nil
            )
        )
    }

    func testNativeAIAppsDoNotUseBlindTimeoutsWithoutCompletionEvidence() {
        let now = Date()
        let nativeApps: [(source: String, bundleId: String)] = [
            ("cursor", "com.todesktop.230313mzl4w4u92"),
            ("trae", "com.trae.app"),
            ("qoder", "com.qoder.ide"),
            ("droid", "com.factory.app"),
            ("codebuddy", "com.tencent.codebuddy"),
            ("codybuddycn", "com.tencent.codebuddy.cn"),
            ("stepfun", "com.stepfun.app"),
            ("codex", "com.openai.codex"),
            ("opencode", "ai.opencode.desktop"),
            ("google-antigravity", "com.google.antigravity"),
            ("claude", "com.anthropic.claudefordesktop"),
        ]

        for app in nativeApps {
            var session = SessionSnapshot()
            session.source = app.source
            session.termBundleId = app.bundleId
            session.status = .processing
            session.lastActivity = now.addingTimeInterval(-3_600)

            XCTAssertTrue(session.isNativeAppMode, "Expected native app mode for \(app.source)")
            XCTAssertFalse(
                AppState.shouldMarkMonitoredProcessingIdle(
                    session: session,
                    now: now,
                    finishedTurnTimestamp: nil
                ),
                "\(app.source) must remain active without explicit completion evidence"
            )
        }
    }

    func testReliableNativeCompletionMarkerCanRecoverAMissedStopHook() {
        let now = Date()
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.openai.codex"
        session.status = .processing
        session.lastActivity = now.addingTimeInterval(-10)

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertTrue(
            AppState.shouldMarkMonitoredProcessingIdle(
                session: session,
                now: now,
                finishedTurnTimestamp: session.lastActivity
            )
        )
    }
}
