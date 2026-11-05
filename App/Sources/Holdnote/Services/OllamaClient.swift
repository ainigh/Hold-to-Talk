import Foundation
import Harness

/// Ollama over HTTP: the model list, what a model knows about itself, and one streamed chat call
/// at a time. A native app sends no Origin header, so OLLAMA_ORIGINS is never needed here.
struct OllamaClient: ChatModel {
    struct ModelInfo: Sendable {
        var contextLength = 0
        var modelfileCtx = 0
        var family = ""
        var size = ""
    }

    let base: String

    init(base: String) { self.base = ReaderConfig.normalizeBase(base) }

    private func url(_ path: String) -> URL { URL(string: base + path)! }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 24 * 3600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 8) -> URLRequest {
        var r = URLRequest(url: url(path), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// The pulled models, sorted.
    func listModels() async throws -> [String] {
        let (data, response) = try await Self.session.data(for: URLRequest(url: url("/api/tags"), timeoutInterval: 6))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ReaderError("Ollama answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return models.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A cheap POST, so a call is proven to work the way real ones do (404 is "no such model", which still proves it).
    func probe(model: String) async -> (ok: Bool, status: Int, error: String?) {
        do {
            let (_, response) = try await Self.session.data(for: post("/api/show", ["model": model], timeout: 6))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status == 200 || status == 404, status, nil)
        } catch { return (false, 0, error.localizedDescription) }
    }

    /// What Ollama knows about a model: its trained context length and any num_ctx set in its Modelfile.
    func modelInfo(_ model: String) async throws -> ModelInfo {
        let (data, response) = try await Self.session.data(for: post("/api/show", ["model": model]))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var info = ModelInfo()
        for (k, v) in d["model_info"] as? [String: Any] ?? [:] where k.hasSuffix(".context_length") {
            if let n = (v as? NSNumber)?.intValue, n > 0 { info.contextLength = n }
        }
        for line in (d["parameters"] as? String ?? "").components(separatedBy: "\n") where line.hasPrefix("num_ctx") {
            if let n = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) { info.modelfileCtx = n }
        }
        let details = d["details"] as? [String: Any] ?? [:]
        info.family = details["family"] as? String ?? ""
        info.size = details["parameter_size"] as? String ?? ""
        return info
    }

    /// Vectors for `texts` from an embedding model (Ollama's /api/embed), one per text.
    func embed(model: String, texts: [String]) async throws -> [[Float]] {
        let (data, response) = try await Self.session.data(for: post("/api/embed", ["model": model, "input": texts, "keep_alive": "30m"], timeout: 120))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rows = d["embeddings"] as? [[NSNumber]] ?? []
        return rows.map { $0.map { $0.floatValue } }
    }

    private static func httpError(_ status: Int, _ body: Data) -> ReaderError {
        var msg = String(decoding: body.prefix(200), as: UTF8.self)
        if let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let e = j["error"] as? String { msg = e }
        // Bad-request, auth and missing-model errors will not fix themselves between calls.
        return ReaderError("Ollama answered \(status)\(msg.isEmpty ? "" : ": " + msg)", fatal: [400, 401, 403, 404].contains(status))
    }

    /// One streamed call: Ollama's NDJSON is read as it arrives and every piece handed to `onToken`.
    func chat(_ request: ChatRequest, config: ReaderConfig) async throws -> ChatReply {
        var body: [String: Any] = [
            "model": config.model,
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.user]],
            "stream": true,
            "options": ["num_ctx": config.numCtx, "temperature": 0, "seed": 7, "num_predict": config.outputTokens],
            "keep_alive": "30m",
        ]
        // Thinking is off unless asked for: on thinking models the hidden reasoning otherwise eats
        // num_predict and the window comes back empty. `think: true` is refused by models that cannot
        // think, so when the setting is on the field is left out and the model keeps its own default.
        if !config.think { body["think"] = false }
        var attempt = 0
        while true {
            do { return try await stream(body, onToken: request.onToken) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw ReaderError.cancelled }
                if let e = error as? ReaderError, e.cancelled || e.fatal { throw e }
                attempt += 1
                if attempt >= 3 { throw error as? ReaderError ?? ReaderError(error.localizedDescription) }
                try await Task.sleep(nanoseconds: UInt64(1.5 * Double(attempt) * 1e9))
            }
        }
    }

    private func stream(_ body: [String: Any], onToken: (@Sendable (String, String) -> Void)?) async throws -> ChatReply {
        let (bytes, response) = try await Self.session.bytes(for: post("/api/chat", body, timeout: 600))
        guard let http = response as? HTTPURLResponse else { throw ReaderError("No answer from Ollama") }
        if http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 4000 { break } }
            throw Self.httpError(http.statusCode, data)
        }
        var content = "", thinking = ""
        var last: [String: Any] = [:]
        for try await line in bytes.lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let e = d["error"] as? String { throw ReaderError(String(e.prefix(200))) }
            let m = d["message"] as? [String: Any]
            let c = m?["content"] as? String ?? "", t = m?["thinking"] as? String ?? ""
            if !c.isEmpty { content += c }
            if !t.isEmpty { thinking += t }
            if !c.isEmpty || !t.isEmpty { onToken?(content, thinking) }
            if d["done"] as? Bool == true { last = d }
        }
        let outTokens = (last["eval_count"] as? NSNumber)?.intValue ?? 0
        let ms = ((last["total_duration"] as? NSNumber)?.doubleValue ?? 0) / 1e6
        let evalMs = ((last["eval_duration"] as? NSNumber)?.doubleValue ?? 0) / 1e6
        return ChatReply(text: content, thinking: thinking,
                         promptTokens: (last["prompt_eval_count"] as? NSNumber)?.intValue ?? 0,
                         outTokens: outTokens, estTokens: 0, ms: Int(ms),
                         tokensPerSecond: evalMs > 0 ? (Double(outTokens) / (evalMs / 1000) * 10).rounded() / 10 : 0,
                         truncated: last["done_reason"] as? String == "length")
    }
}
