import SwiftUI
import UIKit

/// 设置：账户 + 加速设置（并发）+ 下载源 + 关于
struct SettingsView: View {
    @EnvironmentObject private var session: SessionManager

    @State private var settings = AccelerationSettings.load()
    // 原神彩蛋：长按导航栏「设置」标题触发，二次确认后才跳官网，不做后台静默下载
    @State private var showGenshinEgg = false

    var body: some View {
        List {
            accountSection
            accelerationSection
            sourceSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 原生 TabView 的 tabItem 不支持长按，彩蛋触发点放在导航栏标题上
            //（与安卓端设置页 TopAppBar 标题长按兜底入口对齐）。
            ToolbarItem(placement: .principal) {
                Text("设置")
                    .font(.headline)
                    .onLongPressGesture(minimumDuration: 0.6) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showGenshinEgg = true
                    }
                    .accessibilityHint("长按发现彩蛋")
            }
        }
        .genshinEasterEggAlert(isPresented: $showGenshinEgg)
        .onAppear {
            settings = AccelerationSettings.load()
        }
    }

    // MARK: - 账户

    private var accountSection: some View {
        Section {
            HStack(spacing: 12) {
                if let url = session.user?.avatarURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
                } else {
                    IconBadge(systemName: "person.fill", color: Theme.accent, size: 46)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.user?.login ?? "已登录")
                        .font(.subheadline.weight(.semibold))
                    Text("Token 保存在本机钥匙串")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            Button(role: .destructive) {
                session.logout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("账户")
        }
    }

    // MARK: - 加速设置

    private var accelerationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("并发上限")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(settings.connections)")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.blue)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Picker("并发连接数", selection: connectionsBinding) {
                    ForEach(AccelerationSettings.connectionOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.purple)
                    Text("自适应引擎会按服务器反馈自动增减并发，这里设的只是天花板")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.subtle)
                }
            }
        } header: {
            Text("加速设置")
        } footer: {
            Text("这是**上限**而不是固定连接数。引擎用 AIMD 自适应算法：下载顺畅时慢慢往上爬（最多爬到上限），一遇限流（429/503）立刻砍半退让。所以设 128 不会像以前那样盲目砸 128 条连接撞限流 —— 只会给引擎更高的天花板。一般 16~32 就够，自建中转可以拉到 64~128。")
        }
    }

    // MARK: - 下载源

    private var sourceSection: some View {
        Section {
            HStack(spacing: 10) {
                SourceButton(title: "官方源",
                             subtitle: "直连 GitHub",
                             systemImage: "cloud.fill",
                             selected: settings.mode == .direct,
                             accent: Theme.accent) {
                    settings.mode = .direct
                    settings.save()
                    // 换源后旧的通道排序不再适用，清掉探测缓存
                    RouteProbeCache.shared.invalidateAll()
                }
                SourceButton(title: "镜像加速",
                             subtitle: "多通道并行 · 推荐",
                             systemImage: "bolt.fill",
                             selected: settings.mode == .smart,
                             accent: Theme.green) {
                    settings.mode = .smart
                    settings.save()
                    RouteProbeCache.shared.invalidateAll()
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            Toggle(isOn: customBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自建中转")
                    Text("用自己的反代地址下载")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.mode == .custom {
                TextField("https://你的中转地址/", text: prefixBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if DownloadRoute.normalizedPrefix(settings.customPrefix).isEmpty {
                    Text("前缀为空时将回退直连")
                        .font(.caption2)
                        .foregroundStyle(Theme.orange)
                }
            }
        } header: {
            Text("下载源")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.mode.detail)
                if settings.mode == .smart {
                    Text("智能加速会额外尝试 ghfast.top —— 它只认 github.com 原始地址，因此**仅对发行版（Release）附件生效**，构建产物与日志仍走其它镜像。")
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: "2.0")
            LabeledContent("并发引擎", value: "AIMD 自适应")
            LabeledContent("通道探测", value: "并发 + 5 分钟缓存")
            Link(destination: URL(string: "https://github.com/yitenchen123/ArtifactBoost")!) {
                Label("项目主页 / 自建中转教程", systemImage: "link")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("智能加速与自定义通道可能让产物数据经过第三方中转，私有仓库会自动强制走直连。Token 全程只在本机使用。")
        }
    }

    // MARK: - 绑定（改动即保存）

    private var connectionsBinding: Binding<Int> {
        Binding(get: { settings.connections },
                set: { settings.connections = $0; settings.save() })
    }

    private var prefixBinding: Binding<String> {
        Binding(get: { settings.customPrefix },
                set: { settings.customPrefix = $0; settings.save() })
    }

    /// 自建中转开关：打开进自定义，关闭回到镜像加速
    private var customBinding: Binding<Bool> {
        Binding(get: { settings.mode == .custom },
                set: {
                    settings.mode = $0 ? .custom : .smart
                    settings.save()
                })
    }
}

/// 下载源大按钮：选中时按语义色高亮，未选中时灰边。复用给官方源 / 镜像加速。
private struct SourceButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let selected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? accent : .secondary)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(selected ? accent : .primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? accent.opacity(0.12) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(selected ? accent : Color(.separator), lineWidth: selected ? 1.5 : 1)
            }
        }
    }
}