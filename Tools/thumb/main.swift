import Foundation
import AppKit
import AVFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

// thumb — diagnose why a file shows (or does not show) a preview in the icon
// views. It prints the file's UTI classification, then what Quick Look returns
// and what AVFoundation can extract as a poster frame.
//
//   swiftc -O -swift-version 5 -framework AVFoundation -framework QuickLookThumbnailing \
//     Tools/thumb/main.swift -o build/everything-thumb
//   ./build/everything-thumb clip.mp4 photo.png document.pdf
//
// A video that reports `icon` from Quick Look but a real frame from AVFoundation
// is exactly the case the app's thumbnail pipeline special-cases.

func quickLookProbe(_ path: String) {
    let sem = DispatchSemaphore(value: 0)
    let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                               size: CGSize(width: 256, height: 256),
                                               scale: 1,
                                               representationTypes: [.thumbnail, .icon])
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
        if let representation = representation {
            let kind = representation.type == .thumbnail ? "thumbnail" : "icon"
            print("  QuickLook: \(kind) cg=\(representation.cgImage.width)x\(representation.cgImage.height)")
        } else {
            print("  QuickLook: FAILED \(error?.localizedDescription ?? "unknown")")
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
}

func videoFrameProbe(_ path: String, seconds: Double) {
    let sem = DispatchSemaphore(value: 0)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 512, height: 512)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    Task {
        do {
            let (image, actual) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            print("  AVFoundation: OK cg=\(image.width)x\(image.height) at=\(String(format: "%.2f", actual.seconds))s")
        } catch {
            print("  AVFoundation: FAILED \(error.localizedDescription)")
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    print("usage: everything-thumb <file> [file ...]")
    exit(2)
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    let type = UTType(filenameExtension: url.pathExtension)
    let isVideo = type?.conforms(to: .audiovisualContent) ?? false
    print("\(url.lastPathComponent)  uti=\(type?.identifier ?? "nil")  video=\(isVideo)")
    quickLookProbe(path)
    if isVideo { videoFrameProbe(path, seconds: 1.0) }
}
