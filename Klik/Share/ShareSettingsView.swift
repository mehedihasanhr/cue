import SwiftUI

/// Settings › Sharing: where "Copy Share Link" uploads captures.
struct ShareSettingsView: View {
    @Environment(ShareSettings.self) private var settings
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = settings
        SettingsPane(.sharing) {
            SettingsGroup("Share links") {
                SettingsRow("Upload to") {
                    Picker("Upload to", selection: $settings.provider) {
                        ForEach(ShareSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                SettingsRow("Name uploads by capture time") {
                    Toggle("Dated names", isOn: $settings.datedNames).toggleStyle(.switch)
                }
            }

            if settings.provider == .s3 {
                SettingsGroup("S3-compatible bucket") {
                    field("Endpoint", text: $settings.endpoint, prompt: "s3.amazonaws.com · <account>.r2.cloudflarestorage.com")
                    field("Region", text: $settings.region, prompt: "us-east-1 · auto")
                    field("Bucket", text: $settings.bucket)
                    field("Key prefix", text: $settings.prefix, prompt: "klik/")
                    field("Access key ID", text: $settings.accessKey)
                    SettingsRow("Secret access key") {
                        SecureField("Secret access key", text: $settings.secretKey).textFieldStyle(.roundedBorder).frame(width: 300)
                    }
                    field("Public URL base", text: $settings.publicBase, prompt: "https://cdn.example.com (optional)")
                }
            }

            if settings.provider == .custom {
                SettingsGroup("Custom endpoint") {
                    field("URL", text: $settings.customURL, prompt: "https://example.com/upload/{name}")
                    SettingsRow("Method") {
                        Picker("Method", selection: $settings.customMethod) {
                            Text("PUT (raw PNG body)").tag(ShareSettings.Method.put)
                            Text("POST (multipart, field “file”)").tag(ShareSettings.Method.post)
                        }
                        .fixedSize()
                    }
                    SettingsRow("Header") {
                        HStack(spacing: 8) {
                            TextField("Header", text: $settings.customHeaderName, prompt: Text("Authorization")).frame(width: 120)
                            SecureField("Value", text: $settings.customHeaderValue, prompt: Text("Bearer …")).frame(width: 172)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    field("Link in JSON answer", text: $settings.customResponseKey, prompt: "url · data.link (empty: body is the link)")
                }
            }

            if settings.provider != .off {
                SettingsGroup {
                    SettingsRow("Test", subtitle: testResult) {
                        Button(testing ? "Testing…" : "Test Upload") { test() }
                            .disabled(testing || !settings.isConfigured)
                    }
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String? = nil) -> some View {
        SettingsRow(title) {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
        }
    }

    /// Uploads a tiny image and shows the link (or the error) inline.
    private func test() {
        testing = true
        testResult = nil
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(Color.brand).setFill(); rect.fill(); return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = ImageEncoding.png(cg) else { testing = false; return }
        let settings = settings
        Task { @MainActor in
            do {
                let url = try await ShareUploader.upload(png, name: "klik-test.png", settings: settings)
                testResult = url.absoluteString
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}
