import CoreMedia
import Foundation

extension Commands {
    /// A movie brought into the project, put in whole at a moment — the playhead or the end.
    ///
    /// One step, so one ⌘Z takes away both the clip and the record of its file: a record
    /// left behind with no clip naming it would be harmless, but it would also be a file
    /// the project claims to use and does not. The file itself stays in the package, which
    /// is what lets a redo — or a paste of the clip copied before the undo — find it.
    ///
    /// The clip goes in the way a paste does, so it lands at a cut (opening one at the
    /// moment if it can), what comes after it moves along, and a region spanning the moment
    /// stretches over it. See `ClipSequence.insert`.
    public struct AddMedia: TimelineCommand {
        public let file: MediaFile
        public let clip: Clip
        public let time: CMTime
        public var name: String { file.kind == .recording ? "Add Recording" : "Add Video" }

        /// - Parameter id: the new clip's identity, chosen by the caller so it can select
        ///   what it has just added.
        public init(_ file: MediaFile, at time: CMTime, id: UUID = UUID()) {
            self.file = file
            self.clip = Clip(id: id, sourceStart: .zero, sourceDuration: file.duration, source: file.path)
            self.time = time
        }

        public func apply(to timeline: inout Timeline) -> Bool {
            guard !file.path.isEmpty, file.duration >= Clip.minimumDuration else { return false }
            return ClipSequence.insert(&timeline,
                                       CopiedFootage(clips: [clip], sourceDuration: timeline.sourceDuration,
                                                     media: [file]),
                                       at: time)
        }
    }
}
