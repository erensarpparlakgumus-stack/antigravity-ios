import SwiftUI
import UniformTypeIdentifiers
import Combine
import Citadel
import NIOCore
import Crypto

// MARK: - DATA MODELS

struct ProjectFile: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var url: URL
    var isDirectory: Bool
    var children: [ProjectFile]?
}

struct BackupVersion: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let content: String
    let fileURL: URL
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let role: String       // "siz" | "agent" | "system"
    let text: String
    var actionLog: [String] = []
    var isError: Bool = false
}

struct SSHServerConfig: Identifiable, Codable {
    var id = UUID()
    var host: String
    var port: Int = 22
    var username: String
    var authType: AuthType
    var privateKey: String?
    var password: String?

    enum AuthType: String, Codable, CaseIterable {
        case password = "Parola"
        case privateKey = "Private Key (RSA/Ed25519)"
    }
}

// MARK: - AGENT ACTION MODELS

struct AgentAction: Codable, Identifiable {
    var id: String { (path) + type + (content?.prefix(8) ?? "") }
    let type: String      // create_file | edit_file | delete_file | create_folder | delete_folder
    let path: String
    var content: String?
}

struct AgentResponse: Codable {
    let explanation: String
    let actions: [AgentAction]?
}

// MARK: - WORKSPACE MANAGER

@MainActor
class WorkspaceManager: ObservableObject {
    @Published var rootFolderURL: URL?
    @Published var fileTree: [ProjectFile] = []
    @Published var activeFileURL: URL?
    @Published var activeFileContent: String = ""
    @Published var fileBackups: [URL: [BackupVersion]] = [:]
    @Published var lastCreatedFileURL: URL?    // agent'ın tetiklenmesi için izlenir

    private static let defaultWorkspaceName = "AntigravityWorkspace"
    private var securityScopedURL: URL?

    init() {
        ensureDefaultWorkspaceIsActive()
    }

    @discardableResult
    private func ensureDefaultWorkspaceIsActive() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(Self.defaultWorkspaceName, isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if rootFolderURL == nil {
            rootFolderURL = url
            fileTree = buildFileTree(for: url)
        }
        return url
    }

    func createAndOpenNewEmptyProject(named name: String = "YeniProje") {
        releaseSecurityScope()
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var candidate = name
        var counter = 1
        var candidateURL = docs.appendingPathComponent(candidate, isDirectory: true)
        while fm.fileExists(atPath: candidateURL.path) {
            counter += 1
            candidate = "\(name)\(counter)"
            candidateURL = docs.appendingPathComponent(candidate, isDirectory: true)
        }
        try? fm.createDirectory(at: candidateURL, withIntermediateDirectories: true)
        setRoot(candidateURL)
    }

    func openRoot(url: URL) {
        releaseSecurityScope()
        guard url.startAccessingSecurityScopedResource() else { return }
        securityScopedURL = url
        if url.hasDirectoryPath { setRoot(url) } else { loadFile(url: url) }
    }

    private func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    deinit { securityScopedURL?.stopAccessingSecurityScopedResource() }

    func setRoot(_ url: URL) {
        rootFolderURL = url
        fileTree = buildFileTree(for: url)
        activeFileURL = nil
        activeFileContent = ""
    }

    func refreshTree() {
        guard let root = rootFolderURL else { return }
        fileTree = buildFileTree(for: root)
    }

    func loadFile(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        activeFileURL = url
        activeFileContent = content
    }

    func saveActiveFile() {
        guard let url = activeFileURL else { return }
        let backup = BackupVersion(timestamp: Date(), content: activeFileContent, fileURL: url)
        fileBackups[url, default: []].insert(backup, at: 0)
        try? activeFileContent.write(to: url, atomically: true, encoding: .utf8)
    }

    func restoreBackup(_ backup: BackupVersion) {
        activeFileContent = backup.content
        saveActiveFile()
    }

    private func buildFileTree(for url: URL) -> [ProjectFile] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return items.compactMap { itemURL -> ProjectFile? in
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return ProjectFile(
                name: itemURL.lastPathComponent,
                url: itemURL,
                isDirectory: isDir,
                children: isDir ? buildFileTree(for: itemURL) : nil
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    func workspaceContext() -> String {
        guard let root = rootFolderURL else { return "(Çalışma alanı yok)" }
        let fm = FileManager.default
        var ctx = ""
        if let e = fm.enumerator(at: root,
                                  includingPropertiesForKeys: [.isDirectoryKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in e where !fileURL.hasDirectoryPath {
                let ext = fileURL.pathExtension.lowercased()
                let valid = ["swift","py","js","ts","html","css","json","c","cpp","h","md","txt","yaml","yml","sh"]
                if valid.contains(ext), let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    ctx += "\n--- FILE: \(relPath(fileURL, from: root)) ---\n\(content)\n--- END ---\n"
                }
            }
        }
        if ctx.isEmpty {
            return "(Proje '\(root.lastPathComponent)' boş. Sıfırdan dosya ve klasör oluşturabilirsin.)"
        }
        return ctx
    }

    func relPath(_ url: URL, from root: URL) -> String {
        let r = root.standardizedFileURL.path
        let f = url.standardizedFileURL.path
        if f.hasPrefix(r) {
            var rel = String(f.dropFirst(r.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }

    enum FSError: Error, LocalizedError {
        case badPath, fsFailure(String)
        var errorDescription: String? {
            switch self {
            case .badPath: return "Geçersiz dosya yolu."
            case .fsFailure(let m): return m
            }
        }
    }

    private func resolve(_ path: String) throws -> URL {
        let root = rootFolderURL ?? ensureDefaultWorkspaceIsActive()
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("..") else { throw FSError.badPath }
        return root.appendingPathComponent(clean)
    }

    @discardableResult
    func apply(_ action: AgentAction) -> String {
        do {
            let target = try resolve(action.path)
            let fm = FileManager.default

            switch action.type {
            case "create_file", "edit_file":
                let dir = target.deletingLastPathComponent()
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: target.path),
                   let old = try? String(contentsOf: target, encoding: .utf8) {
                    fileBackups[target, default: []].insert(
                        BackupVersion(timestamp: Date(), content: old, fileURL: target), at: 0)
                }
                try (action.content ?? "").write(to: target, atomically: true, encoding: .utf8)
                refreshTree()
                if activeFileURL == target { activeFileContent = action.content ?? "" }
                lastCreatedFileURL = target
                return (action.type == "create_file" ? "✅ Oluşturuldu: " : "✏️ Düzenlendi: ") + action.path

            case "delete_file":
                guard fm.fileExists(atPath: target.path) else {
                    return "⚠️ Zaten yok: \(action.path)"
                }
                try fm.removeItem(at: target)
                if activeFileURL == target { activeFileURL = nil; activeFileContent = "" }
                refreshTree()
                return "🗑️ Silindi: \(action.path)"

            case "create_folder":
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                refreshTree()
                return "📁 Klasör: \(action.path)"

            case "delete_folder":
                guard fm.fileExists(atPath: target.path) else {
                    return "⚠️ Klasör yok: \(action.path)"
                }
                try fm.removeItem(at: target)
                refreshTree()
                return "🗑️ Klasör silindi: \(action.path)"

            default:
                return "❓ Bilinmeyen eylem: \(action.type)"
            }
        } catch {
            return "❌ \(action.path): \(error.localizedDescription)"
        }
    }
}

// MARK: - AGENT ENGINE

@MainActor
class AgentEngine: ObservableObject {
    @Published var apiKey: String = UserDefaults.standard.string(forKey: "or_api_key") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "or_api_key") }
    }
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "or_model") ?? "anthropic/claude-sonnet-4-5" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "or_model") }
    }
    @Published var isConnected: Bool = false   // API'ye başarılı ping sonrası true
    @Published var isProcessing: Bool = false
    @Published var agentEnabled: Bool = true

    let models = [
        "anthropic/claude-sonnet-4-5",
        "anthropic/claude-3.5-sonnet",
        "openai/gpt-4o",
        "deepseek/deepseek-coder",
        "meta-llama/llama-3-70b-instruct",
        "google/gemini-2.0-flash-exp:free"
    ]

    // MARK: - Connect (API ping)
    func connect() async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                isConnected = true
                return true
            }
            let _ = String(data: data, encoding: .utf8)
            isConnected = false
            return false
        } catch {
            isConnected = false
            return false
        }
    }

    func disconnect() {
        isConnected = false
    }

    // MARK: - Send to Agent
    func send(
        prompt: String,
        context: String,
        fileContext: String? = nil,
        completion: @escaping (String, [AgentAction]) -> Void
    ) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, isConnected else {
            completion("⚠️ Önce 'Bağlan' butonuna bas.", [])
            return
        }
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            completion("❌ Geçersiz URL.", [])
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let sys = buildSystemPrompt(context: context, fileContext: fileContext)
        var payload: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "system", "content": sys],
                ["role": "user",   "content": prompt]
            ],
            "temperature": 0.15
        ]
        if agentEnabled {
            payload["response_format"] = ["type": "json_object"]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion("❌ JSON hatası.", [])
            return
        }
        req.httpBody = body
        isProcessing = true

        Task { @MainActor in
            defer { isProcessing = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion("❌ Yanıt okunamadı.", [])
                    return
                }
                if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                    completion("❌ API: \(msg)", [])
                    return
                }
                guard let choices = json["choices"] as? [[String: Any]],
                      let msg = choices.first?["message"] as? [String: Any],
                      let content = msg["content"] as? String else {
                    completion("❌ Yanıt ayrıştırılamadı.", [])
                    return
                }
                if agentEnabled {
                    let (exp, acts) = parse(content)
                    completion(exp, acts)
                } else {
                    completion(content, [])
                }
            } catch {
                completion("❌ Ağ hatası: \(error.localizedDescription)", [])
            }
        }
    }

    private func buildSystemPrompt(context: String, fileContext: String?) -> String {
        var extra = ""
        if let fc = fileContext, !fc.isEmpty {
            extra = "\n\n=== AÇIK DOSYA ===\n\(fc)\n=== DOSYA SONU ==="
        }
        if agentEnabled {
            return """
            Sen Antigravity Agent'sın — kullanıcının iOS/macOS/diğer projesinde tam yetkiyle çalışan otonom bir kodlama ajansısın.
            Görevin: Kullanıcının isteğini anlayıp projedeki dosyaları DOĞRUDAN oluşturmak, düzenlemek veya silmek.
            Boş projede bile çalışırsın; izin beklemeden harekete geçersin.

            SADECE aşağıdaki formatta tek bir JSON nesnesi döndür (markdown fence YOK, dışarıda metin YOK):
            {
              "explanation": "Türkçe kısa özet — ne yaptın / ne yapacaksın.",
              "actions": [
                {"type": "create_file",   "path": "göreceli/yol.swift", "content": "tam dosya içeriği"},
                {"type": "edit_file",     "path": "göreceli/yol.swift", "content": "TAM yeni içerik"},
                {"type": "delete_file",   "path": "göreceli/yol.swift"},
                {"type": "create_folder", "path": "göreceli/klasör"},
                {"type": "delete_folder", "path": "göreceli/klasör"}
              ]
            }

            Kurallar:
            - path her zaman proje köküne göreceli (asla mutlak, asla ".." içermez).
            - edit_file için "content" dosyanın TAMAMI olmalı — diff veya parça değil.
            - Sadece soru sorulduysa "actions": [] döndür, cevabı "explanation" a yaz.
            - JSON dışında HİÇBİR metin yazma.

            === PROJE BAĞLAMI ===
            \(context)\(extra)
            === BAĞLAM SONU ===
            """
        } else {
            return """
            Sen Antigravity AI'sın — gelişmiş bir mobil kodlama asistanısın.
            Proje bağlamını analiz et, hataları bul, iyileştirme öner.

            === PROJE BAĞLAMI ===
            \(context)\(extra)
            === BAĞLAM SONU ===
            """
        }
    }

    private func parse(_ raw: String) -> (String, [AgentAction]) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AgentResponse.self, from: data) else {
            return (raw, [])
        }
        return (decoded.explanation, decoded.actions ?? [])
    }
}

// MARK: - SSH CLIENT

@MainActor
class RealSSHClient: ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var lines: [String] = []
    @Published var lastError: String?
    private var client: SSHClient?

    func connect(cfg: SSHServerConfig) async {
        guard !isConnecting else { return }
        isConnecting = true; lastError = nil
        log("[SSH] \(cfg.username)@\(cfg.host):\(cfg.port) bağlanılıyor…")
        do {
            let auth: SSHAuthenticationMethod
            switch cfg.authType {
            case .password:
                guard let p = cfg.password, !p.isEmpty else { throw Err.empty("Parola boş.") }
                auth = .passwordBased(username: cfg.username, password: p)
            case .privateKey:
                guard let k = cfg.privateKey, !k.isEmpty else { throw Err.empty("Key boş.") }
                auth = try Self.keyAuth(username: cfg.username, pem: k)
            }
            let c = try await SSHClient.connect(
                host: cfg.host, port: cfg.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never)
            client = c; isConnected = true
            log("[SSH] ✅ Bağlandı.")
        } catch {
            lastError = error.localizedDescription
            log("❌ \(error.localizedDescription)")
            isConnected = false
        }
        isConnecting = false
    }

    private static func keyAuth(username: String, pem: String) throws -> SSHAuthenticationMethod {
        if let k = try? Curve25519.Signing.PrivateKey(sshEd25519: pem) { return .ed25519(username: username, privateKey: k) }
        if let k = try? Insecure.RSA.PrivateKey(sshRsa: pem) { return .rsa(username: username, privateKey: k) }
        throw Err.badKey
    }

    enum Err: Error, LocalizedError {
        case empty(String), badKey
        var errorDescription: String? {
            switch self {
            case .empty(let m): return m
            case .badKey: return "Anahtar formatı tanınamadı (Ed25519 veya RSA)."
            }
        }
    }

    func disconnect() async {
        try? await client?.close(); client = nil; isConnected = false; log("[SSH] Bağlantı kesildi.")
    }

    func run(_ cmd: String) async {
        guard let c = client else { log("⚠️ Önce bağlan."); return }
        log("$ \(cmd)")
        do {
            let buf = try await c.executeCommand(cmd)
            let out = String(buffer: buf).trimmingCharacters(in: .newlines)
            log(out.isEmpty ? "(çıktı yok)" : out)
        } catch { log("❌ \(error.localizedDescription)") }
    }

    func log(_ line: String) {
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }
    func clear() { lines.removeAll() }
}

// MARK: - MAIN IDE VIEW

struct MainIDEView: View {
    @StateObject var ws   = WorkspaceManager()
    @StateObject var ai   = AgentEngine()

    @State private var showFilePicker  = false
    @State private var showSettings    = false
    @State private var showSSH         = false
    @State private var showNewFile     = false
    @State private var newFileName     = ""

    @State private var chat: [ChatMessage] = [
        ChatMessage(role: "system", text: "Antigravity Agent hazır. 'Bağlan' butonuna basarak API'ye bağlan, sonra istediğini yaz.")
    ]
    @State private var prompt = ""
    @State private var connectStatus = ""

    let symbols = ["{","}"," [","]","(",")",";","=","->","//","\"","'","<",">","?","!","&","|"]

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    editorView
                        .frame(width: geo.size.width * 0.56)
                    Divider().background(Color.gray.opacity(0.3))
                    agentPanelView
                        .frame(width: geo.size.width * 0.44)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.folder, .item],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first { ws.openRoot(url: u) }
        }
        .sheet(isPresented: $showSettings) { SettingsView(ai: ai) }
        .sheet(isPresented: $showSSH)      { SSHTerminalView() }
        .alert("Yeni Dosya", isPresented: $showNewFile) {
            TextField("dosyaadi.swift", text: $newFileName)
                .autocorrectionDisabled()
            Button("Oluştur") { createNewFile() }
            Button("İptal", role: .cancel) { newFileName = "" }
        } message: {
            Text("Proje köküne yeni bir dosya oluşturulacak.")
        }
    }

    // MARK: Sidebar
    var sidebarView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("DOSYALAR")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Button { showNewFile = true } label: {
                    Image(systemName: "doc.badge.plus").foregroundColor(.cyan)
                }
                .help("Yeni dosya oluştur")
                Button { ws.createAndOpenNewEmptyProject() } label: {
                    Image(systemName: "plus.rectangle.on.folder").foregroundColor(.green)
                }
                .help("Yeni boş proje")
                Button { showFilePicker = true } label: {
                    Image(systemName: "folder.badge.plus").foregroundColor(.accentColor)
                }
                .help("Klasör aç")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.11))

            List {
                Section {
                    if let root = ws.rootFolderURL {
                        Label(root.lastPathComponent, systemImage: "folder.fill")
                            .font(.footnote.bold())
                            .foregroundColor(.yellow)
                        if ws.fileTree.isEmpty {
                            Text("Klasör boş")
                                .font(.caption2).foregroundColor(.gray)
                        }
                    }
                    OutlineGroup(ws.fileTree, children: \.children) { f in
                        Button {
                            if !f.isDirectory {
                                ws.loadFile(url: f.url)
                                if ai.isConnected && ai.agentEnabled {
                                    agentAnalyzeOpenedFile(f.url)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: f.isDirectory ? "folder.fill" : iconFor(f.name))
                                    .foregroundColor(f.isDirectory ? .blue : .mint)
                                    .font(.caption)
                                Text(f.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Çalışma Alanı") }

                if let url = ws.activeFileURL,
                   let backups = ws.fileBackups[url], !backups.isEmpty {
                    Section {
                        ForEach(backups.prefix(5)) { b in
                            HStack {
                                Text(b.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
                                Spacer()
                                Button("↩ Geri") { ws.restoreBackup(b) }
                                    .font(.caption2).buttonStyle(.bordered).tint(.orange)
                            }
                        }
                    } header: { Text("Revizyonlar") }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom bar
            HStack {
                Button { showSSH = true } label: {
                    Label("SSH", systemImage: "terminal").font(.caption)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
            .padding(10)
            .background(Color(white: 0.08))
        }
        .background(Color(white: 0.07))
    }

    // MARK: Editor
    var editorView: some View {
        VStack(spacing: 0) {
            // Titlebar
            HStack {
                Image(systemName: "doc.text.fill").foregroundColor(.cyan)
                Text(ws.activeFileURL?.lastPathComponent ?? "— Dosya Seçilmedi —")
                    .font(.system(.footnote, design: .monospaced)).bold()
                Spacer()
                Button { ws.saveActiveFile() } label: {
                    Label("Kaydet", systemImage: "square.and.arrow.down").font(.caption)
                }
                .buttonStyle(.borderedProminent).tint(.blue)
                .disabled(ws.activeFileURL == nil)

                Button {
                    if let url = ws.activeFileURL, ai.isConnected && ai.agentEnabled {
                        agentAnalyzeOpenedFile(url)
                    }
                } label: {
                    Label("Agent Analiz", systemImage: "wand.and.stars").font(.caption)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(!ai.isConnected || ws.activeFileURL == nil)
                .help("Açık dosyayı agent'a analiz ettir")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.13))

            // Shortcut symbols bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(symbols, id: \.self) { sym in
                        Button {
                            ws.activeFileContent.append(sym)
                        } label: {
                            Text(sym)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(minWidth: 28, minHeight: 28)
                                .background(Color(white: 0.19))
                                .foregroundColor(.white)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .background(Color(white: 0.09))

            // Code editor
            ZStack {
                Color(white: 0.03)
                TextEditor(text: $ws.activeFileContent)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .foregroundColor(Color(red: 0.45, green: 1.0, blue: 0.65))
                    .padding(6)
                if ws.activeFileURL == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 48)).foregroundColor(.gray.opacity(0.3))
                        Text("Sol panelden bir dosya seç\nveya 'Yeni Dosya' oluştur")
                            .multilineTextAlignment(.center)
                            .font(.callout).foregroundColor(.gray.opacity(0.5))
                    }
                }
            }
        }
        .background(Color(white: 0.04))
    }

    // MARK: Agent Panel
    var agentPanelView: some View {
        VStack(spacing: 0) {
            // Agent header + connect button
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ai.isConnected ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text("ANTIGRAVITY AGENT")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    // Model picker (compact)
                    Menu {
                        ForEach(ai.models, id: \.self) { m in
                            Button(m) { ai.selectedModel = m }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(ai.selectedModel.components(separatedBy: "/").last ?? ai.selectedModel)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(white: 0.22))
                        .cornerRadius(6)
                    }
                    .foregroundColor(.cyan)

                    // Agent mode toggle
                    Button {
                        ai.agentEnabled.toggle()
                    } label: {
                        Image(systemName: ai.agentEnabled ? "bolt.fill" : "bolt.slash")
                            .foregroundColor(ai.agentEnabled ? .yellow : .gray)
                            .font(.system(size: 14))
                    }
                    .help(ai.agentEnabled ? "Agent Modu Açık — kapat" : "Agent Modu Kapalı — aç")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(white: 0.14))

                // Connect/Disconnect row
                HStack(spacing: 8) {
                    if !ai.isConnected {
                        Button {
                            Task {
                                connectStatus = "Bağlanıyor…"
                                let ok = await ai.connect()
                                connectStatus = ok ? "✅ Bağlandı" : "❌ Bağlantı başarısız"
                                if ok {
                                    chat.append(ChatMessage(role: "system",
                                        text: "API bağlantısı kuruldu (\(ai.selectedModel)). Artık komut verebilirsin."))
                                }
                            }
                        } label: {
                            Label("API'ye Bağlan", systemImage: "network")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .disabled(ai.apiKey.isEmpty)
                    } else {
                        Button {
                            ai.disconnect()
                            connectStatus = "Bağlantı kesildi."
                            chat.append(ChatMessage(role: "system", text: "API bağlantısı kesildi."))
                        } label: {
                            Label("Bağlantıyı Kes", systemImage: "network.slash")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                    }

                    if !connectStatus.isEmpty {
                        Text(connectStatus)
                            .font(.caption2).foregroundColor(.gray).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(white: 0.1))

                if ai.agentEnabled && ai.isConnected {
                    HStack {
                        Image(systemName: "bolt.fill").foregroundColor(.yellow).font(.caption)
                        Text("Agent Modu — dosyaları doğrudan yazar/siler/değiştirir")
                            .font(.caption2).foregroundColor(.orange)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                }

                if ai.apiKey.isEmpty {
                    HStack {
                        Image(systemName: "key.fill").foregroundColor(.red).font(.caption)
                        Text("⚙️ Ayarlar'a giderek OpenRouter API Key gir")
                            .font(.caption2).foregroundColor(.red)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                }
            }

            // Chat area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chat) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: chat) { _ in
                    if let last = chat.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Quick action buttons
            if ai.isConnected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        quickBtn("Dosyayı Analiz Et", icon: "magnifyingglass") {
                            if let url = ws.activeFileURL { agentAnalyzeOpenedFile(url) }
                            else { prompt = "Projeyi genel olarak incele ve iyileştirme öner." }
                        }
                        quickBtn("Hataları Düzelt", icon: "wrench.and.screwdriver") {
                            sendToAgent("Bu projedeki olası hataları ve eksiklikleri bul ve otomatik olarak düzelt.")
                        }
                        quickBtn("Dokümantasyon Ekle", icon: "doc.text") {
                            sendToAgent("Tüm public fonksiyon ve sınıflara uygun dokümantasyon yorumları ekle.")
                        }
                        quickBtn("Refactor Et", icon: "arrow.triangle.2.circlepath") {
                            sendToAgent("Projeyi modern Swift best practice'lerine göre refactor et.")
                        }
                        quickBtn("README Oluştur", icon: "book") {
                            sendToAgent("Proje için detaylı bir README.md dosyası oluştur.")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .background(Color(white: 0.09))
            }

            // Input bar
            HStack(spacing: 8) {
                TextField(ai.isConnected ? "Komut yaz… (Örn: bir SwiftUI view oluştur)" : "Önce 'API'ye Bağlan' butonuna bas",
                          text: $prompt,
                          axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1...4)
                    .padding(8)
                    .background(Color(white: 0.15))
                    .cornerRadius(8)
                    .onSubmit { sendPrompt() }
                    .disabled(!ai.isConnected)

                Button(action: sendPrompt) {
                    if ai.isProcessing {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                            .foregroundColor(ai.isConnected ? .accentColor : .gray)
                    }
                }
                .disabled(!ai.isConnected || ai.isProcessing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(Color(white: 0.08))
        }
        .background(Color(white: 0.06))
    }

    // MARK: Chat bubble
    @ViewBuilder
    func chatBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: roleIcon(msg.role))
                    .font(.system(size: 9)).foregroundColor(roleColor(msg.role))
                Text(roleLabel(msg.role))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(roleColor(msg.role))
            }
            Text(msg.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(msg.isError ? .red : .primary)
                .textSelection(.enabled)

            if !msg.actionLog.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                ForEach(msg.actionLog, id: \.self) { log in
                    HStack(spacing: 4) {
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(log.hasPrefix("❌") ? .red : .green)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(msg.role == "siz" ? Color(white: 0.12) : (msg.role == "system" ? Color(white: 0.09) : Color(white: 0.15)))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(msg.role == "agent" ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: Quick action button
    func quickBtn(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(white: 0.18))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(ai.isProcessing)
    }

    // MARK: Actions
    private func sendPrompt() {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        prompt = ""
        sendToAgent(t)
    }

    private func sendToAgent(_ text: String, fileContext: String? = nil) {
        chat.append(ChatMessage(role: "siz", text: text))
        let ctx = ws.workspaceContext()
        ai.send(prompt: text, context: ctx, fileContext: fileContext) { explanation, actions in
            var logs: [String] = []
            for a in actions { logs.append(ws.apply(a)) }
            chat.append(ChatMessage(role: "agent", text: explanation, actionLog: logs))
        }
    }

    /// Dosya açıldığında veya "Agent Analiz" butonuna basıldığında agent'ı tetikler
    private func agentAnalyzeOpenedFile(_ url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let fileName = url.lastPathComponent
        sendToAgent(
            "'\(fileName)' dosyası açıldı. Bu dosyayı incele: hataları bul, eksik kısımları tamamla, gerekirse düzenle.",
            fileContext: "// \(fileName)\n\(content)"
        )
    }

    private func createNewFile() {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newFileName = ""
        let action = AgentAction(type: "create_file", path: name, content: "// \(name)\n")
        let log = ws.apply(action)
        chat.append(ChatMessage(role: "system", text: log))

        // Yeni dosyayı aç
        if let root = ws.rootFolderURL {
            let url = root.appendingPathComponent(name)
            ws.loadFile(url: url)
        }

        // Agent'a boş dosya hakkında bilgi ver
        if ai.isConnected && ai.agentEnabled {
            sendToAgent("'\(name)' adında yeni boş bir dosya oluşturdum. Bu dosya için başlangıç kodu yaz.")
        }
    }

    // MARK: Helpers
    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py":    return "doc.text.fill"
        case "js","ts": return "doc.text"
        case "json":  return "curlybraces"
        case "md":    return "text.alignleft"
        case "html":  return "globe"
        case "css":   return "paintbrush"
        default:      return "doc"
        }
    }

    private func roleIcon(_ r: String) -> String {
        switch r {
        case "siz": return "person.fill"
        case "agent": return "cpu.fill"
        default: return "info.circle.fill"
        }
    }
    private func roleColor(_ r: String) -> Color {
        switch r {
        case "siz": return .cyan
        case "agent": return .purple
        default: return .gray
        }
    }
    private func roleLabel(_ r: String) -> String {
        switch r {
        case "siz": return "SİZ"
        case "agent": return "AGENT"
        default: return "SİSTEM"
        }
    }
}

// MARK: - SSH TERMINAL VIEW

struct SSHTerminalView: View {
    @StateObject private var ssh = RealSSHClient()
    @State private var cfg = SSHServerConfig(host: "", username: "", authType: .password)
    @State private var cmd = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Sunucu Bilgileri") {
                        TextField("Host / IP", text: $cfg.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Stepper("Port: \(cfg.port)", value: $cfg.port, in: 1...65535)
                        TextField("Kullanıcı Adı", text: $cfg.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Kimlik Doğrulama", selection: $cfg.authType) {
                            ForEach(SSHServerConfig.AuthType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        if cfg.authType == .password {
                            SecureField("Parola", text: Binding($cfg.password, default: ""))
                        } else {
                            TextEditor(text: Binding($cfg.privateKey, default: ""))
                                .frame(height: 70)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if ssh.isConnecting {
                            ProgressView("Bağlanıyor…")
                        } else {
                            Button(ssh.isConnected ? "Bağlantıyı Kes" : "Bağlan") {
                                if ssh.isConnected { Task { await ssh.disconnect() } }
                                else { Task { await ssh.connect(cfg: cfg) } }
                            }
                            .tint(ssh.isConnected ? .red : .green)
                        }
                        if let err = ssh.lastError {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                    }
                }
                .frame(maxHeight: 260)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(ssh.lines.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(line.hasPrefix("❌") ? .red : line.hasPrefix("$") ? .cyan : .green)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                        .padding()
                    }
                    .background(Color(white: 0.02))
                    .onChange(of: ssh.lines) { _ in
                        if let last = ssh.lines.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }

                Divider()
                HStack {
                    Text("$").font(.system(.callout, design: .monospaced)).foregroundColor(.green)
                    TextField("komut girin…", text: $cmd)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(!ssh.isConnected)
                        .onSubmit { runCmd() }
                    Button(action: runCmd) {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .disabled(!ssh.isConnected || cmd.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10).background(Color.black)
            }
            .navigationTitle("SSH Terminal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { Task { await ssh.disconnect() }; dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Temizle") { ssh.clear() }
                }
            }
        }
    }

    private func runCmd() {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        cmd = ""
        Task { await ssh.run(c) }
    }
}

// MARK: - SETTINGS VIEW

struct SettingsView: View {
    @ObservedObject var ai: AgentEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenRouter API Key") {
                    SecureField("sk-or-v1-…", text: $ai.apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("openrouter.ai/keys adresinden ücretsiz key al ↗",
                         destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)
                }
                Section("Varsayılan Model") {
                    Picker("Model", selection: $ai.selectedModel) {
                        ForEach(ai.models, id: \.self) { m in Text(m).tag(m) }
                    }
                }
                Section(header: Text("Agent Modu"),
                        footer: Text("Açıkken AI dosya oluşturur/siler/değiştirir. Kapalıyken sadece metin yanıtı döner.")) {
                    Toggle("Dosya işlemlerine izin ver", isOn: $ai.agentEnabled)
                }
            }
            .navigationTitle("Ayarlar")
            .toolbar { Button("Tamam") { dismiss() } }
        }
    }
}

// MARK: - UTILITY EXTENSIONS

extension Binding {
    init<T>(_ source: Binding<T?>, default dv: T) where Value == T {
        self.init(get: { source.wrappedValue ?? dv }, set: { source.wrappedValue = $0 })
    }
}

// MARK: - ENTRY POINT

@main
struct AntigravityIDEApp: App {
    var body: some Scene {
        WindowGroup {
            MainIDEView()
        }
    }
}
