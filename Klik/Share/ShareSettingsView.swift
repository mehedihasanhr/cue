import SwiftUI

/// Settings › Sharing: where "Copy Share Link" uploads captures.
struct ShareSettingsView: View {
    @Environment(ShareSettings.self) private var settings
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = settings
        SettingsPane(.sharing) {
            Section {
                Picker("Upload to", selection: $settings.provider) {
                    ForEach(ShareSettings.Provider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Name uploads by capture time", isOn: $settings.datedNames)
            } header: {
                Text("Share links")
            } footer: {
                Text("“Copy Share Link” on a capture (or ⌘L in the command palette) uploads the PNG and puts its link on the clipboard. Keys and secrets are kept in your Keychain.")
            }

            if settings.provider == .s3 {
                Section {
                    TextField("Endpoint", text: $settings.endpoint, prompt: Text("s3.amazonaws.com · <account>.r2.cloudflarestorage.com"))
                    TextField("Region", text: $settings.region, prompt: Text("us-east-1 · auto"))
                    TextField("Bucket", text: $settings.bucket)
                    TextField("Key prefix", text: $settings.prefix, prompt: Text("klik/"))
                    TextField("Access key ID", text: $settings.accessKey)
                    SecureField("Secret access key", text: $settings.secretKey)
                    TextField("Public URL base", text: $settings.publicBase, prompt: Text("https://cdn.example.com (optional)"))
                } header: {
                    Text("S3-compatible bucket")
                } footer: {
                    Text("Uploads are PUT with SigV4 and public-read. With R2, set a public bucket domain as the URL base.")
                }
            }

            if settings.provider == .custom {
                Section {
                    TextField("URL", text: $settings.customURL, prompt: Text("https://example.com/upload/{name}"))
                    Picker("Method", selection: $settings.customMethod) {
                        Text("PUT (raw PNG body)").tag(ShareSettings.Method.put)
                        Text("POST (multipart, field “file”)").tag(ShareSettings.Method.post)
                    }
                    HStack {
                        TextField("Header", text: $settings.customHeaderName, prompt: Text("Authorization"))
                        SecureField("Value", text: $settings.customHeaderValue, prompt: Text("Bearer …"))
                    }
                    TextField("Link in JSON answer", text: $settings.customResponseKey, prompt: Text("url · data.link (empty: body is the link)"))
                } header: {
                    Text("Custom endpoint")
                } footer: {
                    Text("{name} in the URL becomes the file name. With an empty answer the request URL is the link.")
                }
            }

            if settings.provider != .off {
                Section {
                    HStack {
                        Button(testing ? "Testing…" : "Test Upload") { test() }
                            .disabled(testing || !settings.isConfigured)
                        Spacer()
                        if let testResult {
                            Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
            }
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
