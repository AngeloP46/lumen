import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All photos", picks = "Picks", rated = "Rated", rejects = "Rejected"
    var id: String { rawValue }

    func matches(_ i: LibraryItem) -> Bool {
        switch self {
        case .all: return i.flag != -1
        case .picks: return i.flag == 1
        case .rated: return i.rating > 0
        case .rejects: return i.flag == -1
        }
    }
}

/// One day's photos in the grid.
private struct DaySection: Identifiable {
    let day: Date
    var items: [LibraryItem]
    var id: Date { day }
}

/// Library sort order: by the date the photo was taken (EXIF; import date when the file has none) or by import date.
private enum LibrarySort: String, CaseIterable, Identifiable {
    case taken = "Date taken", added = "Import date"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var filter: LibraryFilter = .all
    @AppStorage("librarySort") private var sortRaw = LibrarySort.taken.rawValue
    @State private var path: [LibraryItem] = []
    @State private var demoStarted = false   // CI demo mode: open the photo once, not every time the library reappears

    // selection mode: delete, paste edits onto, or export many photos at once
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    /// Long-press → Remove asks first too (it removed the photo at once before 22 Oct: checklist A3).
    @State private var confirmRemove: LibraryItem?
    @State private var showBatchExport = false
    @State private var showDiagnostics = false
    @State private var notice: String?
    /// Pasting edits that include AI Denoise asks first (it needs a clean of each photo).
    @State private var denoisePaste: [LibraryItem]?
    /// The photo Copy edits… is choosing from (shows the Copy edits sheet).
    @State private var copyFrom: LibraryItem?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    /// CI demo mode sorts by import date (the order the tests expect) unless `-lumenDemoSort taken` is given.
    private var sort: LibrarySort {
        if DemoMode.isOn { return DemoMode.value("-lumenDemoSort") == "taken" ? .taken : .added }
        return LibrarySort(rawValue: sortRaw) ?? .taken
    }

    private func date(_ i: LibraryItem) -> Date { sort == .added ? i.added : (i.taken ?? i.added) }

    private var visible: [LibraryItem] {
        store.items.filter { filter.matches($0) }.sorted { date($0) > date($1) }
    }

    /// One section per day, newest first.
    private var sections: [DaySection] {
        let cal = Calendar.current
        var out: [DaySection] = []
        for it in visible {
            let d = cal.startOfDay(for: date(it))
            if let last = out.last, last.day == d { out[out.count - 1].items.append(it) } else { out.append(DaySection(day: d, items: [it])) }
        }
        return out
    }

    private var selectedItems: [LibraryItem] { visible.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 14) {
                        ContentUnavailableView("No photos yet",
                                               systemImage: "photo.on.rectangle.angled",
                                               description: Text("Import RAW / ProRAW from your Photos library, or ARW files from Files or an SD card."))
                        Button { showPhotoPicker = true } label: {
                            Label("Import from Photos", systemImage: "photo").frame(maxWidth: 260)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { showFileImporter = true } label: {
                            Label("Import from Files / SD card", systemImage: "folder").frame(maxWidth: 260)
                        }
                        .buttonStyle(.bordered)
                    }
                } else if visible.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("No photos match “\(filter.rawValue)”."))
                } else {
                    grid
                }
            }
            .navigationTitle(selecting ? (selection.isEmpty ? "Select photos" : "\(selection.count) selected")
                                       : (filter == .all ? "Lumen" : filter.rawValue))
            .navigationBarTitleDisplayMode(selecting ? .inline : .automatic)
            .navigationDestination(for: LibraryItem.self) { EditorView(item: $0).id($0.id) }
            .task {
                guard let dir = DemoMode.value("-lumenDemoDir"), !demoStarted else { return }
                demoStarted = true
                let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
                if store.items.count != urls.count {
                    // always exactly the sample photos, in the same order (a delete test must not change later tests)
                    store.delete(store.items)
                    store.importFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                if DemoMode.value("-lumenDemoBroken") != nil {   // CI: a file that is not a photo
                    let bad = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-photo.jpg")
                    try? Data("this is not a photo".utf8).write(to: bad)
                    store.importFiles([bad])
                }
                if DemoMode.value("-lumenDemoFresh") != nil {
                    // -lumenDemoRawHDR: no saved edits at all, like a photo never opened
                    for it in store.items {
                        // the undo history goes too: the demo library lives on between launches, and a test that opened a photo
                        // after another test's edits found Undo already enabled (found 23 Oct, tests run in a different order)
                        store.forgetEdits(it)
                        if DemoMode.value("-lumenDemoRawHDR") == nil { store.save(EditSettings(), for: it) }
                    }
                    store.clipboard = nil
                }
                store.runPersistenceChecksIfRequested()
                if let n = DemoMode.value("-lumenDemoOpen"), let i = Int(n), store.items.indices.contains(i) {
                    path = [store.items[i]]
                }
            }
            .toolbar { toolbar }
            // The picker must live outside the Menu: inside it, the picker is torn down as the menu closes.
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 50,
                          matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .overlay { progressOverlay }
            .overlay(alignment: .bottom) { denoiseBanner }
            .onAppear { store.refreshPausedCleans() }
            .sheet(item: $copyFrom) { item in
                CopyEditsSheet(settings: store.editorSettings(for: item), sourceName: item.displayName, sourceID: item.id) { clip in
                    store.clipboard = clip
                    show("Copied \(clip.summary). Select photos and tap Paste.")
                }
            }
            .confirmationDialog("Paste AI Denoise too?", isPresented: Binding(get: { denoisePaste != nil }, set: { if !$0 { denoisePaste = nil } }),
                                titleVisibility: .visible) {
                if let list = denoisePaste, let clip = store.clipboard {
                    let n = min(list.count, LibraryStore.denoiseBatchCap)
                    Button("Paste and clean \(n == 1 ? "it" : "\(n) photos") (\(denoiseMinutes(n)))") {
                        store.paste(clip, to: list)
                        store.cleanWithAIDenoise(list, strength: clip.settings.aiDenoise)
                        denoisePaste = nil
                    }
                    Button("Paste without AI Denoise") {
                        store.paste(clip, to: list)
                        show("Pasted onto \(list.count) photo\(list.count == 1 ? "" : "s"), without AI Denoise.")
                        denoisePaste = nil
                    }
                    Button("Cancel", role: .cancel) { denoisePaste = nil }
                }
            } message: {
                if let list = denoisePaste {
                    let n = min(list.count, LibraryStore.denoiseBatchCap)
                    Text("AI Denoise cleans each photo on its own: \(denoiseMinutes(n)). "
                         + (list.count > LibraryStore.denoiseBatchCap ? "At most \(LibraryStore.denoiseBatchCap) photos at a time: the first \(n) of the \(list.count) selected get it. " : "")
                         + "Progress shows here; leaving Lumen pauses it and it carries on when you're back.")
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, selecting ? 80 : 24)
                        .accessibilityIdentifier("library-notice")
                        .transition(.opacity)
                }
            }
            .onChange(of: pickerItems) { _, new in
                guard !new.isEmpty else { return }
                Task {
                    await store.importPicked(new)
                    pickerItems = []
                }
            }
            .onChange(of: visible.map(\.id), initial: true) { _, ids in
                store.browseOrder = ids
                selection.formIntersection(Set(ids))
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.rawImage, .image],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { store.importFiles(urls) }
            }
            .confirmationDialog("Remove \(selection.count) photo\(selection.count == 1 ? "" : "s") from Lumen?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove \(selection.count) photo\(selection.count == 1 ? "" : "s")", role: .destructive) {
                    store.delete(selectedItems)
                    selection = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their edits are removed too. The originals in Photos or Files are not touched.")
            }
            .confirmationDialog("Remove this photo from Lumen?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                                titleVisibility: .visible) {
                if let item = confirmRemove {
                    Button("Remove photo", role: .destructive) { store.delete(item); confirmRemove = nil }
                        .accessibilityIdentifier("confirm-remove")
                }
                Button("Cancel", role: .cancel) { confirmRemove = nil }
            } message: {
                Text("Its edits are removed too. The original in Photos or Files is not touched.")
            }
            .overlay(alignment: .top) { SaveProblemBanner() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsSheet() }
            .sheet(isPresented: $showBatchExport) {
                let list = selectedItems
                ExportOptionsSheet(count: list.count, hdrAvailable: list.contains { store.editorSettings(for: $0).hdr }) { o in
                    store.export(list, options: o)
                }
            }
            .sheet(item: $store.batchResult) { result in
                BatchExportSheet(urls: result.urls) { show(await store.saveToPhotos(result.urls)) }
            }
            .alert("Lumen", isPresented: Binding(get: { store.lastError != nil },
                                                 set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.lastError ?? "") }
        }
        // on the stack itself (not its root view) so the editors it pushes can reach it
        .environment(\.openItem, { item in path = [item] })
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { sec in
                    Section {
                        ForEach(sec.items) { item in cell(item) }
                    } header: {
                        HStack {
                            Text(sec.day, format: .dateTime.weekday(.abbreviated).day().month(.wide).year())
                                .font(.subheadline.weight(.semibold))
                            Text("\(sec.items.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if selecting {
                                let ids = Set(sec.items.map(\.id))
                                Button(ids.isSubset(of: selection) ? "Deselect" : "Select") {
                                    if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.bar)
                        .accessibilityIdentifier("library-section")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: LibraryItem) -> some View {
        if selecting {
            let on = selection.contains(item.id)
            Button {
                if on { selection.remove(item.id) } else { selection.insert(item.id) }
            } label: {
                ThumbnailView(item: item)
                    .overlay { if on { Color.black.opacity(0.28) } }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, on ? Theme.accent : Color.black.opacity(0.25))
                            .shadow(radius: 2).padding(5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-item")
            .accessibilityValue(on ? "selected" : "not selected")
        } else {
            NavigationLink(value: item) { ThumbnailView(item: item) }
                .accessibilityIdentifier("library-item")
                .contextMenu {
                    Button { copyFrom = item } label: {
                        Label("Copy edits…", systemImage: "doc.on.doc")
                    }
                    if let clip = store.clipboard {
                        Button { paste(clip, to: [item]) } label: {
                            Label { Text("Paste edits"); Text(clip.summary) } icon: { Image(systemName: "doc.on.clipboard") }
                        }
                    }
                    Button { selecting = true; selection = [item.id] } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) { confirmRemove = item } label: {
                        Label("Remove from Lumen", systemImage: "trash")
                    }
                }
        }
    }

    // MARK: Toolbar and selection bar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Sort by", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { Label($0.rawValue, systemImage: $0 == .taken ? "camera" : "square.and.arrow.down").tag($0.rawValue) }
                }
                Divider()
                Button { showDiagnostics = true } label: { Label("Send diagnostics…", systemImage: "stethoscope") }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            .accessibilityIdentifier("btn-library-filter")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selecting {
                Button("Done") { selecting = false; selection = [] }.bold().accessibilityIdentifier("btn-select-done")
            } else {
                Button("Select") { selecting = true }.disabled(store.items.isEmpty).accessibilityIdentifier("btn-select")
                Menu {
                    Button { showPhotoPicker = true } label: {
                        Label("From Photos", systemImage: "photo")
                    }
                    Button { showFileImporter = true } label: {
                        Label("From Files / SD card", systemImage: "folder")
                    }
                } label: { Image(systemName: "plus") }
            }
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 4) {
            // what Paste will do, or how to get something to paste
            Group {
                if let clip = store.clipboard {
                    Text("Paste: \(clip.summary) (from \(clip.sourceName))")
                } else {
                    Text("Select one photo and tap Copy to choose edits to paste onto others.")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 12)
            .accessibilityIdentifier("lib-clipboard")
            HStack(spacing: 0) {
                let all = Set(visible.map(\.id))
                barButton(all.isSubset(of: selection) ? "None" : "All", "checkmark.circle", id: "lib-select-all") {
                    selection = all.isSubset(of: selection) ? [] : all
                }
                barButton("Copy", "doc.on.doc", id: "lib-copy") { copyFrom = selectedItems.first }
                    .disabled(selection.count != 1)
                barButton("Paste", "doc.on.clipboard", id: "lib-paste") {
                    if let clip = store.clipboard { paste(clip, to: selectedItems) }
                }
                .disabled(store.clipboard == nil || selection.isEmpty)
                barButton("Export", "square.and.arrow.up", id: "lib-export") { showBatchExport = true }
                    .disabled(selection.isEmpty)
                barButton("Delete", "trash", id: "lib-delete") { confirmDelete = true }
                    .disabled(selection.isEmpty)
                    .tint(.red)
            }
        }
        .padding(.top, 6).padding(.bottom, 4)
        .background(.bar)
    }

    private func barLabel(_ title: String, _ system: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: system).font(.system(size: 18))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .frame(maxWidth: .infinity).frame(height: 44)
    }

    private func barButton(_ title: String, _ system: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(title, system) }.accessibilityIdentifier(id)
    }

    private func paste(_ clip: Clipboard, to list: [LibraryItem]) {
        guard !list.isEmpty else { return }
        if clip.bringsDenoise, EditSession.hasDenoiseModel { denoisePaste = list; return }
        store.paste(clip, to: list)
        show("Pasted \(clip.summary) onto \(list.count) photo\(list.count == 1 ? "" : "s").")
    }

    /// About a minute per 24 MP photo on an iPhone 17 Pro Max (owner's phone, 21 Oct: 57 s), twice that at 48 MP.
    private func denoiseMinutes(_ n: Int) -> String {
        n <= 1 ? "about a minute (2 for 48 MP ProRAW)" : "about \(n) minutes (twice that for 48 MP ProRAW)"
    }

    @ViewBuilder
    private var denoiseBanner: some View {
        if let b = store.denoiseBatch {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.paused ? "AI Denoise paused · \(b.count - b.done) photo\(b.count - b.done == 1 ? "" : "s") left"
                                  : "AI Denoise · photo \(b.done + 1) of \(b.count) · \(Int(b.fraction * 100))%")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                    if !b.paused { ProgressView(value: (Double(b.done) + b.fraction) / Double(max(1, b.count))).tint(.white) }
                    Text(b.paused ? b.name : "\(b.name) · leaving Lumen pauses it").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if b.paused {
                    Button("Continue") { store.continueDenoiseBatch() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("denoise-batch-continue")
                }
                Button(role: .cancel) { store.cancelDenoiseBatch() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).accessibilityIdentifier("denoise-batch-cancel")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12).padding(.bottom, selecting ? 84 : 12)
            .accessibilityIdentifier("denoise-batch")
        } else if let p = store.pausedCleans.first {
            Button { path = [p.item] } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.sparkles")
                    Text("AI Denoise paused on \(p.item.displayName) at \(Int(p.fraction * 100))%").font(.footnote.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("Continue").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.bottom, selecting ? 84 : 12)
            .accessibilityIdentifier("denoise-paused")
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { if notice == text { notice = nil } }
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if store.importing {
            VStack(spacing: 10) {
                ProgressView()
                Text("Importing \(min(store.importDone + 1, store.importTotal)) of \(store.importTotal)…").font(.footnote)
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if let p = store.batchProgress {
            VStack(spacing: 10) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 160)
                Text("Exporting \(min(p.done + 1, p.total)) of \(p.total)…").font(.footnote)
                // A19: a batch export can now be stopped; the photos already done are kept.
                Button("Stop") { store.cancelExport() }
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("export-cancel")
            }
            .padding(22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("batch-progress")
        }
    }
}

struct ThumbnailView: View {
    @EnvironmentObject var store: LibraryStore
    let item: LibraryItem

    var body: some View {
        let _ = store.thumbVersion // re-read the file whenever a thumbnail finishes
        let current = store.item(item.id) ?? item
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = store.thumbnail(item) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if store.unreadable.contains(item.id) {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.title3)
                        Text("Can't open").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("thumb-unreadable")
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 2) {
                    if current.flag != 0 {
                        Image(systemName: "flag.fill").foregroundStyle(current.flag == 1 ? .green : .red)
                    }
                    if current.rating > 0 {
                        Text("\(current.rating)").foregroundStyle(.yellow)
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                .font(.caption2)
                .shadow(radius: 2)
                .padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                // RAW or not at a glance: a JPEG has no hidden highlight detail to bring back
                if UTType(filenameExtension: (item.fileName as NSString).pathExtension.lowercased())?.conforms(to: .rawImage) == true {
                    Text("RAW").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white).padding(4)
                }
            }
            .clipped()
    }
}
