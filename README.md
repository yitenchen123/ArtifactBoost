# ArtifactBoost — GitHub Actions 产物加速下载（iOS）

[![Build ArtifactBoost](https://github.com/yitenchen123/ArtifactBoost/actions/workflows/build.yml/badge.svg)](https://github.com/yitenchen123/ArtifactBoost/actions/workflows/build.yml)

一个原生 SwiftUI iOS 应用：登录 GitHub，浏览仓库的 Actions 运行记录与产物，用**多线程分段并发下载**大幅加速产物拉取。

## 为什么镜像站加速不了 Actions 产物？

GitHub 产物的下载流程是：

1. 带 Token 请求 `api.github.com/.../artifacts/{id}/zip`
2. GitHub 返回 **302 跳转**到一个临时的 Azure Blob 签名地址
3. 真正的文件从 Azure 服务器下载

ghproxy 等公开镜像无法携带你的 Token 去请求这个接口，所以全部失效。
本 App 在**本机**完成鉴权和跳转解析，拿到签名地址后直接对 Azure 地址做 **HTTP Range 分段并发下载**（类似 IDM/aria2 的多线程）。GitHub/Azure 对单连接有限速，多并发通常能提速 **3–10 倍**。

## 功能

**不限于自己的仓库**：搜索 Tab 可以搜全站仓库，别人的公开仓库照样能进去下载产物 / 日志 / 正式版 / 源码；
也可以直接粘贴 `owner/repo` 或 GitHub 链接打开。

**能加速下载的内容**——GitHub 上能下载的，这里基本都能下：

| 类型 | 位置 | 说明 |
| --- | --- | --- |
| 构建产物 | 仓库 → 构建 → 某次运行 | Actions Artifacts，主力场景 |
| 构建日志 | 仓库 → 构建 → 某次运行 | GitHub 打包好的 logs.zip |
| 正式版附件 | 仓库 → 正式版 → 某个 Release | Release Assets，含源码包 |
| 源码包 | 仓库 → 源码 / Release 页 | zipball / tarball，可选任意分支或 tag |

**功能**

- Personal Access Token 登录（Token 只存本机钥匙串，不上传任何服务器）
- 界面参考 GitHub 移动端：Primer 配色、自动适配深色模式、语言色点与 owner/repo 双色标题
- 底部「仓库 / 搜索 / 下载 / 设置」四个 Tab，仓库内分「构建 / 正式版 / 源码」三栏
- 搜索全站仓库（支持最佳匹配 / 星标最多 / 最近更新排序），也能直接粘贴仓库地址打开
- 下载中心统一管理所有任务，可取消 / 移除 / 清空已完成
- **1–64 可调并发分段下载**（默认 16），实时显示进度、百分比和速度
- **智能多通道加速**：直连与公共镜像多通道并行，初始权重均等，下载中按实时吞吐动态分配，带宽叠加
- **后台续下**：未完成任务落盘，进程被杀后下次启动自动恢复下载
- 自动重试（每段最多 3 次）、可随时取消
- 下载完成后一键导出到「文件」App / 分享（也可以在「文件」App → 我的 iPhone → ArtifactBoost → Artifacts 里直接找到）

## 安装到 iPhone（三种方式，任选一种）

### 方式 A：直接下载 CI 构建好的安装包（没有 Mac 也能用）

1. 打开本仓库的 **Actions** 页面 → 选最新一次成功的 **Build ArtifactBoost**
2. 在页面底部的 **Artifacts** 区域下载 **ArtifactBoost-unsigned.ipa**
3. 在电脑上用免费工具自签安装到手机（未签名包不能直接双击安装）：
   - **Sideloadly**（Windows / macOS，最省事）：拖入 ipa → 填 Apple ID → Start
   - **AltStore / SideStore**：把 ipa 放进 AltStore 后安装
   - 免费 Apple ID 签名的 App 有效期为 7 天，到期重签一次即可
4. 装好后打开 App，粘贴 Token 登录即可使用

> 同一个 Artifacts 里还有 **ArtifactBoost-simulator.zip**，是给 Mac 上的 iOS 模拟器用的。

### 方式 B：Mac + Xcode 本地运行

1. Mac 上安装 **Xcode 16 或更新版本**（XcodeGen 生成的是新版工程格式，Xcode 15 打不开）
2. 安装 XcodeGen 并生成工程：

   ```bash
   brew install xcodegen
   xcodegen generate
   open ArtifactBoost.xcodeproj
   ```

3. 选中 TARGETS → ArtifactBoost → **Signing & Capabilities**，Team 选择你的 Apple ID（免费 Personal Team 即可）
4. 连上 iPhone，选中设备，按 `⌘R` 运行

### 方式 C：纯手工建工程（不使用 XcodeGen）

1. 打开 Xcode → **Create New Project** → **iOS → App**
   - Product Name：`ArtifactBoost`；Interface：**SwiftUI**；Language：**Swift**
2. 删除 Xcode 自动生成的 `ContentView.swift` 和 `ArtifactBoostApp.swift`
3. 把 `Sources` 里的全部 `.swift` 文件拖进项目导航（勾选 **Copy items if needed**，Target 勾选 ArtifactBoost）
4. General 里把 Minimum Deployments 设为 **iOS 16.0**，Signing 里选好自己的 Team，`⌘R` 运行

## 创建 Token（二选一）

**方式 A：Classic Token（最省事）**
打开 https://github.com/settings/tokens/new
→ Note 随便填 → Expiration 自选 → 勾选 **`repo`** → Generate → 复制 `ghp_` 开头的 Token。

**方式 B：Fine-grained Token（更安全）**
打开 https://github.com/settings/personal-access-tokens/new
→ Repository access 选 **Only select repositories** 并勾选目标仓库
→ Permissions 里把 **Actions** 和 **Contents** 都设为 **Read**
→ Generate → 复制 `github_pat_` 开头的 Token。

在 App 登录页粘贴 Token，点「验证并登录」。

## 使用

**先花 10 秒在「设置」里把加速参数调好，之后每次下载都直接生效：**

1. **设置 → 加速设置**：并发连接数选 16（网络好可以拉到 32 / 64）—— 改动即自动保存
2. **设置 → 下载源**：点「镜像加速」（推荐）或「官方源」，一点即切换并保存；有自建反代可打开「自建中转」填前缀
3. 回到**仓库** → 选仓库 →（构建 / 正式版 / 源码）→ 点「加速下载」

下载中的任务都在底部「下载」Tab 里，可以随时取消、重试、导出到「文件」App。

### 能下载别人的仓库吗？

能。搜索 Tab 里搜到的**公开仓库**，不需要你拥有它，就能下载：

- 构建产物 / 构建日志（Actions）
- 正式版附件（Release Assets）
- 源码包（zipball / tarball，任意分支或 tag）

唯一要求是 Token 能读取公开仓库：

- **classic Token**：勾选 `repo` 即可
- **fine-grained Token**：需要在创建时允许读取公开仓库（Public repositories 只读），
  或者把目标仓库加进授权范围

如果打开仓库时提示 403 / 404，就是 Token 权限问题，App 会给出对应提示。

### 下载通道说明（设置 → 下载源，一点即切换并保存）

- `官方源`：直接连 GitHub 的 Azure 存储，最安全，但国内经常只有几十 KB/s
- `镜像加速`（默认）：直连与几个公共镜像多通道并行，带宽叠加
  （分块初始均分，下载中按实时吞吐动态分配，快通道多干活）
- `自建中转`：打开开关后填自己的加速前缀，比如自建的 Cloudflare Worker / 反向代理地址；前缀为空时回退直连

> 公共镜像只中转「已经签名的产物下载地址」，整个过程不经过你的 Token；
> 但产物数据本身会经过第三方服务器，因此**私有仓库一律强制直连**。

### 自建加速前缀（可选，最稳）

在 Cloudflare Workers 新建一个 Worker，粘贴下面几行，把生成的地址填进 App 的「自定义」：

```js
export default {
  async fetch(request) {
    const target = new URL(request.url).pathname.slice(1) + new URL(request.url).search
    return fetch(target, { headers: request.headers, method: request.method })
  }
}
```

然后填 `https://你的worker名.workers.dev/` 即可（Range 请求会自动透传，支持多线程分段）。

## 到底能跑多快？

速度由三段链路里最慢的一段决定，App 只能优化其中一段：

| 环节 | 实际情况 |
| --- | --- |
| 你的宽带 | 100Mbps≈12MB/s、300Mbps≈37MB/s、500Mbps≈62MB/s —— 这是绝对上限 |
| 到 GitHub 存储的链路 | 国内直连 Azure 常见只有几十 KB/s，链路差的时段更慢 |
| 并发 + 中转（App 负责） | 默认 16 连接、可拉到 64；智能加速把多条通道叠加 |

对应的现实预期：

- **直连 + 多连接**：国内通常 1~5 MB/s，晚高峰可能只有几百 KB/s
- **公共镜像 + 多连接**：常见几 MB/s（镜像本身也会被挤，且不同节点速度差别很大）
- **自建中转 + 32~64 连接**：这是唯一能稳定摸到几十 MB/s 的路子。
  Cloudflare Worker 或香港/国内 VPS 反代，单连接就能有几 MB/s，多连接叠加后取决于你的宽带上限

> 一句话：**如果不开中转，光靠 App 不可能稳定跑到几十 MB/s**——那是链路物理限制，不是并发数能解决的。
> 用上面的「自建加速前缀」接一个中转，再配合 32~64 并发，才有机会。

下载时产物卡片会显示「通道 + 实测速度」，可以直接用它验证自己环境的上限。

### 能不能跑满我的宽带？

能 —— 前提是「源端能给出的带宽 ≥ 你的带宽」。为了不白白浪费可用带宽，引擎做了两件事：

- **多会话连接**：Cloudflare 这类 CDN 会协商 HTTP/2，所有请求会被塞进**同一条 TCP 连接**，
  长链路下单连接就是天花板，开再多"连接"也没用。引擎会拆成最多 4 个独立 URLSession 会话，
  每个会话有独立连接池，才能拿到真正的并行连接
- **分块数 = 连接数 × 4**：多出来的分块在 URLSession 里排队，哪条连接先空出来就接下一条，
  不会因为"最慢的那一块"拖住整体

所以：如果中转能给到 10 MB/s 以上，App 会把这些带宽全部吃满，直到撞上你的宽带上限；
如果速度始终停在几百 KB，那说明源端只给了这么多 —— 换一条中转线路才是解法，加连接没用。

> 自建反代的小提示：nginx 建议不要开 `http2`（写 `listen 443 ssl;` 而不是 `listen 443 ssl http2;`）。
> HTTP/1.1 下单连接限速更明显，多连接的收益更大；App 的多个会话也能兜住 h2 的情况。

## 注意事项

- 下载时尽量保持 App 在前台：已申请系统后台任务，切走后有约 30 秒缓冲，之后 iOS 仍会暂停网络任务
- 大文件建议在 Wi-Fi 下下载
- 国内直连 GitHub 的 Azure 存储常见只有几十 KB/s，这是链路的限制而不是 App 的限制；
  多开连接与「智能加速」通道就是为了绕开它，走镜像/自建反代通常能到几 MB/s
- GitHub 产物默认保留 90 天，过期的产物（列表里标红「已过期」）无法下载
- 加速的原理是绕过单连接限速，无法突破你本地网络的物理带宽上限
- Token 不要泄露给他人；怀疑泄露时到 GitHub Settings 里点 Revoke 即可

## 文件结构

```
Sources/
├── ArtifactBoostApp.swift   App 入口，按登录状态切换界面
├── SessionManager.swift     登录态管理（Token 存取）
├── KeychainHelper.swift     系统钥匙串读写
├── GitHubModels.swift       API 数据模型
├── GitHubClient.swift       GitHub REST API 客户端（含 302 签名地址解析）
├── DownloadRoute.swift      下载通道（直连 / 镜像 / 自定义）
├── DownloadEngine.swift     多线程 Range 分段下载引擎（核心加速逻辑）
├── DownloadManager.swift    下载任务调度（状态/进度/取消/重试）
├── Formatters.swift         字节数/网速格式化
│
│  ——— 界面 ———
├── ArtifactBoostApp.swift   App 入口：未登录显示登录页，已登录进主界面
├── RootTabView.swift        底部 Tab：仓库 / 搜索 / 下载 / 设置
├── LoginView.swift          登录页
├── RepoListView.swift       我的仓库（筛选 + GitHub 风格仓库行）
├── SearchView.swift         搜索全站仓库 / 直接打开仓库
├── RepoDetailView.swift     仓库详情：构建 / 正式版 / 源码 三栏
├── RunDetailView.swift      单次构建：构建日志 + 全部产物
├── ReleaseDetailView.swift  正式版：附件 + 该 tag 的源码包
├── DownloadsView.swift      下载中心（进行中 / 已完成）
├── SettingsView.swift       设置：账户、并发、下载源切换
├── DownloadItemRow.swift    通用下载行（四种下载类型共用）
├── Theme.swift              统一视觉元素（徽标 / 胶囊 / 空态 / 错误条）
└── DownloadItem.swift       可下载项抽象（产物 / 日志 / 附件 / 源码包）
```
