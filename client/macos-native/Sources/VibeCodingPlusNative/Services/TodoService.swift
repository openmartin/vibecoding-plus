import Foundation

// MARK: - Constants

private let todoFileVersion = 1

private let defaultTodoTitles = [
    "示例：按住 BOOT 说\"添加计划 喝水\"",
    "示例：UP/DN 移动选中项",
    "示例：短按 BOOT 完成或删除当前计划",
    "示例：双击 UP 切换 Todo / Live"
]

// MARK: - Todo Item Data

struct TodoItemData: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var completed: Bool
    var createdAt: Double       // epoch ms
    var updatedAt: Double       // epoch ms
    var completedAt: Double?    // epoch ms
    var dueAt: String?          // ISO 8601
    var source: String?         // "local", "seed", "ticktick"
    var ticktickId: String?
    var ticktickProjectId: String?  // TickTick project the task belongs to
    var syncUpdatedAt: Double?  // epoch ms — last TickTick sync time
    var dirty: Bool             // needs sync to TickTick
    var isAllDay: Bool?         // true = all-day task (no specific time)
    var timeZone: String?       // e.g. "Asia/Shanghai"
}

// MARK: - Todo Snapshot

struct TodoServiceSnapshot: Sendable {
    var items: [TodoItemData]
    var archiveItems: [TodoItemData]
    var selectedIndex: Int
    var lastActionText: String
}

// MARK: - Persisted State (Codable)

private struct PersistedState: Codable {
    var version: Int
    var items: [TodoItemData]
    var archiveItems: [TodoItemData]
    var selectedIndex: Int
}

// MARK: - TodoService

actor TodoService {

    // MARK: - State

    private var items: [TodoItemData] = []
    private var archiveItems: [TodoItemData] = []
    private var selectedIndex: Int = 0
    private var lastActionText: String = ""
    private let storagePath: String
    private var onChange: (() -> Void)?
    private var pendingReminderList: String? = nil

    // MARK: - Init

    /// Creates a new TodoService, loading persisted state from disk.
    static func create(storagePath: String) async -> TodoService {
        let service = TodoService(storagePath: storagePath)
        await service.loadFromDisk()
        return service
    }

    private init(storagePath: String) {
        self.storagePath = storagePath
    }

    // MARK: - Callback

    func setOnChange(_ handler: @escaping () -> Void) {
        self.onChange = handler
    }

    // MARK: - CRUD

    func create(title: String, dueAt: String? = nil, reminderList: String? = nil) -> TodoItemData {
        let now = epochMs()
        let item = TodoItemData(
            id: makeId(),
            title: title,
            completed: false,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            dueAt: dueAt,
            source: "local",
            ticktickId: nil,
            syncUpdatedAt: nil,
            dirty: true
        )
        items.append(item)
        selectedIndex = items.count - 1
        lastActionText = "已添加计划 \(items.count)"
        pendingReminderList = reminderList
        save()
        emitChange()
        return item
    }

    func update(id: String? = nil, index: Int? = nil, title: String? = nil, dueAt: String? = nil) {
        guard let resolvedIndex = tryResolveIndex(id: id, index: index) else { return }

        if let title {
            items[resolvedIndex].title = title
        }
        if let dueAt {
            items[resolvedIndex].dueAt = dueAt.isEmpty ? nil : dueAt
        }
        items[resolvedIndex].updatedAt = epochMs()
        items[resolvedIndex].source = "local"
        items[resolvedIndex].dirty = true
        selectedIndex = resolvedIndex
        lastActionText = "已更新计划 \(resolvedIndex + 1)"
        save()
        emitChange()
    }

    func toggle(id: String? = nil, index: Int? = nil, completed: Bool) {
        let now = epochMs()

        if !completed, let id, let archiveIndex = archiveItems.firstIndex(where: { $0.id == id }) {
            var item = archiveItems.remove(at: archiveIndex)
            item.completed = false
            item.completedAt = nil
            item.updatedAt = now
            item.source = "local"
            item.dirty = true
            items.append(item)
            selectedIndex = items.count - 1
            lastActionText = "已恢复计划"
        } else if let resolvedIndex = tryResolveIndex(id: id, index: index), completed {
            // Move to archive
            var item = items.remove(at: resolvedIndex)
            item.completed = true
            item.completedAt = now
            item.updatedAt = now
            item.source = "local"
            item.dirty = true
            archiveItems.insert(item, at: 0)
            lastActionText = "已完成计划 \(resolvedIndex + 1)"
        } else if let resolvedIndex = tryResolveIndex(id: id, index: index) {
            // Restore from archive — find by id
            let targetId = id ?? (index != nil ? nil : items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil)
            if let targetId, let archiveIndex = archiveItems.firstIndex(where: { $0.id == targetId }) {
                var item = archiveItems.remove(at: archiveIndex)
                item.completed = false
                item.completedAt = nil
                item.updatedAt = now
                item.source = "local"
                item.dirty = true
                items.append(item)
                selectedIndex = items.count - 1
                lastActionText = "已恢复计划"
            } else if items.indices.contains(resolvedIndex) {
                items[resolvedIndex].completed = false
                items[resolvedIndex].completedAt = nil
                items[resolvedIndex].updatedAt = now
                items[resolvedIndex].source = "local"
                items[resolvedIndex].dirty = true
                selectedIndex = resolvedIndex
                lastActionText = "已恢复计划 \(resolvedIndex + 1)"
            }
        }

        clampSelectedIndex()
        save()
        emitChange()
    }

    @discardableResult
    func delete(id: String? = nil, index: Int? = nil) -> [TodoItemData] {
        if let id, let archiveIndex = archiveItems.firstIndex(where: { $0.id == id }) {
            let removed = archiveItems.remove(at: archiveIndex)
            lastActionText = "已删除归档计划"
            save()
            emitChange()
            return [removed]
        }

        guard let resolvedIndex = tryResolveIndex(id: id, index: index) else { return [] }
        let removed = items.remove(at: resolvedIndex)
        selectedIndex = items.isEmpty ? -1 : min(resolvedIndex, items.count - 1)
        lastActionText = "已删除计划 \(resolvedIndex + 1)"
        save()
        emitChange()
        return [removed]
    }

    func selectNext() {
        guard !items.isEmpty else {
            lastActionText = "暂无计划"
            return
        }
        selectedIndex = (selectedIndex + 1) % items.count
        lastActionText = "当前计划 \(selectedIndex + 1)"
        save()
    }

    func selectPrev() {
        guard !items.isEmpty else {
            lastActionText = "暂无计划"
            return
        }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        lastActionText = "当前计划 \(selectedIndex + 1)"
        save()
    }

    func clearCompleted() {
        archiveItems.removeAll()
        lastActionText = "已清空已完成计划"
        save()
        emitChange()
    }

    // MARK: - Query

    func getSnapshot() -> TodoServiceSnapshot {
        TodoServiceSnapshot(
            items: items,
            archiveItems: archiveItems,
            selectedIndex: clampIndex(selectedIndex),
            lastActionText: lastActionText
        )
    }

    func getTickTickLinkedItemsByIds(_ ids: [String]) -> [TodoItemData] {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return [] }
        return items.filter { idSet.contains($0.id) && ($0.ticktickId?.isEmpty == false) }
    }

    func consumePendingReminderList() -> String? {
        let value = pendingReminderList
        pendingReminderList = nil
        return value
    }

    func getDirtySyncItems() -> [TodoItemData] {
        (items + archiveItems).filter { item in
            let src = item.source ?? "local"
            if src == "seed" { return false }
            guard let ticktickId = item.ticktickId, !ticktickId.isEmpty else {
                return src == "local"
            }
            // Has ticktickId: dirty if local changes newer than last sync
            if src == "local" { return true }
            let updatedAt = item.updatedAt
            let syncedAt = item.syncUpdatedAt ?? 0
            return updatedAt > syncedAt
        }
    }

    // MARK: - TickTick Integration

    func applyRemoteTickTickTask(ticktickId: String, title: String, dueDate: String?, completed: Bool, isAllDay: Bool? = nil, timeZone: String? = nil, projectId: String? = nil) {
        let now = epochMs()

        // Find existing item by ticktickId
        if let idx = items.firstIndex(where: { $0.ticktickId == ticktickId }) {
            items[idx].title = title
            items[idx].completed = completed
            items[idx].dueAt = dueDate
            items[idx].source = "ticktick"
            items[idx].updatedAt = now
            items[idx].syncUpdatedAt = now
            items[idx].isAllDay = isAllDay
            items[idx].timeZone = timeZone
            items[idx].ticktickProjectId = projectId
            items[idx].dirty = false
            if completed {
                items[idx].completedAt = now
                // Move completed item to archive
                let item = items.remove(at: idx)
                archiveItems.insert(item, at: 0)
            } else {
                items[idx].completedAt = nil
            }
            lastActionText = "TickTick 已同步"
            clampSelectedIndex()
            save()
            emitChange()
            return
        }

        // Also check archive
        if let idx = archiveItems.firstIndex(where: { $0.ticktickId == ticktickId }) {
            archiveItems[idx].title = title
            archiveItems[idx].completed = completed
            archiveItems[idx].dueAt = dueDate
            archiveItems[idx].source = "ticktick"
            archiveItems[idx].updatedAt = now
            archiveItems[idx].syncUpdatedAt = now
            archiveItems[idx].completedAt = completed ? now : nil
            archiveItems[idx].isAllDay = isAllDay
            archiveItems[idx].timeZone = timeZone
            archiveItems[idx].ticktickProjectId = projectId
            archiveItems[idx].dirty = false

            // If uncompleted, move back to active
            if !completed {
                var item = archiveItems.remove(at: idx)
                item.completed = false
                item.completedAt = nil
                items.append(item)
            }
            lastActionText = "TickTick 已同步"
            clampSelectedIndex()
            save()
            emitChange()
            return
        }

        // Create new item from remote
        var item = TodoItemData(
            id: makeId(),
            title: title,
            completed: completed,
            createdAt: now,
            updatedAt: now,
            completedAt: completed ? now : nil,
            dueAt: dueDate,
            source: "ticktick",
            ticktickId: ticktickId,
            ticktickProjectId: projectId,
            syncUpdatedAt: now,
            dirty: false,
            isAllDay: isAllDay,
            timeZone: timeZone
        )
        if completed {
            archiveItems.insert(item, at: 0)
        } else {
            items.append(item)
            if selectedIndex < 0 { selectedIndex = 0 }
        }
        lastActionText = "TickTick 已同步"
        save()
        emitChange()
    }

    func markItemSynced(id: String, ticktickId: String) {
        let now = epochMs()
        var changed = false
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].ticktickId = ticktickId
            items[idx].source = "ticktick"
            items[idx].syncUpdatedAt = now
            items[idx].dirty = false
            save()
            changed = true
        }
        if let idx = archiveItems.firstIndex(where: { $0.id == id }) {
            archiveItems[idx].ticktickId = ticktickId
            archiveItems[idx].source = "ticktick"
            archiveItems[idx].syncUpdatedAt = now
            archiveItems[idx].dirty = false
            save()
            changed = true
        }
        if changed {
            emitChange()
        }
    }

    func pruneRemoteMissingTickTickIds(validIds: Set<String>) {
        // Safety: if no valid IDs returned (API issue), skip pruning to avoid data loss
        guard !validIds.isEmpty else {
            print("[TodoService] prune skipped: validIds is empty (possible API issue)")
            return
        }
        let before = items.count + archiveItems.count
        items.removeAll { item in
            guard let ticktickId = item.ticktickId, !ticktickId.isEmpty else { return false }
            if item.source == "local" { return false }
            return !validIds.contains(ticktickId)
        }
        archiveItems.removeAll { item in
            guard let ticktickId = item.ticktickId, !ticktickId.isEmpty else { return false }
            if item.source == "local" { return false }
            return !validIds.contains(ticktickId)
        }
        guard items.count + archiveItems.count != before else { return }
        clampSelectedIndex()
        lastActionText = "TickTick 已同步"
        save()
        emitChange()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        let fm = FileManager.default
        guard !storagePath.isEmpty, fm.fileExists(atPath: storagePath) else {
            seedDefaults()
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: storagePath))
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            items = state.items
            archiveItems = state.archiveItems
            selectedIndex = clampIndex(state.selectedIndex)
        } catch {
            backupCorruptFile()
            seedDefaults()
        }
    }

    func save() {
        let state = PersistedState(
            version: todoFileVersion,
            items: items,
            archiveItems: archiveItems,
            selectedIndex: clampIndex(selectedIndex)
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)

            let dir = (storagePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            // Atomic write: temp file then rename
            let tempPath = "\(storagePath).\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970 * 1000)).tmp"
            try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
            try? FileManager.default.replaceItemAt(
                URL(fileURLWithPath: storagePath),
                withItemAt: URL(fileURLWithPath: tempPath)
            )
        } catch {
            print("[TodoService] save failed: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func seedDefaults() {
        let now = epochMs()
        items = defaultTodoTitles.map { title in
            TodoItemData(
                id: makeId(),
                title: title,
                completed: false,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                dueAt: nil,
                source: "seed",
                ticktickId: nil,
                syncUpdatedAt: nil,
                dirty: false
            )
        }
        archiveItems = []
        selectedIndex = 0
        save()
    }

    private func backupCorruptFile() {
        let fm = FileManager.default
        guard !storagePath.isEmpty, fm.fileExists(atPath: storagePath) else { return }
        let backupPath = "\(storagePath).corrupt-\(Int(Date().timeIntervalSince1970 * 1000))"
        try? fm.moveItem(atPath: storagePath, toPath: backupPath)
    }

    private func emitChange() {
        onChange?()
    }

    /// Resolve an item index from an explicit id, a 1-based user index, or the current selection.
    private func tryResolveIndex(id: String?, index: Int?) -> Int? {
        guard !items.isEmpty else {
            assertionFailure("todo_empty")
            return nil
        }

        // Prefer id lookup
        if let id, !id.isEmpty {
            guard let idx = items.firstIndex(where: { $0.id == id }) else {
                assertionFailure("todo_item_not_found: \(id)")
                return nil
            }
            return idx
        }

        // 1-based user-facing index
        if let index {
            let zeroBased = index - 1
            guard zeroBased >= 0, zeroBased < items.count else {
                assertionFailure("todo_index_out_of_range: \(index)")
                return nil
            }
            return zeroBased
        }

        // Fall back to selected index
        guard selectedIndex >= 0, selectedIndex < items.count else {
            assertionFailure("todo_index_required")
            return nil
        }
        return selectedIndex
    }

    private func clampIndex(_ idx: Int) -> Int {
        if items.isEmpty { return -1 }
        return min(max(idx, 0), items.count - 1)
    }

    private func clampSelectedIndex() {
        selectedIndex = clampIndex(selectedIndex)
    }

    private func makeId() -> String {
        UUID().uuidString.lowercased()
    }

    private func epochMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }
}
