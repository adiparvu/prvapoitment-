import CoreTransferable
import Foundation
import PRVModels
import UniformTypeIdentifiers

/// Persists media picked from the photo library into the app's caches
/// directory so an outgoing `ChatMessage` can reference a stable file URL
/// while the transport layer uploads it.
///
/// Attachments are grouped per conversation, so a conversation's local media
/// can be evicted in one step when the client clears it.
enum ChatAttachmentStore {
    /// Directory holding one conversation's outgoing attachments, created on
    /// demand.
    static func directory(for conversationID: Conversation.ID) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches
            .appending(path: "PRVChatAttachments", directoryHint: .isDirectory)
            .appending(path: conversationID.description, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes in-memory data (a picked photo) as a new attachment.
    /// - Returns: The file URL to reference from the outgoing message.
    static func store(
        _ data: Data,
        fileExtension: String,
        in conversationID: Conversation.ID
    ) throws -> URL {
        let directory = try directory(for: conversationID)
        let url = directory.appending(path: "\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Moves an already-materialized file (a picked movie) into the store.
    /// - Returns: The file URL to reference from the outgoing message.
    static func adopt(_ source: URL, in conversationID: Conversation.ID) throws -> URL {
        let directory = try directory(for: conversationID)
        let fileExtension = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = directory.appending(path: "\(UUID().uuidString).\(fileExtension)")
        if FileManager.default.fileExists(atPath: destination.path()) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try? FileManager.default.removeItem(at: source)
        return destination
    }

    /// Removes every locally cached attachment for a conversation.
    static func clear(_ conversationID: Conversation.ID) {
        guard let directory = try? directory(for: conversationID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A movie picked from the photo library, materialized as a local file.
///
/// `PhotosPickerItem` hands movies over as files rather than in-memory data,
/// so loading one needs a `FileRepresentation` rather than `Data`.
struct PickedMovie: Transferable, Sendable {
    /// Location of the imported copy inside the temporary directory. Move it
    /// into ``ChatAttachmentStore`` before referencing it from a message.
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).\(fileExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}
