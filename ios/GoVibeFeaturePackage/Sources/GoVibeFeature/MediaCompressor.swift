import AVFoundation
import UIKit

enum MediaCompressor {

    static func compressImage(
        _ image: UIImage,
        maxDimension: CGFloat = 1200,
        quality: CGFloat = 0.7
    ) -> Data? {
        let size = image.size
        let largerSide = max(size.width, size.height)
        guard largerSide > 0 else { return nil }

        let scale = largerSide > maxDimension ? maxDimension / largerSide : 1.0
        let targetSize = CGSize(
            width: (size.width * scale).rounded(.down),
            height: (size.height * scale).rounded(.down)
        )

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    static func compressVideo(at sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetMediumQuality
        ) else {
            throw CompressionError.exportSessionCreationFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        return try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed:
                    continuation.resume(
                        throwing: session.error ?? CompressionError.exportFailed
                    )
                case .cancelled:
                    continuation.resume(throwing: CompressionError.exportCancelled)
                default:
                    continuation.resume(throwing: CompressionError.exportFailed)
                }
            }
        }
    }

    enum CompressionError: LocalizedError {
        case exportSessionCreationFailed
        case exportFailed
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case .exportSessionCreationFailed:
                "Could not create video export session."
            case .exportFailed:
                "Video compression failed."
            case .exportCancelled:
                "Video compression was cancelled."
            }
        }
    }
}
