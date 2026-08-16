import Foundation

/// One reversible thing that happened on disk.
///
/// Every file operation decomposes into these two primitives, which is what
/// makes undo and redo the same machinery: inverting a step both performs the
/// reversal and yields the step that would undo *that*, so redo is just undo
/// applied to the inverse.
enum UndoStep {
    /// Something changed location or name.
    case moved(from: URL, to: URL)
    /// Something new appeared and did not exist before.
    case created(URL)
    /// Something went to the Trash; `inTrash` is where it landed.
    case trashed(original: URL, inTrash: URL)
}

/// A user-visible operation, named the way Explorer names it in "撤销 移动".
struct FileTransaction {
    var label: String
    var steps: [UndoStep]
}

/// Undo/redo history for file operations.
///
/// Permanent deletes are deliberately never recorded: there is nothing to put
/// back, and offering "撤销 删除" for something unrecoverable would be worse
/// than offering nothing.
final class UndoStack {

    private(set) var undoable: [FileTransaction] = []
    private(set) var redoable: [FileTransaction] = []

    /// Explorer keeps a shallow history; this is deep enough to cover real use
    /// without holding references to Trash items forever.
    private let limit = 25

    var canUndo: Bool { !undoable.isEmpty }
    var canRedo: Bool { !redoable.isEmpty }

    /// "撤销 移动" — Windows puts the verb in the menu label.
    var undoLabel: String? { undoable.last.map { "撤销 \($0.label)" } }
    var redoLabel: String? { redoable.last.map { "恢复 \($0.label)" } }

    func record(_ transaction: FileTransaction) {
        guard !transaction.steps.isEmpty else { return }
        undoable.append(transaction)
        if undoable.count > limit { undoable.removeFirst() }
        // Any fresh action invalidates the redo branch, as everywhere else.
        redoable.removeAll()
    }

    func clear() {
        undoable.removeAll()
        redoable.removeAll()
    }

    enum Failure: Error {
        case nothingToUndo
        case partial(String)
    }

    func undo() throws {
        guard let transaction = undoable.popLast() else { throw Failure.nothingToUndo }
        let inverse = try invert(transaction)
        redoable.append(inverse)
        if redoable.count > limit { redoable.removeFirst() }
    }

    func redo() throws {
        guard let transaction = redoable.popLast() else { throw Failure.nothingToUndo }
        let inverse = try invert(transaction)
        undoable.append(inverse)
        if undoable.count > limit { undoable.removeFirst() }
    }

    /// Applies the reverse of every step, last first, and returns the
    /// transaction that would reverse *this* reversal.
    private func invert(_ transaction: FileTransaction) throws -> FileTransaction {
        let manager = FileManager.default
        var produced: [UndoStep] = []
        var problems: [String] = []

        for step in transaction.steps.reversed() {
            do {
                switch step {
                case let .moved(from, to):
                    try manager.moveItem(at: to, to: from)
                    produced.append(.moved(from: to, to: from))

                case let .created(url):
                    var landed: NSURL?
                    try manager.trashItem(at: url, resultingItemURL: &landed)
                    guard let inTrash = landed as URL? else {
                        problems.append(url.lastPathComponent)
                        continue
                    }
                    produced.append(.trashed(original: url, inTrash: inTrash))

                case let .trashed(original, inTrash):
                    try manager.moveItem(at: inTrash, to: original)
                    // Undoing the restore means trashing it again, which is
                    // exactly what inverting `created` does.
                    produced.append(.created(original))
                }
            } catch {
                problems.append("\(stepName(step))：\(error.localizedDescription)")
            }
        }

        if !problems.isEmpty, produced.isEmpty {
            throw Failure.partial(problems.joined(separator: "\n"))
        }
        return FileTransaction(label: transaction.label, steps: produced.reversed())
    }

    private func stepName(_ step: UndoStep) -> String {
        switch step {
        case let .moved(_, to): return to.lastPathComponent
        case let .created(url): return url.lastPathComponent
        case let .trashed(original, _): return original.lastPathComponent
        }
    }
}
