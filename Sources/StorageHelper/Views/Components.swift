import AppKit
import StorageCore
import SwiftUI

struct DiskGauge: View {
    let disk: DiskInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let disk {
                HStack {
                    Text("Macintosh HD").font(.caption.bold())
                    Spacer()
                    Text("\(ByteFormat.string(disk.available)) free")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(disk.available < 20_000_000_000 ? DS.critical : .secondary)
                }
                ProgressView(value: disk.usedFraction)
                    .tint(disk.usedFraction > 0.9 ? DS.critical : disk.usedFraction > 0.8 ? DS.review : DS.tint)
                Text("\(ByteFormat.string(disk.used)) of \(ByteFormat.string(disk.total)) used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Disk info unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Horizontal bar proportional to `value / maxValue`.
struct SizeBar: View {
    let value: Int64
    let maxValue: Int64
    var color: Color = DS.reclaimable

    var body: some View {
        GeometryReader { geo in
            let fraction = maxValue > 0 ? CGFloat(Double(value) / Double(maxValue)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color.gradient).frame(width: max(2, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct SafetyBadge: View {
    let safety: SafetyLevel

    var body: some View {
        switch safety {
        case .safe:
            EmptyView()
        case .caution:
            Text("Caution")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(DS.review.opacity(0.15)))
                .foregroundStyle(DS.review)
        case .review:
            Text("Review")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(DS.review, lineWidth: 1))
                .foregroundStyle(DS.review)
        }
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(DS.review)
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access is off").font(.headline)
                Text("Without it, Diskward can't see the Trash and some caches, so the numbers will be too low. Turn on Diskward in System Settings › Privacy & Security › Full Disk Access, then scan again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") { NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL) }
                    Button("Check Again") {
                        model.hasFullDiskAccess = Permissions.hasFullDiskAccess()
                        if model.hasFullDiskAccess { model.scanAll() }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.review.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.review.opacity(0.35)))
    }
}

enum Reveal {
    static func inFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension Date {
    var relative: String {
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}
