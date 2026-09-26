# Antigravity IDE (iOS & macOS SwiftUI Application)

Antigravity IDE, SwiftUI ve OpenRouter API entegrasyonu ile geliştirilmiş gelişmiş bir mobil/masaüstü kod editörüdür.

## Öne Çıkan Özellikler

1. **Çalışma Alanı & Dosya Yönetimi (`WorkspaceManager`)**
   - Security-scoped URL kaynak yönetimi (Sandbox uyumlu).
   - Klasör ağacı görünümü ve dosya içeriklerini anlık okuma/yazma.
   - Otomatik revizyon geçmişi ve versiyon geri yükleme (Backup Version History).
   - Tam proje bağlamı çıkarma (`extractFullWorkspaceContext`) ile yapay zekaya tüm projenizi gönderme.

2. **OpenRouter AI Copilot (`OpenRouterEngine`)**
   - Claude 3.5 Sonnet, GPT-4o, DeepSeek Coder ve Llama 3 modelleri desteği.
   - Proje kod bağlamı ile zenginleştirilmiş AI rehberliği ve refactoring.
   - Asenkron `Task @MainActor` yapısı ile UI donmalarını ve concurrency hatalarını önleyen mimari.

3. **Gelişmiş Kod Editör Arayüzü (`MainIDEView`)**
   - Split view yerleşimi (Sol: Dosya ağacı & Sürümler, Orta: Kod Editörü, Sağ: Copilot Chat).
   - Hızlı sembol barı (`{`, `}`, `[`, `]`, `(`, `)`, vb.) ile mobil klavye kolaylığı.

4. **Uzak SSH Terminal Konsolu (`SSHTerminalView`)**
   - Sunucu kimlik doğrulama ayarları (Parola / RSA Private Key).
   - İnteraktif komut satırı ve konsol çıktısı ekranı.

5. **Ayarlar Paneli (`SettingsView`)**
   - OpenRouter API Anahtarı ve Varsayılan Yapay Zeka modeli seçimi.

## Xcode İçinde Çalıştırma

1. Mac üzerinde **Xcode**'u açın.
2. **New Project** -> **App** (Platform: iOS veya macOS, Interface: SwiftUI) oluşturun.
3. `AntigravityIDEApp.swift` dosyasındaki kodları projenize ekleyin.
4. Hedef cihazı (iPad, iPhone veya Mac) seçip **Run (⌘R)** butonuna basın.
