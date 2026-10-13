import Foundation

/// The index arithmetic behind drag-to-reorder, kept free of SwiftUI and AppKit so it can be
/// tested directly — the drag itself can only be checked by hand.
enum Reordering {
    /// Drops the element at `source` onto the element at `target`, the way a list reorder reads:
    /// dragging downwards lands below the target, dragging upwards lands above it.
    static func move<Element>(_ elements: [Element], from source: Int, onto target: Int) -> [Element] {
        guard elements.indices.contains(source),
              elements.indices.contains(target),
              source != target else { return elements }

        var result = elements
        let moving = result.remove(at: source)
        // `target` is the right insertion point either way. Dragging down, removal shifts the
        // target one place earlier and we want to land after it; dragging up, the target keeps
        // its index and we want to land before it.
        result.insert(moving, at: target)
        return result
    }

    /// One step up (-1) or down (+1), used by the Move Up / Move Down commands.
    static func shift<Element>(_ elements: [Element], at index: Int, by offset: Int) -> [Element] {
        let destination = index + offset
        guard elements.indices.contains(index), elements.indices.contains(destination) else { return elements }

        var result = elements
        result.swapAt(index, destination)
        return result
    }
}
