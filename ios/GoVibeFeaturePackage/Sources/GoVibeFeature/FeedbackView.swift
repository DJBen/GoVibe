import FirebaseFirestore
import FirebaseStorage
import PhotosUI
import SwiftUI

struct FeedbackView: View {
    let sessionId: String
    let terminalText: String?
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var feedbackText = ""
    @State private var selectedMedia: [FeedbackMediaItem] = []
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var errorMessage: String?
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Info") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .disabled(true)
                        .foregroundStyle(.secondary)
                }
                Section("Feedback") {
                    TextEditor(text: $feedbackText)
                        .frame(height: 120)
                }
                Section {
                    if !selectedMedia.isEmpty {
                        mediaPreviewRow
                    }
                    if selectedMedia.count < 3 {
                        PhotosPicker(
                            selection: $selectedPhotos,
                            maxSelectionCount: 3 - selectedMedia.count,
                            matching: .any(of: [.images, .videos])
                        ) {
                            Label("Add Photo or Video", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                } header: {
                    Text("Attachments")
                } footer: {
                    Text("Up to 3 photos or videos. Media will be compressed before upload.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        GoVibeAnalytics.log("feedback_cancelled", parameters: ["session_id": sessionId])
                        onDismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Submit") {
                            Task { await submit() }
                        }
                        .bold()
                        .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onChange(of: selectedPhotos) { _, newItems in
                Task { await loadMedia(from: newItems) }
            }
            .task {
                let user = GoVibeAuthController.shared.currentUser
                email = user?.email ?? ""
                name = user?.displayName ?? ""
                GoVibeAnalytics.log("feedback_form_opened", parameters: ["session_id": sessionId])
            }
            .overlay {
                if showSuccess {
                    successBanner
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    // MARK: - Media Preview

    private var mediaPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(selectedMedia) { item in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = item.thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        if item.type == .video {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                        Button {
                            selectedMedia.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                    .frame(width: 72, height: 72)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Success Banner

    private var successBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Thank you for your feedback!")
                .font(.headline)
            Text("Our team will get back to you soon.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 32)
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            onDismiss()
        }
    }

    // MARK: - Load Media

    @MainActor
    private func loadMedia(from items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                let mediaItem = FeedbackMediaItem(
                    type: .image,
                    thumbnail: image,
                    imageData: data,
                    videoURL: nil
                )
                selectedMedia.append(mediaItem)
            } else if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                let thumbnail = await generateVideoThumbnail(url: movie.url)
                let mediaItem = FeedbackMediaItem(
                    type: .video,
                    thumbnail: thumbnail,
                    imageData: nil,
                    videoURL: movie.url
                )
                selectedMedia.append(mediaItem)
            }
        }
        selectedPhotos = []
    }

    private func generateVideoThumbnail(url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return try? await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: UIImage(cgImage: image))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Submit

    @MainActor
    private func submit() async {
        isSubmitting = true
        errorMessage = nil

        let feedbackId = UUID().uuidString
        let storageRef = Storage.storage().reference().child("feedback/\(feedbackId)")

        do {
            var terminalLogURL: String?
            var mediaURLs: [String] = []
            var mediaTypes: [String] = []

            // Upload terminal log
            if let text = terminalText, !text.isEmpty, let textData = text.data(using: .utf8) {
                let meta = StorageMetadata()
                meta.contentType = "text/plain"
                _ = try await storageRef.child("terminal.txt").putDataAsync(textData, metadata: meta)
                terminalLogURL = try await storageRef.child("terminal.txt").downloadURL().absoluteString
            }

            // Compress and upload media sequentially
            for (index, item) in selectedMedia.enumerated() {
                switch item.type {
                case .image:
                    guard let original = item.thumbnail,
                          let compressed = MediaCompressor.compressImage(original) else { continue }
                    let fileName = "\(index).jpg"
                    let meta = StorageMetadata()
                    meta.contentType = "image/jpeg"
                    _ = try await storageRef.child(fileName).putDataAsync(compressed, metadata: meta)
                    let url = try await storageRef.child(fileName).downloadURL().absoluteString
                    mediaURLs.append(url)
                    mediaTypes.append("image")

                case .video:
                    guard let sourceURL = item.videoURL else { continue }
                    let compressedURL = try await MediaCompressor.compressVideo(at: sourceURL)
                    let videoData = try Data(contentsOf: compressedURL)
                    let fileName = "\(index).mp4"
                    let meta = StorageMetadata()
                    meta.contentType = "video/mp4"
                    _ = try await storageRef.child(fileName).putDataAsync(videoData, metadata: meta)
                    let url = try await storageRef.child(fileName).downloadURL().absoluteString
                    mediaURLs.append(url)
                    mediaTypes.append("video")
                    try? FileManager.default.removeItem(at: compressedURL)
                }
            }

            // Write Firestore document
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            var docData: [String: Any] = [
                "feedbackId": feedbackId,
                "sessionId": sessionId,
                "userId": GoVibeAuthController.shared.currentUser?.uid ?? "",
                "name": name,
                "email": email,
                "text": feedbackText,
                "mediaURLs": mediaURLs,
                "mediaTypes": mediaTypes,
                "appVersion": appVersion,
                "platform": "ios",
                "createdAt": FieldValue.serverTimestamp(),
                "status": "new",
            ]
            if let terminalLogURL {
                docData["terminalLogURL"] = terminalLogURL
            }

            try await Firestore.firestore().collection("feedback").document(feedbackId).setData(docData)

            GoVibeAnalytics.log("feedback_submitted", parameters: [
                "session_id": sessionId,
                "media_count": selectedMedia.count,
            ])
            showSuccess = true

        } catch {
            errorMessage = "Failed to submit feedback. Please check your connection and try again."
            isSubmitting = false
            GoVibeAnalytics.log("feedback_submit_failed", parameters: [
                "session_id": sessionId,
                "error": error.localizedDescription,
            ])
        }
    }
}

// MARK: - Supporting Types

struct FeedbackMediaItem: Identifiable {
    let id = UUID()
    let type: MediaType
    let thumbnail: UIImage?
    let imageData: Data?
    let videoURL: URL?

    enum MediaType {
        case image
        case video
    }
}

struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return Self(url: tempURL)
        }
    }
}
