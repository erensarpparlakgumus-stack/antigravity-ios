import SwiftUI
import UniformTypeIdentifiers
import Combine
import Citadel   // SPM: https://github.com/orlandos-nl/Citadel — gerçek SSH protokolü (SwiftNIO tabanlı)
import NIOCore
import Crypto

// MARK: - 1. DATA MODELS & FILE SYSTEM ARCHITECTURE

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
    let role: String
    let text: String
    var actionLog: [String] = []
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

// MARK: - AI AGENT ACTION MODEL

struct AgentAction: Codable, Identifiable {
    var id: String { path + type }
    let type: String
    let path: String
    var content: String?
}

struct AgentResponse: Codable {
    let explanation: String
    let actions: [AgentAction]?
}

// MARK: - 2. WORKSPACE & REVISION MANAGER

@MainActor
class WorkspaceManager: ObservableObject {
    @Published var rootFolderURL: URL?
    @Published var fileTree: [ProjectFile] = []
    @Published var activeFileURL: URL?
    @Published var activeFileContent: String = ""
    @Published var fileBackups: [URL: [BackupVersion]] = [:]

    private var securityScopedURL: URL?

    func openRoot(url: URL) {
        releaseSecurityScopedAccessIfNeeded()

        guard url.startAccessingSecurityScopedResource() else {
            print("Erişim izni alınamadı.")
            return
        }
        securityScopedURL = url

        if url.hasDirectoryPath {
            setRootDirectory(url)
        } else {
            loadFile(url: url)
        }
    }

    private func releaseSecurityScopedAccessIfNeeded() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    func setRootDirectory(_ url: URL) {
        self.rootFolderURL = url
        self.fileTree = buildFileTree(for: url)
    }

    func refreshTree() {
        guard let root = rootFolderURL else { return }
        self.fileTree = buildFileTree(for: root)
    }

    func loadFile(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            self.activeFileURL = url
            self.activeFileContent = content
        } catch {
            print("Dosya okuma hatası: \(error.localizedDescription)")
        }
    }

    func saveActiveFile() {
        guard let url = activeFileURL else { return }

        let newBackup = BackupVersion(timestamp: Date(), content: activeFileContent, fileURL: url)
        if fileBackups[url] != nil {
            fileBackups[url]?.insert(newBackup, at: 0)
        } else {
            fileBackups[url] = [newBackup]
        }

        do {
            try activeFileContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("Dosya yazma hatası: \(error.localizedDescription)")
        }
    }

    func restoreBackup(_ backup: BackupVersion) {
        self.activeFileContent = backup.content
        saveActiveFile()
    }

    private func buildFileTree(for url: URL) -> [ProjectFile] {
        let fileManager = FileManager.default
        var children: [ProjectFile] = []

        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for itemURL in items {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = resourceValues?.isDirectory ?? false

            var subChildren: [ProjectFile]? = nil
            if isDir {
                subChildren = buildFileTree(for: itemURL)
            }

            let node = ProjectFile(
                name: itemURL.lastPathComponent,
                url: itemURL,
                isDirectory: isDir,
                children: subChildren
            )
            children.append(node)
        }

        return children.sorted {
            if $0.isDirectory == $1.isDirectory {
                return $0.name.lowercased() < $1.name.lowercased()
            }
            return $0.isDirectory && !$1.isDirectory
        }
    }

    func extractFullWorkspaceContext() -> String {
        guard let rootURL = rootFolderURL else { return activeFileContent }

        var aggregatedContext = ""
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                if !fileURL.hasDirectoryPath {
                    let ext = fileURL.pathExtension.lowercased()
                    let validExtensions = ["swift", "py", "js", "ts", "html", "css", "json", "c", "cpp", "h", "md", "txt"]
                    if validExtensions.contains(ext) {
                        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                            let relativePath = relativePath(for: fileURL, from: rootURL)
                            aggregatedContext += "\n--- FILE START: \(relativePath) ---\n"
                            aggregatedContext += content
                            aggregatedContext += "\n--- FILE END ---\n"
                        }
                    }
                }
            }
        }
        return aggregatedContext.isEmpty ? activeFileContent : aggregatedContext
    }

    func relativePath(for url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(rootPath) {
            var relative = String(fullPath.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            return relative
        }
        return url.lastPathComponent
    }

    enum AgentFileError: Error, LocalizedError {
        case noRoot
        case invalidPath
        case fsError(String)

        var errorDescription: String? {
            switch self {
            case .noRoot: return "Önce bir proje klasörü açmalısınız."
            case .invalidPath: return "Geçersiz veya güvensiz dosya yolu."
            case .fsError(let msg): return msg
            }
        }
    }

    private func resolvedURL(forRelativePath path: String) throws -> URL {
        guard let root = rootFolderURL else { throw AgentFileError.noRoot }
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("..") else { throw AgentFileError.invalidPath }
        return root.appendingPathComponent(cleaned)
    }

    @discardableResult
    func applyAgentAction(_ action: AgentAction) -> String {
        do {
            let target = try resolvedURL(forRelativePath: action.path)
            let fm = FileManager.default

            switch action.type {
            case "create_file", "edit_file":
                let parentDir = target.deletingLastPathComponent()
                if !fm.fileExists(atPath: parentDir.path) {
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: target.path), let existing = try? String(contentsOf: target, encoding: .utf8) {
                    let backup = BackupVersion(timestamp: Date(), content: existing, fileURL: target)
                    fileBackups[target, default: []].insert(backup, at: 0)
                }
                try (action.content ?? "").write(to: target, atomically: true, encoding: .utf8)
                refreshTree()
                if activeFileURL == target { activeFileContent = action.content ?? "" }
                return (action.type == "create_file" ? "✅ Oluşturuldu: " : "✏️ Düzenlendi: ") + action.path

            case "delete_file":
                guard fm.fileExists(atPath: target.path) else {
                    return "⚠️ Bulunamadı (zaten yok): \(action.path)"
                }
                try fm.removeItem(at: target)
                if activeFileURL == target {
                    activeFileURL = nil
                    activeFileContent = ""
                }
                refreshTree()
                return "🗑️ Silindi: \(action.path)"

            case "create_folder":
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                refreshTree()
                return "📁 Klasör oluşturuldu: \(action.path)"

            case "delete_folder":
                guard fm.fileExists(atPath: target.path) else {
                    return "⚠️ Klasör bulunamadı: \(action.path)"
                }
                try fm.removeItem(at: target)
                refreshTree()
                return "🗑️ Klasör silindi: \(action.path)"

            default:
                return "❌ Bilinmeyen eylem türü: \(action.type)"
            }
        } catch let error as AgentFileError {
            return "❌ \(action.path): \(error.localizedDescription)"
        } catch {
            return "❌ \(action.path): \(error.localizedDescription)"
        }
    }
}

// MARK: - 3. OPENROUTER AI ENGINE (AGENTIC)

@MainActor
class OpenRouterEngine: ObservableObject {
    @Published var apiKey: String = UserDefaults.standard.string(forKey: "saved_openrouter_api_key") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "saved_openrouter_api_key") }
    }

    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "saved_ai_model") ?? "anthropic/claude-3.5-sonnet" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "saved_ai_model") }
    }

    @Published var agentModeEnabled: Bool = UserDefaults.standard.object(forKey: "saved_agent_mode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(agentModeEnabled, forKey: "saved_agent_mode") }
    }

    @Published var isProcessing: Bool = false

    let availableModels = [
        "anthropic/claude-3.5-sonnet",
        "openai/gpt-4o",
        "deepseek/deepseek-coder",
        "meta-llama/llama-3-70b-instruct"
    ]

    private func systemPrompt(context: String) -> String {
        if agentModeEnabled {
            return """
            You are Antigravity Agent, an autonomous mobile coding agent with direct read/write access \
            to the user's project folder. You do not just suggest code — you make the changes yourself.

            You MUST respond with ONLY a single valid JSON object, no markdown fences, no prose outside JSON:
            {
              "explanation": "Kullanıcıya kısa Türkçe açıklama (ne yaptığın / önerin).",
              "actions": [
                {"type": "create_file", "path": "relative/path.swift", "content": "full file content"},
                {"type": "edit_file", "path": "relative/path.swift", "content": "full NEW file content"},
                {"type": "delete_file", "path": "relative/path.swift"},
                {"type": "create_folder", "path": "relative/folder"},
                {"type": "delete_folder", "path": "relative/folder"}
              ]
            }

            Rules:
            - "path" is always relative to the project root shown in the context below (never absolute, never "..").
            - For edit_file, "content" must be the COMPLETE new file content, not a diff or partial snippet.
            - If the user only asks a question and no file change is needed, return "actions": [] and put your answer in "explanation".
            - Never wrap the JSON in ```json fences. Return raw JSON only.

            === PROJECT WORKSPACE CONTEXT ===
            \(context)
            === END OF CONTEXT ===
            """
        } else {
            return """
            You are Antigravity AI, an advanced mobile coding assistant.
            Analyze the full project context below, debug, suggest performance improvements, and directly generate refactored code blocks.

            === PROJECT WORKSPACE CONTEXT ===
            \(context)
            === END OF CONTEXT ===
            """
        }
    }

    func executeAIQuery(
        prompt: String,
        context: String,
        completion: @escaping (_ explanation: String, _ actions: [AgentAction]) -> Void
    ) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanKey.isEmpty else {
            completion("⚠️ Hata: Lütfen Ayarlar sekmesinden geçerli bir OpenRouter API Key girin.", [])
            return
        }

        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            completion("❌ Geçersiz API URL'i.", [])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemMessage = systemPrompt(context: context)
        var payload: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2
        ]
        if agentModeEnabled {
            payload["response_format"] = ["type": "json_object"]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion("❌ JSON Oluşturma Hatası: \(error.localizedDescription)", [])
            return
        }

        isProcessing = true

        Task { @MainActor in
            defer { isProcessing = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let raw = String(data: data, encoding: .utf8)?.prefix(200) ?? "boş yanıt"
                    completion("❌ API Yanıtı Beklenmeyen Formatta: \(raw)", [])
                    return
                }

                if let errorDict = json["error"] as? [String: Any],
                   let errorMessage = errorDict["message"] as? String {
                    completion("❌ API Hatası: \(errorMessage)", [])
                    return
                }

                guard let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    completion("❌ API Yanıtı İşlenemedi. Lütfen API Key yetkilerini ve bakiye durumunu kontrol edin.", [])
                    return
                }

                if self.agentModeEnabled {
                    let (explanation, actions) = self.parseAgentResponse(content)
                    completion(explanation, actions)
                } else {
                    completion(content, [])
                }
            } catch {
                completion("❌ Ağ/JSON Hatası: \(error.localizedDescription)", [])
            }
        }
    }

    private func parseAgentResponse(_ raw: String) -> (String, [AgentAction]) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8) else {
            return (raw, [])
        }

        do {
            let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)
            return (decoded.explanation, decoded.actions ?? [])
        } catch {
            return (raw, [])
        }
    }
}

// MARK: - 4. GERÇEK SSH CLIENT (Citadel / SwiftNIO SSH)

@MainActor
class RealSSHClient: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var consoleLines: [String] = []
    @Published var lastError: String?

    private var client: SSHClient?

    func connect(config: SSHServerConfig) async {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil
        append("[SSH]: \(config.username)@\(config.host):\(config.port) adresine bağlanılıyor...")

        do {
            let authMethod: SSHAuthenticationMethod

            switch config.authType {
            case .password:
                guard let pass = config.password, !pass.isEmpty else {
                    throw SSHSetupError.emptyCredential("Parola boş olamaz.")
                }
                authMethod = .passwordBased(username: config.username, password: pass)

            case .privateKey:
                guard let keyString = config.privateKey, !keyString.isEmpty else {
                    throw SSHSetupError.emptyCredential("Private key boş olamaz.")
                }
                authMethod = try Self.buildKeyAuthMethod(username: config.username, pemKey: keyString)
            }

            let newClient = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )

            self.client = newClient
            self.isConnected = true
            append("[SSH]: Bağlantı başarılı. Kimlik doğrulandı.")
        } catch {
            self.lastError = error.localizedDescription
            append("❌ [SSH Hatası]: \(error.localizedDescription)")
            self.isConnected = false
        }
        isConnecting = false
    }

    private static func buildKeyAuthMethod(username: String, pemKey: String) throws -> SSHAuthenticationMethod {
        if let ed25519 = try? Curve25519.Signing.PrivateKey(sshEd25519: pemKey) {
            return .ed25519(username: username, privateKey: ed25519)
        }
        if let rsa = try? Insecure.RSA.PrivateKey(sshRsa: pemKey) {
            return .rsa(username: username, privateKey: rsa)
        }
        throw SSHSetupError.unsupportedKeyFormat
    }

    enum SSHSetupError: Error, LocalizedError {
        case emptyCredential(String)
        case unsupportedKeyFormat

        var errorDescription: String? {
            switch self {
            case .emptyCredential(let msg): return msg
            case .unsupportedKeyFormat: return "Anahtar formatı tanınamadı (Ed25519 veya RSA PEM bekleniyor)."
            }
        }
    }

    func disconnect() async {
        guard let client = client else { return }
        try? await client.close()
        self.client = nil
        self.isConnected = false
        append("[SSH]: Bağlantı kapatıldı.")
    }

    func execute(_ command: String) async {
        guard let client = client else {
            append("⚠️ Önce sunucuya bağlanmalısınız.")
            return
        }
        append("$ \(command)")
        do {
            let outputBuffer = try await client.executeCommand(command)
            let text = String(buffer: outputBuffer)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append("(çıktı yok)")
            } else {
                append(text.trimmingCharacters(in: .newlines))
            }
        } catch {
            append("❌ Komut hatası: \(error.localizedDescription)")
        }
    }

    private func append(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 500 {
            consoleLines.removeFirst(consoleLines.count - 500)
        }
    }

    func clearConsole() {
        consoleLines.removeAll()
    }
}

// MARK: - 5. MAIN IDE VIEW CONTAINER

struct MainIDEView: View {
    @StateObject private var workspace = WorkspaceManager()
    @StateObject private var aiEngine = OpenRouterEngine()

    @State private var isFileImporterPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var isTerminalSheetPresented = false
    @State private var aiInputPrompt: String = ""
    @State private var chatHistory: [ChatMessage] = [
        ChatMessage(role: "AI", text: "Antigravity IDE Hazır. Sol panelden proje klasörünüzü seçin. Agent modu açıkken AI, dosyalarınızı doğrudan oluşturabilir, düzenleyebilir veya silebilir.")
    ]

    let keySymbols = ["{", "}", "[", "]", "(", ")", "<", ">", ";", "=", "+", "-", "*", "/", "\""]

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("PROJE DİZİNİ")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Button(action: { isFileImporterPresented = true }) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                }
                .padding()
                .background(Color(white: 0.1))

                List {
                    Section(header: Text("Açık Çalışma Alanı")) {
                        if let root = workspace.rootFolderURL {
                            Label(root.lastPathComponent, systemImage: "folder.fill")
                                .font(.footnote)
                                .foregroundColor(.yellow)
                        } else {
                            Text("Henüz bir klasör açılmadı.")
                                .font(.footnote)
                                .foregroundColor(.gray)
                        }

                        OutlineGroup(workspace.fileTree, children: \.children) { file in
                            Button(action: {
                                if !file.isDirectory {
                                    workspace.loadFile(url: file.url)
                                }
                            }) {
                                HStack {
                                    Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                                        .foregroundColor(file.isDirectory ? .blue : .green)
                                    Text(file.name)
                                        .font(.system(.footnote, design: .monospaced))
                                }
                            }
                        }
                    }

                    if let activeURL = workspace.activeFileURL,
                       let backups = workspace.fileBackups[activeURL], !backups.isEmpty {
                        Section(header: Text("Revizyon Sürümleri")) {
                            ForEach(backups) { backup in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(backup.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    Button("Geri Yükle") {
                                        workspace.restoreBackup(backup)
                                    }
                                    .font(.caption2)
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button(action: { isTerminalSheetPresented.toggle() }) {
                        Label("SSH Terminal", systemImage: "terminal")
                            .font(.footnote)
                    }
                    Spacer()
                    Button(action: { isSettingsSheetPresented.toggle() }) {
                        Image(systemName: "gearshape")
                    }
                }
                .padding()
                .background(Color(white: 0.08))
            }
            .background(Color(white: 0.06))

        } detail: {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.cyan)
                            Text(workspace.activeFileURL?.lastPathComponent ?? "Dosya Seçilmedi")
                                .font(.system(.footnote, design: .monospaced))
                                .bold()
                            Spacer()
                            Button(action: { workspace.saveActiveFile() }) {
                                Label("Kaydet & Yedekle", systemImage: "square.and.arrow.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                        .padding(10)
                        .background(Color(white: 0.12))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(keySymbols, id: \.self) { symbol in
                                    Button(action: {
                                        workspace.activeFileContent.append(symbol)
                                    }) {
                                        Text(symbol)
                                            .font(.system(.callout, design: .monospaced))
                                            .frame(width: 32, height: 32)
                                            .background(Color(white: 0.18))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .background(Color(white: 0.08))

                        TextEditor(text: $workspace.activeFileContent)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .background(Color(white: 0.03))
                            .foregroundColor(Color(red: 0.4, green: 1.0, blue: 0.6))
                            .padding(4)
                    }
                    .frame(width: geometry.size.width * 0.58)

                    Divider()
                        .background(Color.gray.opacity(0.3))

                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.purple)
                            Text("Antigravity Copilot")
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            Toggle(isOn: $aiEngine.agentModeEnabled) {
                                Image(systemName: aiEngine.agentModeEnabled ? "bolt.fill" : "bolt.slash")
                                    .foregroundColor(aiEngine.agentModeEnabled ? .yellow : .gray)
                            }
                            .toggleStyle(.button)
                            .help(aiEngine.agentModeEnabled ? "Agent Modu Açık: AI dosyaları doğrudan değiştirebilir" : "Agent Modu Kapalı: AI sadece öneri sunar")

                            Picker("", selection: $aiEngine.selectedModel) {
                                ForEach(aiEngine.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .padding(10)
                        .background(Color(white: 0.12))

                        if aiEngine.agentModeEnabled {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Agent Modu Açık — AI dosyaları doğrudan oluşturabilir, düzenleyebilir veya silebilir.")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.12))
                        }

                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(chatHistory) { chat in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(chat.role)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundColor(chat.role == "Siz" ? .cyan : .purple)
                                            Text(chat.text)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)

                                            if !chat.actionLog.isEmpty {
                                                Divider().background(Color.gray.opacity(0.3))
                                                ForEach(chat.actionLog, id: \.self) { log in
                                                    Text(log)
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundColor(.green)
                                                }
                                            }
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(chat.role == "Siz" ? Color(white: 0.1) : Color(white: 0.14))
                                        .cornerRadius(8)
                                        .id(chat.id)
                                    }
                                }
                                .padding(10)
                            }
                            .onChange(of: chatHistory) { _ in
                                if let lastMessage = chatHistory.last {
                                    withAnimation {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        }

                        Divider()

                        HStack {
                            TextField("Kod ile ilgili komut veya soru yazın...", text: $aiInputPrompt)
                                .textFieldStyle(.plain)
                                .font(.footnote)
                                .padding(8)
                                .background(Color(white: 0.15))
                                .cornerRadius(6)
                                .onSubmit(sendPromptToAI)

                            Button(action: sendPromptToAI) {
                                if aiEngine.isProcessing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .disabled(aiEngine.isProcessing)
                        }
                        .padding(10)
                        .background(Color(white: 0.08))
                    }
                    .frame(width: geometry.size.width * 0.42)
                    .background(Color(white: 0.07))
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.folder, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                workspace.openRoot(url: url)
            case .failure(let error):
                print("Dosya seçimi başarısız: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $isSettingsSheetPresented) {
            SettingsView(aiEngine: aiEngine)
        }
        .sheet(isPresented: $isTerminalSheetPresented) {
            SSHTerminalView()
        }
    }

    private func sendPromptToAI() {
        let trimmed = aiInputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        chatHistory.append(ChatMessage(role: "Siz", text: trimmed))
        aiInputPrompt = ""

        let workspaceContext = workspace.extractFullWorkspaceContext()

        aiEngine.executeAIQuery(prompt: trimmed, context: workspaceContext) { explanation, actions in
            var logs: [String] = []
            for action in actions {
                let result = workspace.applyAgentAction(action)
                logs.append(result)
            }
            chatHistory.append(ChatMessage(role: "Antigravity AI", text: explanation, actionLog: logs))
        }
    }
}

// MARK: - 6. SSH TERMINAL CLIENT VIEW (GERÇEK BAĞLANTI)

struct SSHTerminalView: View {
    @StateObject private var ssh = RealSSHClient()
    @State private var config = SSHServerConfig(host: "", username: "", authType: .password)
    @State private var inputCommand: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Sunucu & Kimlik Doğrulama Bilgileri") {
                        TextField("Host / Sunucu IP (Örn: 192.168.1.100)", text: $config.host)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        Stepper("Port: \(config.port)", value: $config.port, in: 1...65535)
                        TextField("Kullanıcı Adı (Örn: root)", text: $config.username)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        Picker("Kimlik Doğrulama Türü", selection: $config.authType) {
                            ForEach(SSHServerConfig.AuthType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }

                        if config.authType == .password {
                            SecureField("SSH Parolası", text: Binding($config.password, default: ""))
                        } else {
                            TextEditor(text: Binding($config.privateKey, default: ""))
                                .frame(height: 80)
                                .font(.system(size: 10, design: .monospaced))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4), lineWidth: 1))
                        }

                        if ssh.isConnecting {
                            HStack {
                                ProgressView()
                                Text("Bağlanıyor...")
                            }
                        } else {
                            Button(ssh.isConnected ? "Bağlantıyı Kes" : "Sunucuya Bağlan") {
                                toggleConnection()
                            }
                            .tint(ssh.isConnected ? .red : .green)
                        }

                        if let error = ssh.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                .frame(maxHeight: 280)

                VStack(alignment: .leading, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(ssh.consoleLines.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(line.hasPrefix("❌") ? .red : (line.hasPrefix("$") ? .cyan : .green))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(idx)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: ssh.consoleLines) { _ in
                            if let lastIndex = ssh.consoleLines.indices.last {
                                withAnimation { proxy.scrollTo(lastIndex, anchor: .bottom) }
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Text("$")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(.green)
                        TextField("Uzak sunucu komutu girin...", text: $inputCommand)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .disabled(!ssh.isConnected)
                            .onSubmit {
                                executeRemoteCommand()
                            }
                        Button(action: executeRemoteCommand) {
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .disabled(!ssh.isConnected || inputCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(10)
                    .background(Color.black)
                }
                .background(Color(white: 0.02))
            }
            .navigationTitle("Remote SSH Console")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") {
                        Task { await ssh.disconnect() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Temizle") { ssh.clearConsole() }
                }
            }
        }
    }

    private func toggleConnection() {
        if ssh.isConnected {
            Task { await ssh.disconnect() }
        } else {
            Task { await ssh.connect(config: config) }
        }
    }

    private func executeRemoteCommand() {
        let cmd = inputCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        inputCommand = ""
        Task { await ssh.execute(cmd) }
    }
}

// MARK: - 7. IDE SETTINGS VIEW

struct SettingsView: View {
    @ObservedObject var aiEngine: OpenRouterEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("OpenRouter API Yapılandırması")) {
                    SecureField("API Key (sk-or-v1-...)", text: $aiEngine.apiKey)
                    Link("OpenRouter Paneli üzerinden Key Alın ↗", destination: URL(string: "https://openrouter.ai/keys")!)
                        .font(.caption)
                }

                Section(header: Text("Varsayılan Yapay Zeka Modeli")) {
                    Picker("Model", selection: $aiEngine.selectedModel) {
                        ForEach(aiEngine.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                Section(
                    header: Text("Agent Modu"),
                    footer: Text("Agent modu açıkken AI, proje klasörünüzdeki dosyaları sizin onayınız olmadan doğrudan oluşturabilir, düzenleyebilir veya silebilir. Kapalıyken sadece öneri metni döner, dosyalara dokunmaz.")
                ) {
                    Toggle("Dosyaları doğrudan değiştirmesine izin ver", isOn: $aiEngine.agentModeEnabled)
                }
            }
            .navigationTitle("IDE Ayarları")
            .toolbar {
                Button("Bitti") { dismiss() }
            }
        }
    }
}

// MARK: - 8. UTILITY EXTENSIONS & ENTRY POINT

extension Binding {
    init<T>(_ source: Binding<T?>, default defaultValue: T) where Value == T {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 }
        )
    }
}

@main
struct AntigravityIDEApp: App {
    var body: some Scene {
        WindowGroup {
            MainIDEView()
        }
    }
}
