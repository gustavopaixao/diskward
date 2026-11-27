import AppKit
import StorageCore
import SwiftUI

struct DiskExplorerView: View {
    @Environment(ExplorerModel.self) private var explorer
    @State private var pendingTrash: DirectoryScanner.Child?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if explorer.isLoading && explorer.children.isEmpty {
                ProgressView("Measuring \(Paths.display(explorer.current))…\nLarge folders can take a minute.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if explorer.children.isEmpty {
                ContentUnavailableView("Empty or unreadable folder", systemImage: "folder")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Disk Explorer")
        .onAppear { explorer.load(explorer.current) }
        .confirmationDialog(
            "Move “\(pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { child in
            Button("Move to Trash (\(ByteFormat.string(child.size)))", role: .destructive) { trash(child) }
        } message: { child in
            Text(Paths.display(child.url)).font(.technical)
        }
        .alert("Couldn't move to Trash", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Home Folder") { explorer.setRoot(Paths.home) }
                Button("Whole Disk (/)") { explorer.setRoot(URL(fileURLWithPath: "/")) }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label("Location", systemImage: "externaldrive")
            }
            .fixedSize()

            // Breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(explorer.path.enumerated()), id: \.offset) { index, url in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(index == 0 ? Paths.display(url) : url.lastPathComponent) { explorer.goTo(index: index) }
                            .buttonStyle(.borderless)
                            .fontWeight(index == explorer.path.count - 1 ? .semibold : .regular)
                    }
                }
            }

            Spacer()
            if explorer.isLoading { ProgressView().controlSize(.small) }
            Text(ByteFormat.string(explorer.currentTotal)).monospacedDigit().foregroundStyle(.secondary)
            Button { explorer.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Measure again")
        }
        .padding(10)
    }

    private var list: some View {
        let maxSize = explorer.children.first?.size ?? 0
        let total = max(explorer.currentTotal, 1)
        return List(explorer.children) { child in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: child.url.path))
                    .resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(child.name).lineLimit(1)
                        if child.unreadable > 0 {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(DS.review)
                                .help("\(child.unreadable) items couldn't be read. The real size may be larger.")
                        }
                        Spacer()
                        Text("\(Int(Double(child.size) / Double(total) * 100))%")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(ByteFormat.string(child.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                    SizeBar(value: child.size, maxValue: maxSize, color: child.isDirectory ? DS.tint : DS.otherUsed)
                }
                if child.isDirectory {
                    Button { explorer.open(child.url) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                } else {
                    Color.clear.frame(width: 14)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if child.isDirectory { explorer.open(child.url) } }
            .contextMenu {
                if child.isDirectory { Button("Open") { explorer.open(child.url) } }
                Button("Reveal in Finder") { Reveal.inFinder(child.url) }
                Divider()
                Button("Move to Trash…", role: .destructive) { pendingTrash = child }
                    .disabled((try? SafetyGuard().validate(child.url)) == nil)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { explorer.setRoot(url) }
    }

    private func trash(_ child: DirectoryScanner.Child) {
        do {
            // Same guard as the cleaners: only inside the home folder, never protected folders.
            try SafetyGuard().validate(child.url)
            try FileManager.default.trashItem(at: child.url, resultingItemURL: nil)
            CleanupLog().record(message: "[explorer] Moved to Trash | \(ByteFormat.string(child.size)) | \(child.url.path) | OK")
            explorer.remove(child)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
