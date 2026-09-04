import Core
import Foundation
import Testing

@testable import Capture
@testable import Store
@testable import openrhyme

@Suite struct PurgeSelectionTests {
    private let policy = PrivacyPolicy(settings: PrivacySettings())

    private func event(
        _ id: Int64, bundle: String? = nil, url: String? = nil, document: String? = nil,
        title: String? = nil
    ) -> RawEvent {
        RawEvent(
            id: id, ts: Double(id), kind: .contextSnapshot, bundleID: bundle, windowTitle: title,
            document: document, url: url)
    }

    @Test func selectsByAppAndURLSubstring() {
        let rows = [
            event(1, bundle: "com.apple.Safari", url: "https://example.com/docs"),
            event(2, bundle: "com.google.Chrome", url: "https://vault.internal/ui/vault/list"),
            event(3, bundle: "com.google.Chrome", document: "https://vault.internal/other"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: "com.apple.Safari", urlContains: nil, applyRules: false,
                policy: policy
            ).map(\.id) == [1])
        // --url-contains matches the url OR the document column.
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: "vault.internal", applyRules: false,
                policy: policy
            ).map(\.id) == [2, 3])
    }

    @Test func applyRulesUsesTheRealPolicy() {
        let rows = [
            event(1, bundle: "com.apple.Safari", url: "https://example.com/docs"),
            event(2, bundle: "com.1password.1password"),
            event(3, bundle: "com.google.Chrome", url: "https://x.example/ui/vault/secrets"),
            event(4, bundle: "com.microsoft.VSCode", document: "/Users/me/app/.env"),
            event(5, bundle: "com.apple.Safari", title: "Private Browsing"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: nil, applyRules: true, policy: policy
            ).map(\.id) == [2, 3, 4, 5])
    }

    @Test func filtersCombineWithAnd() {
        let rows = [
            event(1, bundle: "com.google.Chrome", url: "https://vault.x/ui/vault/"),
            event(2, bundle: "com.apple.Safari", url: "https://vault.x/ui/vault/"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: "com.google.Chrome", urlContains: "vault.x", applyRules: false,
                policy: policy
            ).map(\.id) == [1])
    }

    @Test func noFiltersSelectsEverythingInRange() {
        let rows = [event(1, bundle: "a"), event(2, bundle: "b")]
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: nil, applyRules: false, policy: policy
            ).map(\.id) == [1, 2])
    }

    /// Protected-context marker rows (privacy §5.5) have no url/document/title at all — nil
    /// fields must fall out of the match instead of crashing or (worse) matching everything.
    @Test func nilFieldsNeverCrashOrMatchAsWildcards() {
        let rows = [
            event(1, bundle: "com.a"),  // marker row: no url/document/title
            event(2, bundle: "com.b", url: "https://vault.example/ui/vault/"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: "vault", applyRules: false, policy: policy
            ).map(\.id) == [2])
        // With Foundation imported, `String.contains("")` is false (unlike the bare stdlib
        // method), so an empty --url-contains matches nothing rather than everything — the
        // safe direction for a destructive filter to fail in.
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: "", applyRules: false, policy: policy
            ).isEmpty)
    }
}

/// Unit tests for the retry/lock-handling helpers, using injected clocks and fake delete/vacuum
/// operations so a transient-lock scenario is exercised deterministically and instantly, with no
/// real SQLite lock race and no real sleeping.
@Suite struct PurgeRetryTests {
    private func locked(_ message: String = "database is locked") -> DatabaseError {
        DatabaseError(code: 5, message: message)  // SQLITE_BUSY
    }

    private func noSleep(_ delay: Duration) async throws {}

    @Test func isLockedErrorRecognizesBusyAndLockedButNotOtherErrors() {
        #expect(PurgeCommand.isLockedError(DatabaseError(code: 5, message: "busy")))
        #expect(PurgeCommand.isLockedError(DatabaseError(code: 6, message: "locked")))
        #expect(!PurgeCommand.isLockedError(DatabaseError(code: 1, message: "syntax error")))
        struct OtherError: Error {}
        #expect(!PurgeCommand.isLockedError(OtherError()))
    }

    @Test func retryOnBusySucceedsAfterTransientLocks() async throws {
        var calls = 0
        let result = try await PurgeCommand.retryOnBusy(attempts: 3, sleep: noSleep) {
            calls += 1
            if calls < 3 { throw locked() }
            return "ok"
        }
        #expect(result == "ok")
        #expect(calls == 3)
    }

    @Test func retryOnBusyGivesUpAfterExhaustingAttempts() async throws {
        var calls = 0
        await #expect(throws: DatabaseError.self) {
            try await PurgeCommand.retryOnBusy(attempts: 3, sleep: noSleep) {
                calls += 1
                throw locked()
            }
        }
        #expect(calls == 3, "must not retry forever")
    }

    @Test func retryOnBusyNeverRetriesANonLockError() async throws {
        var calls = 0
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await PurgeCommand.retryOnBusy(attempts: 3, sleep: noSleep) {
                calls += 1
                throw Boom()
            }
        }
        #expect(calls == 1, "a non-lock error must surface immediately")
    }

    @Test func deleteWithRetryRecoversFromATransientLockWithoutLosingCount() async throws {
        var attemptsForFirstChunk = 0
        let deleted = try await PurgeCommand.deleteWithRetry(
            ids: Array(1...5), attempts: 3, sleep: noSleep
        ) { chunk in
            attemptsForFirstChunk += 1
            if attemptsForFirstChunk < 2 { throw locked() }
            return chunk.count
        }
        #expect(deleted == 5)
        #expect(attemptsForFirstChunk == 2)
    }

    @Test func deleteWithRetryReportsExactProgressWhenItGivesUp() async throws {
        // Two 500-row-max chunks (600 ids); the first succeeds outright, the second is
        // permanently locked and never recovers even after retrying.
        var callCount = 0
        do {
            _ = try await PurgeCommand.deleteWithRetry(
                ids: Array(1...600), attempts: 2, sleep: noSleep
            ) { chunk in
                callCount += 1
                if callCount == 1 { return chunk.count }  // first 500-row chunk succeeds
                throw self.locked()  // second chunk (remaining 100) never recovers
            }
            Issue.record("expected deleteWithRetry to throw")
        } catch let failure as PurgeCommand.PartialDeleteFailure {
            // The 500 rows from the first, successful chunk must never be lost from the count,
            // even though the overall operation ultimately failed.
            #expect(failure.deleted == 500)
            #expect(PurgeCommand.isLockedError(failure.underlying))
        }
    }

    @Test func destroyReturnsVacuumedFalseAndAWarningWhenVacuumNeverRecovers() async throws {
        let event = RawEvent(id: 1, ts: 0, kind: .contextSnapshot)
        let outcome = try await PurgeCommand.destroy(
            selected: [event], deleteAttempts: 2, vacuumAttempts: 2, sleep: noSleep,
            delete: { $0.count },
            vacuum: { throw self.locked() })
        #expect(outcome.result.deleted == 1)
        #expect(outcome.result.matched == 1)
        #expect(!outcome.result.vacuumed)
        #expect(!outcome.result.dryRun)
        let warning = try #require(outcome.vacuumWarning)
        #expect(warning.lowercased().contains("vacuum"))
        #expect(warning.contains("1"))
        // Never claim an unqualified success.
        let human = PurgeCommand.humanLines(outcome.result)
        #expect(human.contains("WARNING"))
        #expect(human.contains("VACUUM did not complete"))
    }

    @Test func destroyReportsVacuumedTrueWhenBothStepsSucceed() async throws {
        let event = RawEvent(id: 1, ts: 0, kind: .contextSnapshot)
        let outcome = try await PurgeCommand.destroy(
            selected: [event], sleep: noSleep,
            delete: { $0.count },
            vacuum: {})
        #expect(outcome.result.deleted == 1)
        #expect(outcome.result.vacuumed)
        #expect(outcome.vacuumWarning == nil)
        #expect(
            PurgeCommand.humanLines(outcome.result)
                == "deleted 1 of 1 matching row(s); database vacuumed")
    }

    @Test func destroyThrowsALockedCLIErrorWhenDeleteNeverRecovers() async throws {
        let events = (1...3).map { RawEvent(id: Int64($0), ts: 0, kind: .contextSnapshot) }
        do {
            _ = try await PurgeCommand.destroy(
                selected: events, deleteAttempts: 2, sleep: noSleep,
                delete: { _ in throw self.locked() },
                vacuum: {})
            Issue.record("expected destroy to throw")
        } catch let error as CLIError {
            #expect(error.code == "database_locked")
            #expect(error.exitCode == 1)
            #expect(error.message.lowercased().contains("locked"))
            #expect(error.message.contains("none"))
        }
    }

    /// The store's own paging cursor logic, exercised with a small injected page size instead of
    /// seeding tens of thousands of rows.
    @Test func fetchAllCandidatesPagesPastAnInjectedLimit() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-purge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.sqlite")
        let store = try EventStore(url: url)
        for i in 1...5 {
            try await store.append(RawEvent(ts: Double(i), kind: .appActivated, bundleID: "com.a"))
        }
        let all = try await PurgeCommand.fetchAllCandidates(
            store: store, since: 0, until: nil, pageLimit: 2)
        await store.close()
        #expect(all.map(\.id) == [1, 2, 3, 4, 5])
    }
}

@Suite struct PurgeCommandCLITests {
    /// Seeds a store in a temp data dir and returns the env the CLI needs to find it.
    private func seeded() async throws -> (dir: URL, env: [String: String]) {
        let dir = try CLIRunner.tempDataDir()
        let store = try EventStore(url: dir.appendingPathComponent("events.sqlite"))
        try await store.append(
            RawEvent(ts: 100, kind: .appActivated, bundleID: "com.apple.Safari"))
        try await store.append(
            RawEvent(ts: 200, kind: .appActivated, bundleID: "com.google.Chrome"))
        await store.close()
        return (dir, ["OPENRHYME_DATA_DIR": dir.path])
    }

    @Test func dryRunReportsWithoutChangingAnythingThenConfirmationGatesTheRealDelete()
        async throws
    {
        let (dir, env) = try await seeded()

        let dry = try CLIRunner.run(
            ["purge", "--since", "0", "--app", "com.apple.Safari", "--dry-run", "--json"],
            env: env)
        #expect(dry.status == 0, "\(dry.stderr)")
        var data = try CLIRunner.json(dry.stdout)["data"] as? [String: Any]
        #expect(data?["matched"] as? Int == 1)
        #expect(data?["deleted"] as? Int == 0)
        #expect(data?["dryRun"] as? Bool == true)

        let store = try EventStore(
            url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        #expect(try await store.count() == 2)
        await store.close()

        let refused = try CLIRunner.run(
            ["purge", "--since", "0", "--app", "com.apple.Safari", "--json"], env: env)
        #expect(refused.status == 2)
        let error = try CLIRunner.json(refused.stdout)["error"] as? [String: Any]
        #expect(error?["code"] as? String == "confirmation_required")
        let stillThere = try EventStore(
            url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        #expect(try await stillThere.count() == 2)
        await stillThere.close()

        let confirmed = try CLIRunner.run(
            ["purge", "--since", "0", "--app", "com.apple.Safari", "--yes", "--json"], env: env)
        #expect(confirmed.status == 0, "\(confirmed.stderr)")
        data = try CLIRunner.json(confirmed.stdout)["data"] as? [String: Any]
        #expect(data?["matched"] as? Int == 1)
        #expect(data?["deleted"] as? Int == 1)
        #expect(data?["vacuumed"] as? Bool == true)

        let after = try EventStore(
            url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        let remaining = try await after.query(EventQuery(since: 0))
        await after.close()
        #expect(remaining.map(\.bundleID) == ["com.google.Chrome"])
    }

    @Test func noFiltersAndNoAllIsAUsageErrorNotAnImplicitPurgeEverything() async throws {
        let (_, env) = try await seeded()
        let result = try CLIRunner.run(["purge", "--yes", "--json"], env: env)
        #expect(result.status == 2)
        let error = try CLIRunner.json(result.stdout)["error"] as? [String: Any]
        #expect(error?["code"] as? String == "usage")
    }

    @Test func allDeletesEverythingInRange() async throws {
        let (dir, env) = try await seeded()
        let result = try CLIRunner.run(
            ["purge", "--since", "0", "--all", "--yes", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["matched"] as? Int == 2)
        #expect(data?["deleted"] as? Int == 2)
        let store = try EventStore(
            url: dir.appendingPathComponent("events.sqlite"), readOnly: true)
        #expect(try await store.count() == 0)
        await store.close()
    }

    /// Requirement: `--dry-run` must be genuinely read-only. Checkpointed bytes of the main
    /// database file are compared before and after — not merely that the reported count was
    /// zero — so any write at all, including one hidden behind an uncheckpointed WAL frame,
    /// would be caught.
    @Test func dryRunLeavesTheDatabaseByteIdentical() async throws {
        let (dir, env) = try await seeded()
        let dbURL = dir.appendingPathComponent("events.sqlite")

        func checkpointedBytes() throws -> Data {
            let db = try Database(url: dbURL, mode: .readWrite)
            try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
            db.close()
            return try Data(contentsOf: dbURL)
        }

        let before = try checkpointedBytes()
        let result = try CLIRunner.run(
            ["purge", "--since", "0", "--all", "--dry-run", "--json"], env: env)
        #expect(result.status == 0, "\(result.stderr)")
        let data = try CLIRunner.json(result.stdout)["data"] as? [String: Any]
        #expect(data?["matched"] as? Int == 2)
        #expect(data?["deleted"] as? Int == 0)

        let after = try checkpointedBytes()
        #expect(before == after)
    }

    /// Requirement: a purge that hits a locked database retries briefly, then fails loudly
    /// rather than partially deleting. A second connection holds a write transaction open for
    /// the whole attempt, so every retry inside `purge` keeps hitting SQLITE_BUSY and it must
    /// give up rather than hang or silently drop rows.
    @Test func lockedDatabaseFailsLoudlyWithoutDeletingAnything() async throws {
        let (dir, env) = try await seeded()
        let dbURL = dir.appendingPathComponent("events.sqlite")

        let locker = try Database(url: dbURL, mode: .readWrite)
        try locker.exec("BEGIN IMMEDIATE")
        defer {
            try? locker.exec("ROLLBACK")
            locker.close()
        }

        let result = try CLIRunner.run(
            ["purge", "--since", "0", "--all", "--yes", "--json"], env: env)
        #expect(result.status != 0)
        let envelope = try CLIRunner.json(result.stdout)
        #expect(envelope["ok"] as? Bool == false)
        let error = envelope["error"] as? [String: Any]
        #expect((error?["message"] as? String)?.lowercased().contains("locked") == true)

        // The locker's write transaction is still open: a fresh read-only connection can still
        // see the pre-purge snapshot, proving nothing was actually removed.
        let stillThere = try EventStore(url: dbURL, readOnly: true)
        #expect(try await stillThere.count() == 2)
        await stillThere.close()
    }

    // MARK: - Live daemon (requirement: warn, never refuse)

    private func launchDaemon(dataDir: URL) throws -> Process {
        let process = Process()
        process.executableURL = CLIRunner.binaryURL
        process.arguments = ["daemon", "--no-prompt"]
        var env = ProcessInfo.processInfo.environment
        env["OPENRHYME_DATA_DIR"] = dataDir.path
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func waitForPIDFile(
        _ dir: URL, timeout: TimeInterval = 10, poll: Duration = .milliseconds(100)
    ) async -> Bool {
        let pidfile = PIDFile(url: dir.appendingPathComponent("daemon.pid"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pidfile.livePID != nil { return true }
            try? await Task.sleep(for: poll)
        }
        return false
    }

    @discardableResult
    private func stopDaemon(_ process: Process, timeout: TimeInterval = 10) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        return true
    }

    @Test func warnsAboutALiveDaemonButStillPurges() async throws {
        let dir = try CLIRunner.tempDataDir()
        let daemon = try launchDaemon(dataDir: dir)
        defer { stopDaemon(daemon) }
        #expect(await waitForPIDFile(dir), "daemon did not write daemon.pid")

        let result = try CLIRunner.run(
            ["purge", "--since", "0", "--all", "--yes", "--json"],
            env: ["OPENRHYME_DATA_DIR": dir.path])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stderr.lowercased().contains("daemon"))

        // Never blocked or killed by purge: still alive right after it ran.
        let pidfile = PIDFile(url: dir.appendingPathComponent("daemon.pid"))
        #expect(pidfile.livePID != nil, "purge must never stop or block a running daemon")
    }
}
