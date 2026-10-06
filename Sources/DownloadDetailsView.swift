import SwiftUI

/// 下载详情面板 —— 对应 Neat Download Manager 的「连接」视图。
///
/// 展示三类信息（用户选定的口径）：
///  1. 分段进度与速度：每条连接啃哪个字节区间、跑到百分比、当前多快；
///  2. 分段连接状态：等待/下载中/重试中/完成/失败，第几次重试，服务端回了什么码；
///  3. 下载地址与通道：每段走的是哪条镜像，以及当前实际请求的完整 URL（可一键复制）。
///
/// 视觉升级：顶部是渐变数字指标卡 + 连接热力条，下面是按速度排序的车道明细。
struct DownloadDetailsView: View {
    let title: String
    let diagnostics: DownloadDiagnostics?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let diagnostics {
                    content(diagnostics)
                } else {
                    // 还没跑起来（正在解析地址 / 还没分段）：给个体面的占位，别显示空白
                    EmptyStateView(
                        systemName: "antenna.radiowaves.left.and.right",
                        title: "正在建立连接",
                        message: "稍候即可看到各分段明细"
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .background(Theme.canvas)
            .navigationTitle("下载详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func content(_ diagnostics: DownloadDiagnostics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)

                summarySection(diagnostics)

                if !diagnostics.routes.isEmpty {
                    routeSection(diagnostics)
                }

                laneSection(diagnostics)

                if !diagnostics.activeUrl.isEmpty {
                    urlSection(diagnostics.activeUrl)
                }
            }
            .padding(Theme.Spacing.md)
        }
    }

    // MARK: - 汇总

    private func summarySection(_ diagnostics: DownloadDiagnostics) -> some View {
        let totalSpeed = diagnostics.lanes.reduce(0) { $0 + $1.speedBytesPerSecond }
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // 大数字：实时总速度（这是用户最关心的一个数）
            VStack(alignment: .leading, spacing: 2) {
                Text("实时总速度")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.green)
                    Text(formatSpeed(totalSpeed))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.green)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.green.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(Theme.green.opacity(0.25), lineWidth: 1)
            }

            // 分段热力条：颜色 = 状态，长度 = 条数
            if !diagnostics.lanes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    LaneHeatStrip(lanes: diagnostics.lanes, target: diagnostics.targetLanes)
                    HStack(spacing: 10) {
                        legend(color: Theme.green, text: "下载中")
                        legend(color: Theme.blue.opacity(0.7), text: "已完成")
                        legend(color: Theme.orange, text: "重试")
                        legend(color: Theme.red, text: "失败")
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                }
            }

            HStack(spacing: 8) {
                MetricTile(label: "活跃 / 目标",
                           value: "\(diagnostics.lanes.count) / \(diagnostics.targetLanes)",
                           tint: Theme.blue, systemImage: "point.3.connected.trianglepath.dotted")
                MetricTile(label: "自适应窗口",
                           value: diagnostics.adaptiveWindow > 0 ? "\(diagnostics.adaptiveWindow)" : "—",
                           tint: Theme.purple, systemImage: "dial.high.fill")
            }
            HStack(spacing: 8) {
                MetricTile(label: "切片 完成/累计",
                           value: "\(diagnostics.doneSlices) / \(diagnostics.totalSlices)",
                           tint: Theme.muted, systemImage: "square.grid.2x2.fill")
                MetricTile(label: "重试 / 切分",
                           value: "\(diagnostics.retries) / \(diagnostics.splits)",
                           tint: Theme.orange, systemImage: "arrow.triangle.2.circlepath")
            }

            if diagnostics.windowIncreases > 0 || diagnostics.windowDecreases > 0 {
                MetricTile(label: "窗口 涨/缩 · 峰值",
                           value: "\(diagnostics.windowIncreases) / \(diagnostics.windowDecreases) · \(diagnostics.windowPeak)",
                           tint: Theme.blue, systemImage: "chart.line.uptrend.xyaxis")
            }

            if diagnostics.stalled {
                infoBanner(text: "检测到连接卡住：引擎已自动掐断并重建连接，速度会很快恢复。",
                           color: Theme.orange, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }

            if diagnostics.throttles > 0 {
                infoBanner(text: "检测到服务端限流（429/503）：引擎已自动砍半并发并按指数退避重试，这是正常的自我节流，不是下载失败。",
                           color: Theme.orange, systemImage: "gauge.with.dots.needle.33percent")
            }

            Text("说明：并发上限在「设置」里调整。引擎用 AIMD 自适应算法自己爬到服务器愿意给的并发 —— 「自适应窗口」就是当前实际在用的档位，遇到限流会自动砍半。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 4)
            Text(text).font(.system(size: 9)).foregroundStyle(Theme.subtle)
        }
    }

    private func infoBanner(text: String, color: Color, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption2)
                .foregroundStyle(color.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    // MARK: - 通道

    private func routeSection(_ diagnostics: DownloadDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionTitle("通道", systemImage: "arrow.triangle.branch")
            VStack(spacing: 0) {
                ForEach(Array(diagnostics.routes.enumerated()), id: \.element.id) { index, route in
                    if index > 0 { Hairline() }
                    HStack(spacing: Theme.Spacing.xs) {
                        Circle()
                            .fill(route.isActive ? Theme.green : Theme.border)
                            .frame(width: 7, height: 7)
                        Text(route.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(route.isActive ? Theme.strongText : Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if route.isActive {
                            Text("使用中")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Theme.green.opacity(0.12), in: Capsule())
                        }
                        Text(formatSpeed(route.speedBytesPerSecond))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(route.isActive ? Theme.green : Theme.subtle)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
        }
    }

    // MARK: - 分段明细

    private func laneSection(_ diagnostics: DownloadDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionTitle("分段明细（\(diagnostics.lanes.count)/\(diagnostics.targetLanes) 条连接）",
                         systemImage: "list.bullet.indent")

            if diagnostics.lanes.isEmpty {
                Text("当前没有活跃分段")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(diagnostics.lanes.enumerated()), id: \.element.id) { index, lane in
                        if index > 0 { Hairline() }
                        LaneRow(lane: lane)
                    }
                }
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                }
            }
        }
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.purple)
            Text(text)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.strongText)
        }
    }

    // MARK: - 下载地址

    private func urlSection(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                sectionTitle("当前下载地址", systemImage: "link")
                Spacer()
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain)
            }
            Text(url)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Theme.canvas,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                }
        }
    }
}

/// 一条车道的明细行
private struct LaneRow: View {
    let lane: LaneSnapshot

    private var tint: Color {
        switch lane.state {
        case .pending: return Theme.subtle
        case .downloading: return Theme.green
        case .retrying: return Theme.orange
        case .done: return Theme.blue
        case .failed: return Theme.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("#\(lane.laneId)")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.strongText)
                Text(lane.routeName)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)

                Text(lane.state.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(tint.opacity(0.12), in: Capsule())

                Text(formatSpeed(lane.speedBytesPerSecond))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }

            GradientProgressBar(fraction: lane.fraction,
                                height: 4,
                                tint: LinearGradient(colors: [tint.opacity(0.6), tint],
                                                     startPoint: .leading, endPoint: .trailing))

            HStack(spacing: 8) {
                Text("\(formatBytes(lane.start)) – \(formatBytes(lane.end))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.subtle)
                Spacer(minLength: 0)
                if lane.attempt > 1 {
                    Text("第 \(lane.attempt) 次")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                }
                if let status = lane.lastStatus {
                    Text("HTTP \(status)")
                        .font(.system(size: 9))
                        .foregroundStyle(status >= 400 ? Theme.orange : Theme.subtle)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
