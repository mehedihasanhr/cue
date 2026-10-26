import AVFoundation
import SwiftUI

/// The camera as a mirror in the island, to check how you look before a call. The
/// camera runs only while it shows.
struct MirrorView: View {
    static let width: CGFloat = 400
    static let height: CGFloat = 262

    var close: () -> Void = {}
    @State private var camera = MirrorCamera()
    /// A soft white glow round the picture: light on a face in a dark room.
    @AppStorage("island.mirror.light") private var light = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 10) {
            ZStack {
                shape.fill(.white.opacity(0.06))
                switch camera.state {
                case .running:
                    CameraPreview(session: camera.session)
                        .clipShape(shape)
                        .transition(.opacity)
                case .denied:
                    message("Camera access is off", "Allow Cue in Privacy & Security › Camera, then open the mirror again.",
                            action: ("Open Camera Settings", {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                                close()
                            }))
                case .unavailable:
                    message("No camera", "Connect one, or check it isn't in use.")
                case .starting:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 196)
            .overlay(shape.strokeBorder(.white.opacity(light ? 0.9 : 0.1), lineWidth: light ? 3 : 1))
            .shadow(color: .white.opacity(light ? 0.55 : 0), radius: 18)
            HStack(spacing: 8) {
                if camera.devices.count > 1 {
                    Menu {
                        ForEach(camera.devices, id: \.uniqueID) { device in
                            Button {
                                camera.use(device)
                            } label: {
                                if device.uniqueID == camera.current?.uniqueID { Label(device.localizedName, systemImage: "checkmark") } else { Text(device.localizedName) }
                            }
                        }
                    } label: {
                        chip("video.fill", camera.current?.localizedName ?? "Camera")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    chip("video.fill", camera.current?.localizedName ?? "Camera")
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.25)) { light.toggle() } } label: {
                    chip(light ? "lightbulb.fill" : "lightbulb", light ? "Light on" : "Light", lit: light)
                }
                .buttonStyle(.plain)
                .help("A glow round the picture, to light your face")
                Button(action: close) { chip("xmark", nil) }
                    .buttonStyle(.plain)
                    .help("Close")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(width: Self.width, height: Self.height)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .animation(.easeOut(duration: 0.2), value: camera.state)
    }

    private func chip(_ symbol: String, _ title: String?, lit: Bool = false) -> some View {
        HStack(spacing: 5) {
            Icon(symbol, size: 11, weight: .semibold)
            if let title { Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1) }
        }
        .foregroundStyle(lit ? Color.black : .white.opacity(0.8))
        .padding(.horizontal, title == nil ? 0 : 10)
        .frame(minWidth: 28)
        .frame(height: 28)
        .background(lit ? Color.white : .white.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
    }

    private func message(_ title: String, _ detail: String, action: (title: String, perform: () -> Void)? = nil) -> some View {
        VStack(spacing: 4) {
            Icon("video.slash.fill", size: 20).foregroundStyle(.white.opacity(0.5))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            if let action {
                Button(action: action.perform) {
                    Text(action.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(20)
    }
}

/// The capture session behind the mirror.
@MainActor @Observable
final class MirrorCamera {
    enum State: Equatable { case starting, running, denied, unavailable }

    private(set) var state: State = .starting
    private(set) var devices: [AVCaptureDevice] = []
    private(set) var current: AVCaptureDevice?
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "cue.mirror")

    func start() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { state = .denied; return }
            guard let device = current ?? AVCaptureDevice.default(for: .video) ?? devices.first else { state = .unavailable; return }
            use(device)
        }
    }

    func use(_ device: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: device) else { state = .unavailable; return }
        current = device
        let session = session
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            session.inputs.forEach(session.removeInput)
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            Task { @MainActor in self.state = running ? .running : .unavailable }
        }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

/// The live picture, mirrored as a mirror is.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The connection exists once an input is in: mirror it then.
        if let connection = (view.layer as? AVCaptureVideoPreviewLayer)?.connection, connection.isVideoMirroringSupported, !connection.isVideoMirrored {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
