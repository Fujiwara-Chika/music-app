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

    /// Everything the rows paint from, in one string. The parent view is rebuilt
    /// by far more than the rows care about — a volume drag publishes 60 times a
    /// second, and an appearance slider publishes on every pixel — so the table
    /// compares this instead of reloading on every SwiftUI update.
    let renderToken: String
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
        context.coordinator.observeScroll(in: scroll)
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

        /// Cheap signature of "what rows exist on screen", so a palette, selection
        /// or column-width change does not reload the whole table. Column widths
        /// travel in `renderToken` instead: they only need the visible rows
        /// repainted, and a full `reloadData` on every drag frame is what made
        /// resizing feel like it was fighting the pointer.
        private var layoutSignature = ""

        init(_ parent: SongTableAppKit) {
            self.parent = parent
        }

        func apply(_ next: SongTableAppKit) {
            parent = next
            guard let table else { return }
            table.rowHeight = next.rowHeight

            let signature = "\(next.derivedRebuilds)|\(next.rows.count)|\(next.rows.first?.id ?? "")|\(next.rows.last?.id ?? "")|\(next.rowHeight)|\(next.albumHeight)"
            let needsReload = signature != layoutSignature
            layoutSignature = signature
            if needsReload {
                let scrollY = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
                table.reloadData()
                table.enclosingScrollView?.contentView.scroll(to: scrollY)
                renderToken = next.renderToken
            } else if next.renderToken != renderToken,
                      let visible = table.rows(in: table.visibleRect) as NSRange?, visible.length > 0 {
                // Selection, playback state and artwork arrive here: refresh the
                // visible rows only.
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                 columnIndexes: IndexSet(integer: 0))
                renderToken = next.renderToken
            }
            restoreScrollIfNeeded()
            revealTargetIfNeeded()
        }

        // MARK: Scroll position across launches

        /// False while launch is still settling. The window's palette animation
        /// resizes the content for ~0.45 s, which clamps the restored offset; saves
        /// are held off until the position has been re-asserted at the end of it.
        private var restoreSettled = false
        private var restoreTargetY: CGFloat?
        private var restoreRetries = 0

        /// `NSClipView` posts this on every scroll — user flings, the wheel, and
        /// our own programmatic scrolls. Each one updates the debounced save.
        func observeScroll(in scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollDidChange),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        @objc private func scrollDidChange(_ note: Notification) {
            captureScroll()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private func captureScroll() {
            guard restoreSettled else { return }
            guard let table, let scroll = table.enclosingScrollView,
                  !parent.rows.isEmpty else { return }
            let originY = scroll.contentView.bounds.origin.y
            var index = table.row(at: NSPoint(x: 0, y: originY))
            if index < 0 { index = table.rows(in: table.visibleRect).location }
            guard index >= 0, index < parent.rows.count else { return }
            let rect = table.rect(ofRow: index)
            parent.store.noteTableScroll(rowID: parent.rows[index].id,
                                         offsetInRow: Double(max(0, originY - rect.minY)))
        }

        /// Restores the position saved on the last quit. Applied as soon as the
        /// table is laid out, then re-asserted once the launch animation settles so
        /// a transient viewport resize cannot leave it near the top.
        private func restoreScrollIfNeeded() {
            guard !restoreSettled, !parent.rows.isEmpty, let table else { return }
            guard table.bounds.height > 1, table.numberOfRows > 0 else {
                if restoreRetries < 30 {
                    restoreRetries += 1
                    DispatchQueue.main.async { [weak self] in self?.restoreScrollIfNeeded() }
                }
                return
            }
            if restoreTargetY == nil {
                guard let snapshot = parent.store.consumeScrollRestore(),
                      let index = parent.rows.firstIndex(where: { $0.id == snapshot.rowID }) else {
                    restoreSettled = true
                    return
                }
                table.layoutSubtreeIfNeeded()
                let rect = table.rect(ofRow: index)
                restoreTargetY = max(0, rect.minY + CGFloat(snapshot.offsetInRow))
                // Re-assert at the end of `RootView`'s 0.45 s palette animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.applyRestoreTarget()
                    self.restoreSettled = true
                }
            }
            applyRestoreTarget()
        }

        private func applyRestoreTarget() {
            guard let y = restoreTargetY, let table,
                  let scroll = table.enclosingScrollView else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private var renderToken = ""
        private var lastRevealedToken = -1
        private func revealTargetIfNeeded() {
            guard let table, let target = parent.scrollTarget,
                  parent.revealToken != lastRevealedToken else { return }
            guard let index = parent.rows.firstIndex(where: { $0.id == target }) else { return }
            lastRevealedToken = parent.revealToken
            // A deliberate reveal (play, "locate playing") outranks the launch restore.
            restoreTargetY = nil
            restoreSettled = true
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
