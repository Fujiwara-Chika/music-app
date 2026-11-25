import AppKit
import SwiftUI

/// The song table hosted in a real AppKit `NSTableView`.
///
/// Rows are recycled the way AppKit expects (one hosting view per visible row,
/// updated in place) instead of being created and destroyed as the SwiftUI list
/// scrolls. Everything else — header, empty state, row drawing — stays in SwiftUI
/// and is shared with the `ScrollView` implementation.
struct SongTableAppKit: NSViewRepresentable {
    let rows: [TableRow]
    let columns: SongTableColumns
    let rowHeight: CGFloat
    let albumHeight: CGFloat
    let palette: Palette

    /// Row id to bring into view. Passed in as a value so SwiftUI re-runs
    /// `updateNSView` when the "locate playing" request changes.
    let scrollTarget: String?

    /// Bumped by `LibraryStore` whenever the derived rows are rebuilt. Row count
    /// and first/last ids are not enough: a re-sort keeps both while every row in
    /// between moves.
    let derivedRebuilds: Int
    /// Request counter from `LibraryStore.reveal`; the row id alone cannot tell a
    /// repeat request apart from an already-handled one.
    let revealToken: Int

    let store: LibraryStore
    let actions: SongTableActions
    let cursor: PlaybackCursor
    let clock: ProgressClock
    let ticker: ArtworkTicker

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        // Rows paint their own selection, so AppKit must not.
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .automatic
        scroll.contentInsets = NSEdgeInsets()

        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: SongTableAppKit
        weak var table: NSTableView?

        /// Cheap signature of "what is on screen", so a palette or selection change
        /// does not reload the whole table.
        private var layoutSignature = ""

        init(_ parent: SongTableAppKit) {
            self.parent = parent
        }

        func apply(_ next: SongTableAppKit) {
            parent = next
            guard let table else { return }
            table.rowHeight = next.rowHeight

            let signature = "\(next.derivedRebuilds)|\(next.rows.count)|\(next.rows.first?.id ?? "")|\(next.rows.last?.id ?? "")|\(next.rowHeight)|\(next.albumHeight)|\(Int(next.columns.check + next.columns.status))"
            let needsReload = signature != layoutSignature
            layoutSignature = signature
            if needsReload {
                let scrollY = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
                table.reloadData()
                table.enclosingScrollView?.contentView.scroll(to: scrollY)
            } else if let visible = table.rows(in: table.visibleRect) as NSRange?, visible.length > 0 {
                // Selection, playback state and artwork arrive here: refresh the
                // visible rows only.
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                 columnIndexes: IndexSet(integer: 0))
            }
            revealTargetIfNeeded()
        }

        private var lastRevealedToken = -1
        private func revealTargetIfNeeded() {
            guard let table, let target = parent.scrollTarget,
                  parent.revealToken != lastRevealedToken else { return }
            guard let index = parent.rows.firstIndex(where: { $0.id == target }) else { return }
            lastRevealedToken = parent.revealToken
            // `scrollRowToVisible` silently does nothing here (view-based rows,
            // custom heights), so scroll the clip view explicitly.
            table.layoutSubtreeIfNeeded()
            if let scroll = table.enclosingScrollView {
                let rect = table.rect(ofRow: index)
                let target = NSPoint(x: 0, y: max(0, rect.minY - 120))
                scroll.contentView.scroll(to: target)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                table.scrollRowToVisible(index)
            }
            parent.store.scrollTarget = nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch parent.rows[row] {
            case .album: return parent.albumHeight
            case .track: return parent.rowHeight
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? RowHostCell
                ?? RowHostCell.make(identifier: identifier)
            let tableRow = parent.rows[row]
            cell.configure {
                let p = self.parent
                return AnyView(
                    SongTableRowView(row: tableRow, columns: p.columns, actions: p.actions)
                        .environmentObject(p.store)
                        .environmentObject(p.clock)
                        .environmentObject(p.cursor)
                        .environmentObject(p.ticker)
                        .environment(\.palette, p.palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                )
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .track(let track, _) = parent.rows[row] {
                parent.store.selectedTrackID = track.id
            }
            return false   // selection is drawn by the row, not by AppKit
        }
    }
}

/// One recycled row: an `NSHostingView` whose SwiftUI root is swapped in place.
final class RowHostCell: NSTableCellView {
    private var host: NSHostingView<AnyView>?

    static func make(identifier: NSUserInterfaceItemIdentifier) -> RowHostCell {
        let cell = RowHostCell()
        cell.identifier = identifier
        return cell
    }

    func configure(_ root: () -> AnyView) {
        let view = root()
        if let host {
            host.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = bounds
            addSubview(hosting)
            host = hosting
        }
        host?.frame = bounds
    }
}
