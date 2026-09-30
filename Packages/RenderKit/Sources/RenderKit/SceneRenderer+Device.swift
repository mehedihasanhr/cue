import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// A phone or a tablet round the picture, drawn from rounded rectangles.
extension SceneRenderer {
    /// The picture cut to the device's screen.
    ///
    /// The screen's rounded corners, not the frame's own corner setting: the screen is the
    /// only edge a picture on a device has. A picture the screen's shape fills it and is
    /// rounded exactly as the glass is; one of another shape sits in the middle with black
    /// either side of it, and only the corners that reach the glass's are cut.
    func deviceScreenPicture(_ image: CIImage, device: DeviceGeometry) -> CIImage {
        let mask = Self.roundedRectangle(device.screen, radius: device.screenRadius, color: .white)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
        return blend.outputImage ?? image
    }

    /// The handset laid round the picture layer: rim, glass and dark screen under the
    /// picture, and a phone's camera pill over it.
    ///
    /// The result is one layer, like the picture with a window's bar on it, so everything
    /// after — the fade of a camera layout, the shadow, the perspective — takes the device
    /// and the picture together.
    func deviced(_ video: CIImage, in scene: SceneDescriptor) -> CIImage {
        guard let layer = scene.device, let device = scene.deviceGeometry,
              device.body.width > 2, device.body.height > 2 else { return video }
        let palette = DevicePalette(layer.finish)
        let output = CGRect(origin: .zero, size: scene.outputSize)

        // The metal rim, then the black glass inset inside it by the rim's width, then the
        // screen: three concentric rounded rectangles, so the bezel is even all round.
        var image = Self.roundedRectangle(device.body, radius: device.bodyRadius, color: palette.rim)
        // A hairline of light along the rim's inner edge, the way polished metal catches it
        // — a touch that stops a black finish reading as a black hole.
        let glint = max(0.5, device.rim * 0.25)
        let inner = device.body.insetBy(dx: device.rim - glint, dy: device.rim - glint)
        image = Self.roundedRectangle(inner, radius: max(0, device.bodyRadius - device.rim + glint),
                                      color: palette.glint)
            .composited(over: image)
        let glass = device.body.insetBy(dx: device.rim, dy: device.rim)
        image = Self.roundedRectangle(glass, radius: max(0, device.bodyRadius - device.rim), color: palette.glass)
            .composited(over: image)
        // The screen showing nothing, which is what a letterboxed picture's gaps are.
        image = Self.roundedRectangle(device.screen, radius: device.screenRadius, color: palette.screen)
            .composited(over: image)
        image = video.composited(over: image)

        if let camera = device.camera, camera.width > 0.5, camera.height > 0.5 {
            let radius = min(camera.width, camera.height) / 2
            if device.cameraIsInScreen {
                // The pill is part of the screen, and over the picture: that is where it is on
                // a real phone, and what makes a picture on one read as a phone.
                image = Self.roundedRectangle(camera, radius: radius, color: palette.screen)
                    .composited(over: image)
            } else {
                // A lens: a dark ring with a faint blue glint in it, on the glass.
                image = Self.roundedRectangle(camera, radius: radius, color: palette.lens)
                    .composited(over: image)
                let glassy = camera.insetBy(dx: camera.width * 0.3, dy: camera.height * 0.3)
                image = Self.roundedRectangle(glassy, radius: min(glassy.width, glassy.height) / 2,
                                              color: palette.lensGlint)
                    .composited(over: image)
            }
        }
        return image.cropped(to: output)
    }
}

/// The colours of a handset. The glass and the screen are black whatever the finish, as
/// they are on the real things; only the rim takes the colour.
struct DevicePalette {
    let rim: CIColor
    let glint: CIColor
    let glass: CIColor
    let screen: CIColor
    let lens: CIColor
    let lensGlint: CIColor

    init(_ finish: WindowChrome.Finish) {
        switch finish {
        case .black:
            rim = CIColor(red: 0.2, green: 0.2, blue: 0.21)
            glint = CIColor(red: 0.36, green: 0.36, blue: 0.38)
        case .silver:
            rim = CIColor(red: 0.84, green: 0.85, blue: 0.86)
            glint = CIColor(red: 0.95, green: 0.95, blue: 0.96)
        case .natural:
            rim = CIColor(red: 0.72, green: 0.69, blue: 0.64)
            glint = CIColor(red: 0.85, green: 0.82, blue: 0.77)
        }
        glass = CIColor(red: 0.03, green: 0.03, blue: 0.035)
        screen = CIColor(red: 0, green: 0, blue: 0)
        lens = CIColor(red: 0.1, green: 0.1, blue: 0.12)
        lensGlint = CIColor(red: 0.16, green: 0.2, blue: 0.3)
    }
}
