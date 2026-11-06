import Foundation

/// The stream's sentences as vectors, for the SIMILAR move: one vector per sentence, keyed by
/// its number, kept append-only in `vectors.bin` in the notes folder (ids never change, so a
/// vector written once stays right). Vectors are stored unit length, so similarity is a dot
/// product; a query is ranked against every vector (brute force: twenty thousand sentences
/// of 768 floats is a few milliseconds). `vectors.json` names the embedding model and the
/// dimension; a store made by another model is not reused.
public struct VectorStore: Sendable {
    public static let file = "vectors.bin", meta = "vectors.json"
    static let magic: [UInt8] = Array("HNV1".utf8)

    public struct Meta: Codable, Equatable, Sendable {
        public var model: String
        public var dim: Int
        public init(model: String, dim: Int) { self.model = model; self.dim = dim }
    }

    public let model: String
    public let dim: Int
    /// Sentence number → vector index in `vectors`.
    private(set) var index: [Int: Int] = [:]
    private(set) var vectors: [Float] = []

    public init(model: String, dim: Int) { self.model = model; self.dim = dim }

    public var count: Int { index.count }
    public func has(_ n: Int) -> Bool { index[n] != nil }

    /// The numbers of `sentences` with no vector yet.
    public func missing(in sentences: [Sentence]) -> [Int] {
        sentences.compactMap { Sentences.number($0.id) }.filter { index[$0] == nil }
    }

    /// Loads the folder's store, or nil when there is none or it was made by another model.
    public static func load(from folder: NotesFolder, model: String) -> VectorStore? {
        guard let meta = folder.readJSON(meta, as: Meta.self), meta.model == model, meta.dim > 0,
              let u = folder.url(file), let data = try? Data(contentsOf: u) else { return nil }
        var store = VectorStore(model: meta.model, dim: meta.dim)
        let record = 4 + meta.dim * 4
        guard data.count >= 4, Array(data.prefix(4)) == magic else { return nil }
        var offset = 4
        store.vectors.reserveCapacity((data.count - 4) / record * meta.dim)
        while offset + record <= data.count {
            let n = Int(data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let floats = data[offset + 4..<offset + record].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            store.put(n, floats)
            offset += record
        }
        return store
    }

    private mutating func put(_ n: Int, _ v: [Float]) {
        if let i = index[n] { vectors.replaceSubrange(i * dim..<(i + 1) * dim, with: v) } else { index[n] = vectors.count / dim; vectors += v }
    }

    /// Adds vectors (normalised here) to memory and to the file. A file made by another model
    /// (or of another dimension) is replaced, with the meta file, so a store never mixes models.
    public mutating func append(_ records: [(n: Int, vector: [Float])], to folder: NotesFolder) throws {
        guard let u = folder.url(Self.file) else { throw ReaderError("No place for \(Self.file)") }
        var data = Data()
        let mine = Meta(model: model, dim: dim)
        let fresh = !FileManager.default.fileExists(atPath: u.path) || folder.readJSON(Self.meta, as: Meta.self) != mine
        if fresh {
            data.append(contentsOf: Self.magic)
            try folder.writeJSON(Self.meta, mine)
        }
        for r in records {
            guard r.vector.count == dim else { throw ReaderError("A vector of \(r.vector.count) floats for a store of \(dim)") }
            let v = Self.normalised(r.vector)
            put(r.n, v)
            var n = UInt32(r.n)
            data.append(Data(bytes: &n, count: 4))
            v.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        if !fresh, let handle = try? FileHandle(forWritingTo: u) {
            defer { try? handle.close() }
            // A record half written (a crash, a full disk) is cut off first, or every record
            // after it would be read shifted.
            let record = UInt64(4 + dim * 4)
            let size = try handle.seekToEnd()
            if size >= 4 {
                let clean = 4 + (size - 4) / record * record
                if clean != size { try handle.truncate(atOffset: clean); try handle.seekToEnd() }
            }
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: u, options: .atomic)
        }
    }

    /// The `top` nearest sentences to `query`, best first, as (number, cosine similarity).
    public func search(_ query: [Float], top: Int) -> [(n: Int, score: Float)] {
        guard query.count == dim, !vectors.isEmpty else { return [] }
        let q = Self.normalised(query)
        var scored: [(n: Int, score: Float)] = []
        scored.reserveCapacity(index.count)
        vectors.withUnsafeBufferPointer { buf in
            for (n, i) in index {
                var s: Float = 0
                let base = i * dim
                for k in 0..<dim { s += buf[base + k] * q[k] }
                scored.append((n, s))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.n < $1.n }
        return Array(scored.prefix(top))
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
