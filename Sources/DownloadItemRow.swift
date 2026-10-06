import SwiftUI

/// 通用「可下载项」行：产物 / 构建日志 / 发行版附件 / 源码包 共用。
///
/// 视觉分层：
///  1. 顶部「图标 + 标题 + 元信息」，与 GitHub 移动端仓库行同一套语言；
///  2. 中部是**自适应**的操作区 —— 没下载时是一个渐变主按钮，
///     下载中变成「渐变进度条 + 速度徽标 + 连接热力条」，完成后收成一条成功态；
///  3. 底部保留次要操作（详细信息 / 取消 / 重试），默认低调、hover 才亮。
struct DownloadItemRow: View {
    let item: DownloadItem
    var disabled: Bool = false
    var disabledNote: String?

    @EnvironmentObject private var downloads: DownloadManager
    @State private var showDetails = false
    /// 速度历史：用来画迷你趋势线，让「速度在涨还是在掉」一眼可见
    @State private var speedSamples: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionArea
        }
        .padding(.vertical, 6)
        .opacity(disabled ? 0.55 : 1)
        .animation(.snappy(duration: 0.28), value: downloads.state(for: item))
        .sheet(isPresented: $showDetails) {
            // 边下边看：面板里的数据每次都从最新一帧进度里取，
            // 所以重开面板看到的永远是「此刻」的明细。
            DownloadDetailsView(title: item.title, diagnostics: currentDiagnostics)
        }
        .onChange(of: currentSpeed) { newValue in
            guard newValue > 0 else { return }
            speedSamples.append(newValue)
            if speedSamples.count > 32 { speedSamples.removeFirst(speedSamples.count - 32) }
        }
    }

    /// 当前这一帧的分段明细（未在下载时为 nil）
    private var currentDiagnostics: DownloadDiagnostics? {
        if case .downloading(let progress) = downloads.state(for: item) {
            return progress.diagnostics
        }
        return nil
    }

    private var currentSpeed: Double {
        if case .downloading(let progress) = downloads.state(for: item) {
            return progress.speedBytesPerSecond
        }
        return 0
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: item.iconName,
                      color: Theme.color(for: item.source),
                      size: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.strongText)
                    .lineLimit(2)

                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    KindChip(text: item.kindName, color: Theme.color(for: item.source))
                    if let size = item.size {
                        Text(formatBytes(size))
                            .font(.caption2)
                            .foregroundStyle(Theme.subtle)
                    }
                    if !item.source.supportsChunkedDownload {
                        Text("单连接")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Theme.orange.opacity(0.12), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 0)

            if disabled, let note = disabledNote {
                StatusPill(text: note, color: .gray)
            }
        }
    }

    // MARK: - 操作区

    @ViewBuilder
    private var actionArea: some View {
        switch downloads.state(for: item) {
        case .idle:
            Button {
                downloads.start(item, settings: AccelerationSettings.load())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text("加速下载")
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.brandGradient,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .shadow(color: Theme.blue.opacity(0.25), radius: 6, y: 3)
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled)

        case .resolving:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(downloads.routeSummary[item.id] ?? "正在解析下载地址…")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

        case .downloading(let progress):
            downloadingView(progress)

        case .finished(let url):
            finishedView(url)

        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: - 下载中

    private func downloadingView(_ progress: DownloadProgress) -> some View {
        let diagnostics = progress.diagnostics
        let stalled = diagnostics?.stalled ?? false

        return VStack(alignment: .leading, spacing: 9) {
            if progress.totalBytes > 0 {
                GradientProgressBar(fraction: progress.fraction,
                                    height: 9,
                                    stalled: stalled)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.strongText)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Text("\(formatBytes(progress.downloadedBytes)) / \(formatBytes(progress.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()

                    Spacer(minLength: 0)

                    SpeedBadge(bytesPerSecond: progress.speedBytesPerSecond)
                }
            } else {
                // 探测不到体积（单连接流式）：给不确定进度的动画条 + 速度
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("单连接下载中…")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    SpeedBadge(bytesPerSecond: progress.speedBytesPerSecond)
                }
            }

            // 分段热力条：把「哪条连接在跑」画出来，比读明细表快得多
            if let diagnostics, !diagnostics.lanes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    LaneHeatStrip(lanes: diagnostics.lanes, target: diagnostics.targetLanes)
                    HStack(spacing: 8) {
                        Label("\(diagnostics.lanes.count) 条连接", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.subtle)
                        if diagnostics.adaptiveWindow > 0 {
                            Text("· 自适应 \(diagnostics.adaptiveWindow)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.subtle)
                        }
                        if diagnostics.throttles > 0 {
                            Text("· 限流 \(diagnostics.throttles)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.orange)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if stalled {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                    Text("检测到连接卡住，正在自动重建…")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.orange)
            } else if let summary = downloads.routeSummary[item.id] {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(Theme.subtle)
            }

            // 速度趋势迷你线：一眼看出速度在涨还是在掉
            if speedSamples.count >= 4 {
                SpeedSparkline(samples: speedSamples)
            }

            HStack(spacing: 14) {
                Button {
                    showDetails = true
                } label: {
                    Label("详细信息", systemImage: "chart.bar.doc.horizontal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    downloads.cancel(item)
                } label: {
                    Label("取消", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 1)
        }
    }

    // MARK: - 完成

    private func finishedView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.green)
                Text("下载完成")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.strongText)
                Spacer(minLength: 0)
                if let summary = downloads.routeSummary[item.id] {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.subtle)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 9) {
                ShareLink(item: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出 / 保存")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.green,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(PressableStyle())

                Button {
                    downloads.start(item, settings: AccelerationSettings.load())
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.blue)
                        .frame(width: 46)
                        .padding(.vertical, 8)
                        .background(Theme.blue.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: - 失败

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                downloads.start(item, settings: AccelerationSettings.load())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("重试")
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.red.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
    }
}

/// 类型小标签（构建产物 / 日志 / 附件 / 源码包）
struct KindChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 速度趋势迷你折线：把最近若干拍的速度画成一条细线。
/// 「速度在涨还是在掉」用文字看不出来，用一条线一秒钟就懂了。
struct SpeedSparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(samples.max() ?? 1, 1)
            let stepX = geo.size.width / CGFloat(max(samples.count - 1, 1))

            Path { path in
                for (index, value) in samples.enumerated() {
                    let x = CGFloat(index) * stepX
                    let ratio = CGFloat(value / maxValue)
                    let y = geo.size.height * (1 - ratio)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Theme.speedGradient,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

/// 按下时轻微缩放 + 变暗：让按钮"有手感"，比默认的 .bordered 更有质感
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
