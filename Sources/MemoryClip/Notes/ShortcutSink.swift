import Foundation

/// Hands the note to a Shortcut, which can put it anywhere.
///
/// The escape hatch. MemoryClip will never integrate with Bear, Craft, Things,
/// Day One, a git repo or whatever the user is actually keeping their notes in
/// — a Shortcut can, and the user maintains it. The contract is deliberately
/// the simplest one Shortcuts offers: the note is written to a `.md` file and
/// passed as the shortcut's input, so the receiving Shortcut starts with
/// "Shortcut Input" and does whatever it likes.
///
/// The file is a real file rather than text on stdin because `shortcuts run`
/// takes input only as a path (`-i`), and because a file carries a name and a
/// type — a Shortcut that saves its input somewhere gets a sensibly named
/// Markdown document for free instead of an "Untitled" blob.
struct ShortcutSink: NoteSink {
    /// Where the Shortcuts CLI lives. Part of macOS since Monterey; checked
    /// anyway, because "the command is missing" and "the shortcut is broken"
    /// are different sentences for the user.
    static let toolPath = "/usr/bin/shortcuts"

    /// How long a Shortcut gets before it is killed.
    ///
    /// A Shortcut is arbitrary user-authored automation: one that shows a
    /// "Choose from Menu" or "Ask for Input" action blocks until somebody
    /// answers it, and `shortcuts run` waits forever. Without this, a single
    /// badly written Shortcut wedges the export pipeline for the rest of the
    /// session — and the user's next capture, and the one after that. Thirty
    /// seconds is generous for anything doing real work and short enough that a
    /// stuck one is noticed rather than endured.
    static let timeout: Duration = .seconds(30)

    let shortcutName: String

    init(shortcutName: String) {
        self.shortcutName = shortcutName
    }

    // MARK: - NoteSink

    func write(_ draft: NoteDraft) async throws -> NoteReceipt {
        guard draft.hasContent else { throw NoteError.nothingToWrite }
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NoteError.noDestinationConfigured(.shortcut) }
        guard FileManager.default.isExecutableFile(atPath: Self.toolPath) else {
            throw NoteError.shortcutFailed(
                "The shortcuts command-line tool is not available at \(Self.toolPath)."
            )
        }

        let inputFile = try Self.writeTemporaryNote(for: draft)
        // The temp file is deleted only here, at the end of the whole function
        // — after every `await` below has returned and therefore after the
        // process has exited. Deleting it any earlier pulls the file out from
        // under a Shortcut that is still reading its own input, which fails in
        // a way that looks like the Shortcut's bug rather than ours.
        defer { try? FileManager.default.removeItem(at: inputFile.deletingLastPathComponent()) }

        let result = try await Self.run(
            arguments: ["run", name, "-i", inputFile.path(percentEncoded: false)],
            timeout: Self.timeout
        )

        if Task.isCancelled {
            // The child was killed by this task's own cancellation handler, so
            // its SIGTERM exit status is our doing. Reporting it as a non-zero
            // exit would blame the user's Shortcut for something the app did.
            throw NoteError.shortcutFailed("The note export was cancelled.")
        }
        if result.timedOut {
            throw NoteError.shortcutFailed(
                "“\(name)” did not finish within \(Self.timeout.components.seconds) seconds and was stopped. "
                    + "A Shortcut that asks for input cannot be run this way."
            )
        }
        guard result.terminationStatus == 0 else {
            // The tool's own stderr is the only thing that says WHICH shortcut
            // step failed; a bare exit code sends the user to the Shortcuts app
            // with nothing to look for.
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NoteError.shortcutFailed(
                detail.isEmpty
                    ? "“\(name)” exited with status \(result.terminationStatus)."
                    : detail
            )
        }

        log.notice("Ran note Shortcut \(name, privacy: .private)")
        return NoteReceipt(location: "Shortcut “\(name)”", openURL: nil)
    }

    // MARK: - Input file

    /// Write the composed note to a fresh temp directory, returning the file.
    ///
    /// A directory per run, not just a file: the file name is
    /// `NoteComposer.fileNameStem` so a Shortcut that saves its input keeps a
    /// meaningful name, and two exports of clips with the same title would
    /// otherwise collide in a shared temp folder. Removing the directory at the
    /// end takes the file with it.
    private static func writeTemporaryNote(for draft: NoteDraft) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MemoryClip-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "\(NoteComposer.fileNameStem(for: draft)).md")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(NoteComposer.markdown(for: draft).utf8).write(to: file, options: .atomic)
        } catch {
            throw NoteError.writeFailed(error.localizedDescription)
        }
        return file
    }

    // MARK: - Running the tool

    /// What the subprocess did.
    struct Result: Sendable {
        var terminationStatus: Int32
        var standardError: String
        var timedOut: Bool
    }

    /// Run `shortcuts` with `arguments`, killing it after `timeout`.
    ///
    /// Never runs on the main actor: this function is `nonisolated`, so its
    /// `async` body executes on the cooperative pool no matter who called it,
    /// and the UI stays live for the whole 30 seconds a Shortcut might take.
    static func run(arguments: [String], timeout: Duration) async throws -> Result {
        let process = Process()
        process.executableURL = URL(filePath: toolPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        // stdout goes to the null device rather than a second Pipe nobody
        // drains: an undrained pipe fills at 64 KB and the child then blocks
        // forever on its next `write`, which is a hang caused entirely by us.
        process.standardOutput = FileHandle.nullDevice

        let box = ProcessBox(process)
        do {
            try process.run()
        } catch {
            throw NoteError.shortcutFailed("The shortcuts tool could not be started: \(error.localizedDescription)")
        }

        // Cancelling the export (the user quit, the pipeline was torn down)
        // has to reach the child too. Without this the task suspends on a
        // process nothing will ever terminate, and cancellation never lands.
        let timedOut = await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await box.waitForExit()
                    return false
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        // Cancelled because the process already exited — the
                        // normal path, and not a timeout.
                        return false
                    }
                    box.terminate()
                    return true
                }
                let first = await group.next() ?? false
                // Cancels the sleep when the process won the race. The other
                // task is always able to finish: either the sleep throws, or
                // the process has just been terminated and its handler fires.
                group.cancelAll()
                return first
            }
        } onCancel: {
            box.terminate()
        }

        // Read stderr AFTER the process has gone, which is safe for the single
        // short line `shortcuts` prints on failure. A tool that wrote more than
        // the 64 KB pipe buffer would stall instead of exiting — the timeout
        // above is the backstop for that, and we then report whatever made it
        // through.
        let errorData = ((try? errorPipe.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
        return Result(
            terminationStatus: box.terminationStatus,
            standardError: String(decoding: errorData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// A `Process` that can cross concurrency domains.
///
/// `Process` is not `Sendable`, but the timeout task and the cancellation
/// handler both have to reach the same one the awaiting task is watching. The
/// `@unchecked` is narrow and deliberate: only `terminate()`, `isRunning` and
/// `terminationStatus` are touched from another thread, all of which Foundation
/// guards internally, and the one piece of genuinely shared state added here —
/// the "already resumed" flag — is behind a lock.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var resumed = false

    init(_ process: Process) {
        self.process = process
    }

    var terminationStatus: Int32 {
        process.isRunning ? -1 : process.terminationStatus
    }

    /// Suspend until the process exits, without holding a thread.
    ///
    /// `waitUntilExit()` would be one line, but it blocks — on the cooperative
    /// pool that burns one of a small fixed number of threads for up to the
    /// full timeout, and enough concurrent exports would deadlock the pool
    /// outright. The termination handler gives the same answer for free.
    func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume: @Sendable () -> Void = { [self] in
                lock.lock()
                let isFirst = !resumed
                resumed = true
                lock.unlock()
                if isFirst { continuation.resume() }
            }
            process.terminationHandler = { _ in resume() }
            // The process can exit between `run()` and the handler being
            // installed, in which case the handler never fires and this would
            // suspend forever. The flag above makes the double-call harmless.
            if !process.isRunning { resume() }
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
