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

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var filter: LibraryFilter = .all
    @State private var path: [LibraryItem] = []

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private var visible: [LibraryItem] { store.items.filter { filter.matches($0) } }

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
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(visible) { item in
                                NavigationLink(value: item) { ThumbnailView(item: item) }
                                    .contextMenu {
                                        Button(role: .destructive) { store.delete(item) } label: {
                                            Label("Remove from Lumen", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle(filter == .all ? "Lumen" : filter.rawValue)
            .navigationDestination(for: LibraryItem.self) { EditorView(item: $0).id($0.id) }
            .environment(\.openItem, { item in path = [item] })
            .task {
                guard let dir = DemoMode.value("-lumenDemoDir") else { return }
                if store.items.isEmpty {
                    let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
                    store.importFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
                if let n = DemoMode.value("-lumenDemoOpen"), let i = Int(n), store.items.indices.contains(i) {
                    path = [store.items[i]]
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            // The picker must live outside the Menu: inside it, the picker is torn down as the menu closes.
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 50,
                          matching: .images, preferredItemEncoding: .current, photoLibrary: .shared())
            .overlay {
                if store.importing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Importing \(min(store.importDone + 1, store.importTotal)) of \(store.importTotal)…").font(.footnote)
                    }
                    .padding(22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: pickerItems) { _, new in
                guard !new.isEmpty else { return }
                Task {
                    await store.importPicked(new)
                    pickerItems = []
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.rawImage, .image],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { store.importFiles(urls) }
            }
            .alert("Import problem", isPresented: Binding(get: { store.lastError != nil },
                                                         set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.lastError ?? "") }
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
                if let img = UIImage(contentsOfFile: store.thumbURL(item).path) {
                    Image(uiImage: img).resizable().scaledToFill()
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
            .clipped()
    }
}
