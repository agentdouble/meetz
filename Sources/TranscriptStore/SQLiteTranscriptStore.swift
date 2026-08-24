import CSQLite
import Foundation
import MeetingDomain

public actor SQLiteTranscriptStore {
    nonisolated(unsafe) private var database: OpaquePointer?

    public init(databaseURL: URL? = nil) throws {
        let resolvedURL = try databaseURL ?? Self.defaultDatabaseURL()
        let parentDirectory = resolvedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            resolvedURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Impossible d'ouvrir SQLite"
            sqlite3_close(connection)
            throw TranscriptStoreError.sqlite(message)
        }

        database = connection
        try Self.bootstrap(connection)
    }

    deinit {
        sqlite3_close(database)
    }

    public func createMeeting(title: String? = nil) throws -> MeetingRecord {
        let startedAt = Date()
        let record = MeetingRecord(
            title: title ?? Self.defaultTitle(for: startedAt),
            titleOrigin: title == nil ? .automatic : .user,
            startedAt: startedAt
        )

        try execute(
            """
            INSERT INTO meetings (id, title, title_origin, context, started_at, ended_at, state)
            VALUES (?, ?, ?, ?, ?, NULL, ?);
            """,
            bindings: [
                .text(record.id.uuidString),
                .text(record.title),
                .text(record.titleOrigin.rawValue),
                .text(record.context),
                .double(record.startedAt.timeIntervalSince1970),
                .text(record.state.rawValue),
            ]
        )
        return record
    }

    public func finishMeeting(
        id: UUID,
        state: MeetingState = .completed
    ) throws {
        try execute(
            "UPDATE meetings SET ended_at = ?, state = ? WHERE id = ?;",
            bindings: [
                .double(Date().timeIntervalSince1970),
                .text(state.rawValue),
                .text(id.uuidString),
            ]
        )
    }

    public func recoverInterruptedMeetings(at recoveryDate: Date = Date()) throws {
        try execute(
            """
            UPDATE meetings
            SET ended_at = COALESCE(ended_at, ?), state = ?
            WHERE state = ?;
            """,
            bindings: [
                .double(recoveryDate.timeIntervalSince1970),
                .text(MeetingState.interrupted.rawValue),
                .text(MeetingState.recording.rawValue),
            ]
        )
    }

    public func meetingExists(id: UUID) throws -> Bool {
        try !query(
            "SELECT 1 FROM meetings WHERE id = ? LIMIT 1;",
            bindings: [.text(id.uuidString)]
        ) { _ in true }.isEmpty
    }

    public func isAudioBlockProcessed(id: String) throws -> Bool {
        try !query(
            "SELECT 1 FROM processed_audio_blocks WHERE block_id = ? LIMIT 1;",
            bindings: [.text(id)]
        ) { _ in true }.isEmpty
    }

    public func updateMeetingMetadata(
        id: UUID,
        title: String,
        context: String,
        titleOrigin: MeetingTitleOrigin? = nil
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw TranscriptStoreError.invalidRow
        }
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if let titleOrigin {
            try execute(
                "UPDATE meetings SET title = ?, title_origin = ?, context = ? WHERE id = ?;",
                bindings: [
                    .text(normalizedTitle),
                    .text(titleOrigin.rawValue),
                    .text(normalizedContext),
                    .text(id.uuidString),
                ]
            )
        } else {
            try execute(
                "UPDATE meetings SET title = ?, context = ? WHERE id = ?;",
                bindings: [
                    .text(normalizedTitle),
                    .text(normalizedContext),
                    .text(id.uuidString),
                ]
            )
        }
    }

    public func applyAITitleIfAutomatic(id: UUID, title: String) throws -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw TranscriptStoreError.invalidRow }
        try execute(
            """
            UPDATE meetings
            SET title = ?, title_origin = ?
            WHERE id = ? AND title_origin = ?;
            """,
            bindings: [
                .text(normalizedTitle),
                .text(MeetingTitleOrigin.artificialIntelligence.rawValue),
                .text(id.uuidString),
                .text(MeetingTitleOrigin.automatic.rawValue),
            ]
        )
        return sqlite3_changes(database) > 0
    }

    public func saveAIResult(_ result: MeetingAIResult) throws {
        try execute(
            """
            INSERT INTO meeting_ai_results (
                id, meeting_id, kind, schema_version, payload_json,
                source_segment_count, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(result.id.uuidString),
                .text(result.meetingID.uuidString),
                .text(result.kind.rawValue),
                .integer(result.schemaVersion),
                .text(result.payloadJSON),
                .integer(result.sourceSegmentCount),
                .double(result.createdAt.timeIntervalSince1970),
            ]
        )
    }

    public func aiResults(meetingID: UUID) throws -> [MeetingAIResult] {
        try query(
            """
            SELECT id, meeting_id, kind, schema_version, payload_json,
                   source_segment_count, created_at
            FROM meeting_ai_results
            WHERE meeting_id = ?
            ORDER BY created_at DESC;
            """,
            bindings: [.text(meetingID.uuidString)]
        ) { statement in
            guard let id = UUID(uuidString: Self.columnText(statement, index: 0)),
                  let resolvedMeetingID = UUID(uuidString: Self.columnText(statement, index: 1)),
                  let kind = MeetingAIJobKind(rawValue: Self.columnText(statement, index: 2))
            else { throw TranscriptStoreError.invalidRow }
            return MeetingAIResult(
                id: id,
                meetingID: resolvedMeetingID,
                kind: kind,
                schemaVersion: Int(sqlite3_column_int64(statement, 3)),
                payloadJSON: Self.columnText(statement, index: 4),
                sourceSegmentCount: Int(sqlite3_column_int64(statement, 5)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            )
        }
    }

    public func enqueueAIJobs(meetingID: UUID, kinds: [MeetingAIJobKind]) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for kind in kinds {
                try execute(
                    """
                    INSERT OR IGNORE INTO pending_meeting_ai_jobs (meeting_id, kind, created_at)
                    VALUES (?, ?, ?);
                    """,
                    bindings: [
                        .text(meetingID.uuidString),
                        .text(kind.rawValue),
                        .double(Date().timeIntervalSince1970),
                    ]
                )
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func pendingAIJobs() throws -> [PendingMeetingAIJob] {
        try query(
            """
            SELECT meeting_id, kind, created_at
            FROM pending_meeting_ai_jobs
            ORDER BY created_at ASC,
                     CASE kind WHEN 'title' THEN 0 ELSE 1 END;
            """
        ) { statement in
            guard let meetingID = UUID(uuidString: Self.columnText(statement, index: 0)),
                  let kind = MeetingAIJobKind(rawValue: Self.columnText(statement, index: 1))
            else { throw TranscriptStoreError.invalidRow }
            return PendingMeetingAIJob(
                meetingID: meetingID,
                kind: kind,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
    }

    public func completeAIJob(meetingID: UUID, kind: MeetingAIJobKind) throws {
        try execute(
            "DELETE FROM pending_meeting_ai_jobs WHERE meeting_id = ? AND kind = ?;",
            bindings: [.text(meetingID.uuidString), .text(kind.rawValue)]
        )
    }

    public func deleteMeeting(id: UUID) throws {
        try execute(
            "DELETE FROM meetings WHERE id = ?;",
            bindings: [.text(id.uuidString)]
        )
    }

    public func saveVoiceProfile(_ profile: VoiceProfile) throws {
        let embeddingData = try JSONEncoder().encode(profile.embedding)
        guard let embeddingJSON = String(data: embeddingData, encoding: .utf8) else {
            throw TranscriptStoreError.invalidVoiceProfile
        }

        try execute(
            """
            INSERT INTO voice_profiles (
                id, display_name, embedding_json, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                embedding_json = excluded.embedding_json,
                sample_count = excluded.sample_count,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(profile.id),
                .text(profile.displayName),
                .text(embeddingJSON),
                .integer(profile.sampleCount),
                .double(profile.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    public func voiceProfile(id: String = "local-user") throws -> VoiceProfile? {
        try query(
            """
            SELECT id, display_name, embedding_json, sample_count, updated_at
            FROM voice_profiles
            WHERE id = ?
            LIMIT 1;
            """,
            bindings: [.text(id)]
        ) { statement in
            guard let embeddingData = Self.columnText(statement, index: 2).data(using: .utf8),
                  let embedding = try? JSONDecoder().decode([Float].self, from: embeddingData),
                  !embedding.isEmpty
            else {
                throw TranscriptStoreError.invalidVoiceProfile
            }

            return VoiceProfile(
                id: Self.columnText(statement, index: 0),
                displayName: Self.columnText(statement, index: 1),
                embedding: embedding,
                sampleCount: Int(sqlite3_column_int64(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        }.first
    }

    public func voiceProfiles() throws -> [VoiceProfile] {
        try query(
            """
            SELECT id, display_name, embedding_json, sample_count, updated_at
            FROM voice_profiles
            ORDER BY CASE WHEN id = 'local-user' THEN 0 ELSE 1 END,
                     updated_at DESC;
            """
        ) { statement in
            guard let embeddingData = Self.columnText(statement, index: 2).data(using: .utf8),
                  let embedding = try? JSONDecoder().decode([Float].self, from: embeddingData),
                  !embedding.isEmpty
            else {
                throw TranscriptStoreError.invalidVoiceProfile
            }

            return VoiceProfile(
                id: Self.columnText(statement, index: 0),
                displayName: Self.columnText(statement, index: 1),
                embedding: embedding,
                sampleCount: Int(sqlite3_column_int64(statement, 3)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            )
        }
    }

    public func renameVoiceProfile(id: String, displayName: String) throws {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw TranscriptStoreError.invalidVoiceProfile
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(
                "UPDATE voice_profiles SET display_name = ?, updated_at = ? WHERE id = ?;",
                bindings: [
                    .text(normalizedName),
                    .double(Date().timeIntervalSince1970),
                    .text(id),
                ]
            )
            try execute(
                "UPDATE speakers SET display_name = ? WHERE speaker_id = ?;",
                bindings: [.text(normalizedName), .text(id)]
            )
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func renameSpeaker(
        meetingID: UUID,
        speakerID: String,
        displayName: String
    ) throws {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw TranscriptStoreError.invalidVoiceProfile
        }
        try execute(
            "UPDATE speakers SET display_name = ? WHERE meeting_id = ? AND speaker_id = ?;",
            bindings: [
                .text(normalizedName),
                .text(meetingID.uuidString),
                .text(speakerID),
            ]
        )
    }

    public func deleteVoiceProfile(id: String) throws {
        try execute(
            "DELETE FROM voice_profiles WHERE id = ?;",
            bindings: [.text(id)]
        )
    }

    public func insertSegment(_ segment: TranscriptSegment) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(
                """
                INSERT INTO speakers (meeting_id, speaker_id, display_name)
                VALUES (?, ?, ?)
                ON CONFLICT(meeting_id, speaker_id)
                DO UPDATE SET display_name = excluded.display_name;
                """,
                bindings: [
                    .text(segment.meetingID.uuidString),
                    .text(segment.speakerID),
                    .text(segment.speakerName),
                ]
            )
            try execute(
                """
                INSERT INTO segments (
                    id, meeting_id, speaker_id, start_time, end_time,
                    text, confidence, input_kind, audio_block_id, source_kind, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(segment.id.uuidString),
                    .text(segment.meetingID.uuidString),
                    .text(segment.speakerID),
                    .double(segment.startTime),
                    .double(segment.endTime),
                    .text(segment.text),
                    .double(Double(segment.confidence)),
                    segment.inputKind.map { .text($0.rawValue) } ?? .text("unknown"),
                    segment.audioBlockID.map(Binding.text) ?? .text(""),
                    .text(segment.source.rawValue),
                    .double(segment.createdAt.timeIntervalSince1970),
                ]
            )
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func upsertRealtimeSegment(_ segment: TranscriptSegment) throws {
        guard segment.source == .realtime else {
            throw TranscriptStoreError.invalidRow
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(
                """
                INSERT INTO speakers (meeting_id, speaker_id, display_name)
                VALUES (?, ?, ?)
                ON CONFLICT(meeting_id, speaker_id)
                DO UPDATE SET display_name = excluded.display_name;
                """,
                bindings: [
                    .text(segment.meetingID.uuidString),
                    .text(segment.speakerID),
                    .text(segment.speakerName),
                ]
            )
            try execute(
                """
                INSERT INTO segments (
                    id, meeting_id, speaker_id, start_time, end_time,
                    text, confidence, input_kind, audio_block_id, source_kind, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    end_time = excluded.end_time,
                    text = excluded.text,
                    input_kind = excluded.input_kind,
                    audio_block_id = excluded.audio_block_id,
                    source_kind = excluded.source_kind;
                """,
                bindings: [
                    .text(segment.id.uuidString),
                    .text(segment.meetingID.uuidString),
                    .text(segment.speakerID),
                    .double(segment.startTime),
                    .double(segment.endTime),
                    .text(segment.text),
                    .double(Double(segment.confidence)),
                    segment.inputKind.map { .text($0.rawValue) } ?? .text("unknown"),
                    segment.audioBlockID.map(Binding.text) ?? .text(""),
                    .text(segment.source.rawValue),
                    .double(segment.createdAt.timeIntervalSince1970),
                ]
            )
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func deleteRealtimeSegments(meetingID: UUID) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute(
                "DELETE FROM segments WHERE meeting_id = ? AND source_kind = ?;",
                bindings: [
                    .text(meetingID.uuidString),
                    .text(TranscriptSegmentSource.realtime.rawValue),
                ]
            )
            try execute(
                "DELETE FROM speakers WHERE meeting_id = ? AND speaker_id LIKE 'realtime-%';",
                bindings: [.text(meetingID.uuidString)]
            )
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    public func commitAudioBlock(
        id blockID: String,
        meetingID: UUID,
        inputKind: TranscriptInputKind,
        segments: [TranscriptSegment],
        voiceProfiles: [VoiceProfile]
    ) throws -> Bool {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let alreadyProcessed = try !query(
                "SELECT 1 FROM processed_audio_blocks WHERE block_id = ? LIMIT 1;",
                bindings: [.text(blockID)]
            ) { _ in true }.isEmpty
            if alreadyProcessed {
                try execute("COMMIT;")
                return false
            }

            var latestProfiles: [String: VoiceProfile] = [:]
            for profile in voiceProfiles {
                latestProfiles[profile.id] = profile
            }
            for profile in latestProfiles.values {
                try saveVoiceProfileWithoutTransaction(profile)
            }
            for segment in segments {
                try insertSegmentWithoutTransaction(segment)
            }
            try execute(
                """
                INSERT INTO processed_audio_blocks (
                    block_id, meeting_id, input_kind, processed_at
                ) VALUES (?, ?, ?, ?);
                """,
                bindings: [
                    .text(blockID),
                    .text(meetingID.uuidString),
                    .text(inputKind.rawValue),
                    .double(Date().timeIntervalSince1970),
                ]
            )
            try execute("COMMIT;")
            return true
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func meetings() throws -> [MeetingRecord] {
        try query(
            """
            SELECT id, title, title_origin, context, started_at, ended_at, state
            FROM meetings
            ORDER BY started_at DESC;
            """
        ) { statement in
            guard
                let id = UUID(uuidString: Self.columnText(statement, index: 0)),
                let titleOrigin = MeetingTitleOrigin(rawValue: Self.columnText(statement, index: 2)),
                let state = MeetingState(rawValue: Self.columnText(statement, index: 6))
            else {
                throw TranscriptStoreError.invalidRow
            }

            let endedAt: Date?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                endedAt = nil
            } else {
                endedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            }

            return MeetingRecord(
                id: id,
                title: Self.columnText(statement, index: 1),
                titleOrigin: titleOrigin,
                context: Self.columnText(statement, index: 3),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                endedAt: endedAt,
                state: state
            )
        }
    }

    public func segments(meetingID: UUID) throws -> [TranscriptSegment] {
        try query(
            """
            SELECT
                s.id, s.meeting_id, s.speaker_id, sp.display_name,
                s.start_time, s.end_time, s.text, s.confidence,
                s.input_kind, s.audio_block_id, s.source_kind, s.created_at
            FROM segments s
            JOIN speakers sp
              ON sp.meeting_id = s.meeting_id AND sp.speaker_id = s.speaker_id
            WHERE s.meeting_id = ?
            ORDER BY s.start_time ASC, s.created_at ASC;
            """,
            bindings: [.text(meetingID.uuidString)]
        ) { statement in
            guard
                let id = UUID(uuidString: Self.columnText(statement, index: 0)),
                let resolvedMeetingID = UUID(
                    uuidString: Self.columnText(statement, index: 1)
                )
            else {
                throw TranscriptStoreError.invalidRow
            }

            return TranscriptSegment(
                id: id,
                meetingID: resolvedMeetingID,
                speakerID: Self.columnText(statement, index: 2),
                speakerName: Self.columnText(statement, index: 3),
                startTime: sqlite3_column_double(statement, 4),
                endTime: sqlite3_column_double(statement, 5),
                text: Self.columnText(statement, index: 6),
                confidence: Float(sqlite3_column_double(statement, 7)),
                inputKind: TranscriptInputKind(
                    rawValue: Self.columnText(statement, index: 8)
                ),
                audioBlockID: {
                    let value = Self.columnText(statement, index: 9)
                    return value.isEmpty ? nil : value
                }(),
                source: TranscriptSegmentSource(
                    rawValue: Self.columnText(statement, index: 10)
                ) ?? .canonical,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            )
        }
    }

    private func migrate() throws {
        try executeScript(Self.schemaSQL)
    }

    private static let schemaSQL = """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                title_origin TEXT NOT NULL DEFAULT 'automatic',
                context TEXT NOT NULL DEFAULT '',
                started_at REAL NOT NULL,
                ended_at REAL,
                state TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS speakers (
                meeting_id TEXT NOT NULL,
                speaker_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                PRIMARY KEY (meeting_id, speaker_id),
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS segments (
                id TEXT PRIMARY KEY NOT NULL,
                meeting_id TEXT NOT NULL,
                speaker_id TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                text TEXT NOT NULL,
                confidence REAL NOT NULL,
                input_kind TEXT NOT NULL DEFAULT 'unknown',
                audio_block_id TEXT NOT NULL DEFAULT '',
                source_kind TEXT NOT NULL DEFAULT 'canonical',
                created_at REAL NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS segments_meeting_time
            ON segments(meeting_id, start_time, created_at);

            CREATE TABLE IF NOT EXISTS processed_audio_blocks (
                block_id TEXT PRIMARY KEY NOT NULL,
                meeting_id TEXT NOT NULL,
                input_kind TEXT NOT NULL,
                processed_at REAL NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS voice_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                embedding_json TEXT NOT NULL,
                sample_count INTEGER NOT NULL DEFAULT 1,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS meeting_ai_results (
                id TEXT PRIMARY KEY NOT NULL,
                meeting_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                payload_json TEXT NOT NULL,
                source_segment_count INTEGER NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS meeting_ai_results_meeting_kind_date
            ON meeting_ai_results(meeting_id, kind, created_at DESC);

            CREATE TABLE IF NOT EXISTS pending_meeting_ai_jobs (
                meeting_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (meeting_id, kind),
                FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );
            """

    private static func bootstrap(_ connection: OpaquePointer) throws {
        let script = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            \(schemaSQL)
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, script, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(connection))
            throw TranscriptStoreError.sqlite(message)
        }
        try ensureColumn(
            "context",
            in: "meetings",
            definition: "TEXT NOT NULL DEFAULT ''",
            connection: connection
        )
        try ensureColumn(
            "title_origin",
            in: "meetings",
            definition: "TEXT NOT NULL DEFAULT 'automatic'",
            connection: connection
        )
        guard sqlite3_exec(
            connection,
            """
            UPDATE meetings
            SET title_origin = 'user'
            WHERE title_origin = 'automatic' AND title NOT LIKE 'Reunion du %';
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw TranscriptStoreError.sqlite(String(cString: sqlite3_errmsg(connection)))
        }
        try ensureColumn(
            "sample_count",
            in: "voice_profiles",
            definition: "INTEGER NOT NULL DEFAULT 1",
            connection: connection
        )
        try ensureColumn(
            "input_kind",
            in: "segments",
            definition: "TEXT NOT NULL DEFAULT 'unknown'",
            connection: connection
        )
        try ensureColumn(
            "audio_block_id",
            in: "segments",
            definition: "TEXT NOT NULL DEFAULT ''",
            connection: connection
        )
        try ensureColumn(
            "source_kind",
            in: "segments",
            definition: "TEXT NOT NULL DEFAULT 'canonical'",
            connection: connection
        )
    }

    private func saveVoiceProfileWithoutTransaction(_ profile: VoiceProfile) throws {
        let embeddingData = try JSONEncoder().encode(profile.embedding)
        guard let embeddingJSON = String(data: embeddingData, encoding: .utf8) else {
            throw TranscriptStoreError.invalidVoiceProfile
        }
        try execute(
            """
            INSERT INTO voice_profiles (
                id, display_name, embedding_json, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                embedding_json = excluded.embedding_json,
                sample_count = excluded.sample_count,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(profile.id),
                .text(profile.displayName),
                .text(embeddingJSON),
                .integer(profile.sampleCount),
                .double(profile.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    private func insertSegmentWithoutTransaction(_ segment: TranscriptSegment) throws {
        try execute(
            """
            INSERT INTO speakers (meeting_id, speaker_id, display_name)
            VALUES (?, ?, ?)
            ON CONFLICT(meeting_id, speaker_id)
            DO UPDATE SET display_name = excluded.display_name;
            """,
            bindings: [
                .text(segment.meetingID.uuidString),
                .text(segment.speakerID),
                .text(segment.speakerName),
            ]
        )
        try execute(
            """
            INSERT INTO segments (
                id, meeting_id, speaker_id, start_time, end_time,
                text, confidence, input_kind, audio_block_id, source_kind, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(segment.id.uuidString),
                .text(segment.meetingID.uuidString),
                .text(segment.speakerID),
                .double(segment.startTime),
                .double(segment.endTime),
                .text(segment.text),
                .double(Double(segment.confidence)),
                segment.inputKind.map { .text($0.rawValue) } ?? .text("unknown"),
                segment.audioBlockID.map(Binding.text) ?? .text(""),
                .text(segment.source.rawValue),
                .double(segment.createdAt.timeIntervalSince1970),
            ]
        )
    }

    private static func ensureColumn(
        _ column: String,
        in table: String,
        definition: String,
        connection: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw TranscriptStoreError.sqlite(String(cString: sqlite3_errmsg(connection)))
        }
        let exists: Bool = {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if columnText(statement, index: 1) == column {
                    return true
                }
            }
            return false
        }()
        guard !exists else { return }

        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);"
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw TranscriptStoreError.sqlite(String(cString: sqlite3_errmsg(connection)))
        }
    }

    private func executeScript(_ sql: String) throws {
        guard let database else { throw TranscriptStoreError.closed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw TranscriptStoreError.sqlite(message)
        }
    }

    private enum Binding {
        case text(String)
        case double(Double)
        case integer(Int)
    }

    private func execute(
        _ sql: String,
        bindings: [Binding] = []
    ) throws {
        guard let database else { throw TranscriptStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TranscriptStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw TranscriptStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        guard let database else { throw TranscriptStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw TranscriptStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try rows.append(map(statement))
        }
        return rows
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(
                    statement,
                    index,
                    value,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            case let .double(value):
                result = sqlite3_bind_double(statement, index, value)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            }
            guard result == SQLITE_OK else {
                throw TranscriptStoreError.sqlite("Echec de liaison SQLite")
            }
        }
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static func defaultDatabaseURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("Meeting", isDirectory: true)
            .appendingPathComponent("meeting.sqlite", isDirectory: false)
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return "Reunion du \(formatter.string(from: date))"
    }
}

public enum TranscriptStoreError: LocalizedError, Sendable {
    case closed
    case invalidRow
    case invalidVoiceProfile
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .closed:
            "La base Meeting est fermee."
        case .invalidRow:
            "Une ligne de la base Meeting est invalide."
        case .invalidVoiceProfile:
            "Le profil vocal local est invalide."
        case let .sqlite(message):
            "Erreur SQLite : \(message)"
        }
    }
}
