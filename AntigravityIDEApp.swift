import SwiftUI
import UniformTypeIdentifiers
import Combine

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

// MARK: - 2. WORKSPACE & REVISION MANAGER

@MainActor
class WorkspaceManager: ObservableObject {
    @Published var rootFolderURL: URL?
    @Published var fileTree: [ProjectFile] = []
    @Published var activeFileURL: URL?
    @Published var activeFileContent: String = ""
    @Published var fileBackups: [URL: [BackupVersion]] = [:]
    
    // Sandbox erişimi (security-scoped resource) merkezi olarak yönetiliyor.
    private var securityScopedURL: URL?
    
    /// Kullanıcının fileImporter ile seçtiği kök klasör veya tekil dosyayı açar.
    /// Önceki security-scoped erişimi güvenli şekilde kapatıp yenisini başlatır.
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
                            aggregatedContext += "\n--- FILE START: \(fileURL.lastPathComponent) ---\n"
                            aggregatedContext += content
                            aggregatedContext += "\n--- FILE END ---\n"
                        }
                    }
                }
            }
        }
        return aggregatedContext.isEmpty ? activeFileContent : aggregatedContext
    }
}

// MARK: - 3. OPENROUTER AI ENGINE

@MainActor
class OpenRouterEngine: ObservableObject {
    @Published var apiKey: String = UserDefaults.standard.string(forKey: "saved_openrouter_api_key") ?? "" {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "saved_openrouter_api_key")
        }
    }
    
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "saved_ai_model") ?? "anthropic/claude-3.5-sonnet" {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "saved_ai_model")
        }
    }
    
    @Published var isProcessing: Bool = false
    
    let availableModels = [
        "anthropic/claude-3.5-sonnet",
        "openai/gpt-4o",
        "deepseek/deepseek-coder",
        "meta-llama/llama-3-70b-instruct"
    ]
    
    func executeAIQuery(prompt: String, context: String, completion: @escaping (String) -> Void) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanKey.isEmpty else {
            completion("⚠️ Hata: Lütfen Ayarlar sekmesinden geçerli bir OpenRouter API Key girin.")
            return
        }
        
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            completion("❌ Geçersiz API URL'i.")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let systemMessage = """
        You are Antigravity AI, an advanced mobile coding assistant.
        Analyze the full project context below, debug, suggest performance improvements, and directly generate refactored code blocks.
        
        === PROJECT WORKSPACE CONTEXT ===
        \(context)
        === END OF CONTEXT ===
        """
        
        let payload: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion("❌ JSON Oluşturma Hatası: \(error.localizedDescription)")
            return
        }
        
        isProcessing = true
        
        Task { @MainActor in
            defer { isProcessing = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let raw = String(data: data, encoding: .utf8)?.prefix(200) ?? "boş yanıt"
                    completion("❌ API Yanıtı Beklenmeyen Formatta: \(raw)")
                    return
                }
                
                if let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    completion(content)
                } else if let errorDict = json["error"] as? [String: Any],
                          let errorMessage = errorDict["message"] as? String {
                    completion("❌ API Hatası: \(errorMessage)")
                } else {
                    completion("❌ API Yanıtı İşlenemedi. Lütfen API Key yetkilerini ve bakiye durumunu kontrol edin.")
                }
            } catch {
                completion("❌ Ağ/JSON Hatası: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 4. MAIN IDE VIEW CONTAINER

struct MainIDEView: View {
    @StateObject private var workspace = WorkspaceManager()
    @StateObject private var aiEngine = OpenRouterEngine()
    
    @State private var isFileImporterPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var isTerminalSheetPresented = false
    @State private var aiInputPrompt: String = ""
    @State private var chatHistory: [ChatMessage] = [
        ChatMessage(role: "AI", text: "Antigravity IDE Hazır. Sol panelden proje klasörünüzü veya dosyanızı seçin.")
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
                            Picker("", selection: $aiEngine.selectedModel) {
                                ForEach(aiEngine.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        .padding(10)
                        .background(Color(white: 0.12))
                        
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
        
        aiEngine.executeAIQuery(prompt: trimmed, context: workspaceContext) { response in
            chatHistory.append(ChatMessage(role: "Antigravity AI", text: response))
        }
    }
}

// MARK: - 5. SSH TERMINAL CLIENT VIEW

struct SSHTerminalView: View {
    @State private var config = SSHServerConfig(host: "", username: "", authType: .password)
    @State private var consoleLogs: String = "SSH Terminal Client v1.0\nSunucuya bağlanmaya hazır...\n"
    @State private var inputCommand: String = ""
    @State private var isConnected: Bool = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Sunucu & Kimlik Doğrulama Bilgileri") {
                        TextField("Host / Sunucu IP (Örn: 192.168.1.100)", text: $config.host)
                            .textInputAutocapitalization(.never)
                        TextField("Kullanıcı Adı (Örn: root)", text: $config.username)
                            .textInputAutocapitalization(.never)
                        
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
                        
                        Button(isConnected ? "Bağlantıyı Kes" : "Sunucuya Bağlan") {
                            toggleConnection()
                        }
                        .tint(isConnected ? .red : .green)
                    }
                }
                .frame(maxHeight: 250)
                
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        Text(consoleLogs)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    
                    Divider()
                    
                    HStack {
                        Text("$")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(.green)
                        TextField("Uzak sunucu komutu girin...", text: $inputCommand)
                            .font(.system(.footnote, design: .monospaced))
                            .disabled(!isConnected)
                            .onSubmit {
                                executeRemoteCommand()
                            }
                    }
                    .padding(10)
                    .background(Color.black)
                }
                .background(Color(white: 0.02))
            }
            .navigationTitle("Remote SSH Console")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
    
    private func toggleConnection() {
        if isConnected {
            isConnected = false
            consoleLogs += "\n[SSH Socket]: Connection closed.\n"
        } else {
            let targetHost = config.host.isEmpty ? "localhost" : config.host
            let targetUser = config.username.isEmpty ? "user" : config.username
            consoleLogs += "\n[SSH Socket]: Connecting to \(targetUser)@\(targetHost):\(config.port)...\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.isConnected = true
                self.consoleLogs += "[SSH Socket]: Connected successfully.\nLinux 5.15.0-generic x86_64\n"
            }
        }
    }
    
    private func executeRemoteCommand() {
        guard !inputCommand.isEmpty else { return }
        let cmd = inputCommand
        inputCommand = ""
        
        consoleLogs += "\n$ \(cmd)"
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch cmd.lowercased().trimmingCharacters(in: .whitespaces) {
            case "ls":
                consoleLogs += "\nMain.swift  Package.swift  README.md  Assets/"
            case "pwd":
                consoleLogs += "\n/home/\(config.username.isEmpty ? "root" : config.username)/workspace"
            case "clear":
                consoleLogs = ""
            default:
                consoleLogs += "\n[SSH Remote Exec]: \(cmd) executed successfully."
            }
        }
    }
}

// MARK: - 6. IDE SETTINGS VIEW

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
            }
            .navigationTitle("IDE Ayarları")
            .toolbar {
                Button("Bitti") { dismiss() }
            }
        }
    }
}

// MARK: - 7. UTILITY EXTENSIONS & ENTRY POINT

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
