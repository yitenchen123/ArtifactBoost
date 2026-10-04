import Foundation

/// 后台下载的任务落盘：未完成的任务（下载项 + 加速设置快照）。
///
/// 进程被系统杀掉后内存队列全丢；有了这份记录，
/// 下次启动时 `DownloadManager.restorePending()` 能把没下完的任务自动续上。
/// 只有「死时还没终结」的任务会留在这里：
/// 完成 / 失败 / 用户取消 / 移除都会删记录，不会复活。
struct TaskRecord: Codable, Sendable {
    let item: DownloadItem
    let connections: Int
    let mode: RouteMode
    let customPrefix: String

    init(item: DownloadItem, settings: AccelerationSettings) {
        self.item = item
        self.connections = settings.clampedConnections
        self.mode = settings.mode
        self.customPrefix = settings.customPrefix
    }

    var settings: AccelerationSettings {
        AccelerationSettings(connections: connections, mode: mode, customPrefix: customPrefix)
    }
}

/// 未完成任务的持久化：UserDefaults 存一份 JSON 数组。
/// 只在主线程（@MainActor）经由 DownloadManager 调用。
final class DownloadTaskStore {
    private let key = "ab.pendingTasks.v1"
    private let store = UserDefaults.standard

    /// 入队 / 重试时落盘（同 id 覆盖）
    func save(_ record: TaskRecord) {
        var current = Dictionary(uniqueKeysWithValues: loadAll().map { ($0.item.id, $0) })
        current[record.item.id] = record
        persist(Array(current.values))
    }

    /// 终结（完成 / 失败 / 取消 / 移除）时清记录，避免下次启动复活
    func remove(id: String) {
        persist(loadAll().filter { $0.item.id != id })
    }

    /// 读出全部未完成任务；数据损坏时清空并返回空表，不让坏数据卡死恢复
    func loadAll() -> [TaskRecord] {
        guard let data = store.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([TaskRecord].self, from: data)
        } catch {
            store.removeObject(forKey: key)
            return []
        }
    }

    private func persist(_ records: [TaskRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        store.set(data, forKey: key)
    }
}
