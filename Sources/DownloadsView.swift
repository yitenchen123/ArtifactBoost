import SwiftUI

/// 下载中心：所有正在下载 / 已完成的任务。
///
/// 视觉升级：顶部加一个「实时总览」卡片（总速度 / 活跃任务 / 完成数），
/// 用户在下载页一眼就能看到当前整机吞吐，不用点进每一条明细。
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager

    private var orderedItems: [DownloadItem] { downloads.orderedItems }

    /// 所有在下载任务的速度之和
    private var totalSpeed: Double {
        orderedItems.reduce(0) { partial, item in
            if case .downloading(let progress) = downloads.state(for: item) {
                return partial + progress.speedBytesPerSecond
            }
            return partial
        }
    }

    private var finishedCount: Int {
        orderedItems.filter {
            if case .finished = downloads.state(for: $0) { return true }
            return false
        }.count
    }

    private var failedCount: Int {
        orderedItems.filter {
            if case .failed = downloads.state(for: $0) { return true }
            return false
        }.count
    }

    var body: some View {
        List {
            if orderedItems.isEmpty {
                EmptyStateView(systemName: "arrow.down.circle",
                               title: "还没有下载任务",
                               message: "去「仓库」里挑一个构建产物、发行版附件或源码包试试")
            } else {
                Section {
                    overviewCard
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(orderedItems) { item in
                        DownloadItemRow(item: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloads.remove(item)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(downloads.activeCount > 0 ? "正在下载 \(downloads.activeCount) 个" : "全部下载")
                        Spacer()
                        if downloads.activeCount > 0 {
                            // 头部也能看到实时总速度
                            Text(formatSpeed(totalSpeed))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.green)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                } footer: {
                    Text("文件保存在「文件」App → 我的 iPhone → ArtifactBoost → Artifacts，也可以直接导出或分享。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        downloads.clearFinished()
                    } label: {
                        Label("清空已完成", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - 实时总览卡片

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Theme.green.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: downloads.activeCount > 0 ? "bolt.horizontal.fill" : "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(downloads.activeCount > 0 ? "正在加速" : "空闲")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.strongText)
                    Text("自适应并发 · 多通道叠加")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.subtle)
                }
                Spacer(minLength: 0)
                if downloads.activeCount > 0 {
                    Text(formatSpeed(totalSpeed))
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.green)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            HStack(spacing: 8) {
                MetricTile(label: "进行中", value: "\(downloads.activeCount)",
                           tint: Theme.blue, systemImage: "arrow.down.circle.fill")
                MetricTile(label: "已完成", value: "\(finishedCount)",
                           tint: Theme.green, systemImage: "checkmark.circle.fill")
                MetricTile(label: "失败", value: "\(failedCount)",
                           tint: failedCount > 0 ? Theme.red : Theme.subtle,
                           systemImage: "exclamationmark.triangle.fill")
            }
        }
        .card(padding: 14, cornerRadius: Theme.Radius.large, elevated: true)
    }
}
