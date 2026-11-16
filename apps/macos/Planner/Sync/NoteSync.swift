import Foundation

@MainActor
struct NoteSync {
    private struct Index: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            let id: UUID
            let revision: String
        }
        let notes: [Entry]
    }

    private struct Remote: Decodable, Sendable {
        let revision: String
        let data: Data
    }

    private struct Receipt: Decodable, Sendable {
        let revision: String
    }

    private struct Write: Encodable {
        let baseRevision: String?
        let data: Data

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(baseRevision, forKey: .baseRevision)
            try values.encode(data, forKey: .data)
        }

        private enum CodingKeys: String, CodingKey { case baseRevision, data }
    }

    let store: NoteStore
    let api: SyncHTTP

    /// A concurrent write is picked up on the next pass before any retry.
    func synchronize(maxBytes: Int, checkActive: () throws -> Void) async throws -> Bool {
        guard store.flush() else { throw BackupError.unsavedChanges }
        let index: Index = try await api.authorized("/v1/notes")
        try checkActive()
        var revisions: [UUID: String] = [:]
        for entry in index.notes {
            guard revisions.updateValue(entry.revision, forKey: entry.id) == nil else {
                throw SyncProblem.invalidResponse
            }
        }
        let known = Dictionary(uniqueKeysWithValues: store.notes.compactMap { note in
            note.syncVersion.map { (note.id, $0.revision) }
        })
        for entry in index.notes where known[entry.id] != entry.revision {
            let remote: Remote = try await api.authorized("/v1/notes/" + entry.id.syncID)
            try checkActive()
            let note = try JSONDecoder().decode(PlannerNote.self, from: remote.data)
            guard note.id == entry.id, remote.revision == NoteStore.digest(remote.data) else {
                throw SyncProblem.invalidResponse
            }
            try store.applyRemote(note, revision: remote.revision)
            revisions[entry.id] = remote.revision
        }

        guard store.flush() else { throw BackupError.unsavedChanges }
        var retry = false
        var blocked: Error?
        for note in store.notes {
            try checkActive()
            if note.richText != nil && store.sharedFormatLimit == nil { continue }
            let data = try NoteStore.wireData(note)
            let digest = NoteStore.digest(data)
            let revision = revisions[note.id]
            if revision == digest || (revision != nil && revision == note.syncVersion?.revision && digest == note.syncVersion?.localDigest) {
                if note.syncVersion?.revision != revision {
                    try store.acknowledge(note.id, revision: digest, digest: digest)
                }
                continue
            }
            guard data.count <= maxBytes else {
                blocked = SyncProblem.oversizedMutation
                continue
            }
            do {
                let body = try SyncHTTP.payload(Write(baseRevision: revision, data: data))
                let receipt: Receipt = try await api.authorized("/v1/notes/" + note.id.syncID, method: "PUT", body: body)
                try checkActive()
                guard receipt.revision == digest else { throw SyncProblem.invalidResponse }
                try store.acknowledge(note.id, revision: receipt.revision, digest: digest)
            } catch let failure as SyncHTTPFailure where failure.problem.code == "note_conflict" {
                retry = true
            } catch let failure as SyncHTTPFailure where failure.problem.code == "note_quota" || failure.status == 413 {
                blocked = failure
            }
        }
        if let blocked { throw blocked }
        return retry
    }
}
