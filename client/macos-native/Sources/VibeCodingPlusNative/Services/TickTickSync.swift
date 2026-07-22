import Foundation

// MARK: - TickTick API Models

private struct TickTickTask: Decodable {
    let id: String
    let projectId: String?
    let title: String?
    let content: String?
    let dueDate: String?       // ISO 8601 e.g. "2025-07-22T10:00:00.000+0000"
    let startDate: String?
    let status: Int?           // 0 = normal, 2 = completed
    let priority: Int?
    let completedTime: String?
    let modifiedTime: String?
    let createdTime: String?
    let tags: [String]?
    let isAllDay: Bool?
    let timeZone: String?
}

private struct TickTickTaskCreateBody: Encodable {
    let title: String
    let projectId: String?
    let dueDate: String?
    let content: String?
    let priority: Int?
}

// MARK: - TickTick Sync Status

struct TickTickSyncStatus: Sendable {
    var enabled: Bool = false
    var busy: Bool = false
    var lastSyncAt: Date?
    var lastError: String?
    var syncCount: Int = 0
}

// MARK: - TickTickSync

/// Bidirectional sync between local TodoService and TickTick "Today" view.
/// "Today" = tasks with dueDate <= end of today (includes overdue) that are not completed.
actor TickTickSync {

    // MARK: - State

    private let token: String
    private let pollSec: Int
    private var syncTask: Task<Void, Never>?
    private var status = TickTickSyncStatus()
    private var defaultProjectId: String?

    private static let apiBase = "https://api.ticktick.com/open/v1"

    // MARK: - Init

    init(token: String, pollSec: Int = 60) {
        self.token = token
        self.pollSec = max(15, pollSec)
    }

    // MARK: - Public

    func getStatus() -> TickTickSyncStatus {
        status.enabled = !token.isEmpty
        return status
    }

    /// Start periodic sync. First sync runs immediately.
    func startPeriodicSync(todoService: TodoService) {
        guard !token.isEmpty else { return }
        stopPeriodicSync()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.performSync(todoService: todoService)
                try? await Task.sleep(for: .seconds(self.pollSec))
            }
        }
    }

    func stopPeriodicSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Perform a single sync cycle: push local changes, then pull remote.
    func performSync(todoService: TodoService) async {
        guard !token.isEmpty else { return }
        status.busy = true
        defer { status.busy = false }

        do {
            // 1. Pull "Today" tasks from TickTick (also resolves defaultProjectId)
            let pulled = try await pullRemoteChanges(todoService: todoService)

            // 2. Push local changes to TickTick
            try await pushLocalChanges(todoService: todoService)

            status.lastSyncAt = Date()
            status.syncCount += 1
            status.lastError = nil
            print("[TickTickSync] sync #\(status.syncCount) ok, pulled \(pulled) today tasks")
        } catch {
            status.lastError = error.localizedDescription
            print("[TickTickSync] sync error: \(error)")
        }
    }

    /// Immediately push dirty local items to TickTick (no pull).
    /// Called when a todo completion event is received from device for instant sync.
    func pushDirtyItems(todoService: TodoService) async {
        guard !token.isEmpty else { return }
        do {
            try await pushLocalChanges(todoService: todoService)
            status.lastSyncAt = Date()
            status.lastError = nil
            print("[TickTickSync] immediate push ok")
        } catch {
            status.lastError = error.localizedDescription
            print("[TickTickSync] immediate push error: \(error)")
        }
    }

    // MARK: - Push Local Changes

    private func pushLocalChanges(todoService: TodoService) async throws {
        let dirtyItems = await todoService.getDirtySyncItems()
        guard !dirtyItems.isEmpty else { return }

        for item in dirtyItems {
            if let ticktickId = item.ticktickId, !ticktickId.isEmpty {
                // Existing TickTick task: complete or restore
                if item.completed {
                    let projectId = item.ticktickProjectId ?? defaultProjectId ?? "inbox"
                    print("[TickTickSync] completing task \(ticktickId) in project \(projectId)")
                    try await completeTask(taskId: ticktickId, projectId: projectId)
                } else {
                    print("[TickTickSync] restoring task \(ticktickId) to uncompleted")
                    try await updateTask(taskId: ticktickId, title: item.title, dueDate: item.dueAt, status: 0)
                }
                await todoService.markItemSynced(id: item.id, ticktickId: ticktickId)
            } else if !item.completed, let dueAt = item.dueAt, !dueAt.isEmpty {
                // New local task with due date: create on TickTick
                // Only push tasks with a due date so they appear in "Today" view
                let taskId = try await createTask(title: item.title, dueDate: dueAt)
                if let taskId {
                    await todoService.markItemSynced(id: item.id, ticktickId: taskId)
                }
            }
        }
    }

    // MARK: - Pull Remote Changes

    private func pullRemoteChanges(todoService: TodoService) async throws -> Int {
        let todayTasks = try await fetchTodayTasks()
        print("[TickTickSync] fetched \(todayTasks.count) today tasks from TickTick")

        // Apply each remote task to local
        var validIds = Set<String>()
        for task in todayTasks {
            validIds.insert(task.id)
            let completed = (task.status ?? 0) == 2
            await todoService.applyRemoteTickTickTask(
                ticktickId: task.id,
                title: task.title ?? "Untitled",
                dueDate: task.dueDate,
                completed: completed,
                isAllDay: task.isAllDay,
                timeZone: task.timeZone,
                projectId: task.projectId
            )
        }

        // Prune local items that no longer exist in TickTick "Today"
        await todoService.pruneRemoteMissingTickTickIds(validIds: validIds)
        return todayTasks.count
    }

    // MARK: - API: Fetch Today Tasks

    /// Fetch all tasks that appear in TickTick "Today" view:
    /// - Uncompleted tasks with dueDate <= end of today (via POST /task/filter)
    /// - Tasks completed today (via POST /task/completed)
    private func fetchTodayTasks() async throws -> [TickTickTask] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let endOfToday = Self.endOfTodayDate()
        let startStr = Self.formatLocalDate(startOfToday)
        let endStr = Self.formatLocalDate(endOfToday)

        // 1. Uncompleted tasks due today or overdue
        let filterBody: [String: Any] = [
            "endDate": endStr,
            "status": [0]
        ]
        let filterData = try await performRequest(
            url: URL(string: "\(Self.apiBase)/task/filter")!,
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: filterBody)
        )
        let uncompleted = try JSONDecoder().decode([TickTickTask].self, from: filterData)

        // 2. Tasks completed today
        let completedBody: [String: Any] = [
            "startDate": startStr,
            "endDate": endStr
        ]
        let completedData = try await performRequest(
            url: URL(string: "\(Self.apiBase)/task/completed")!,
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: completedBody)
        )
        let completed = try JSONDecoder().decode([TickTickTask].self, from: completedData)

        // Resolve defaultProjectId from results if not yet set
        if defaultProjectId == nil {
            defaultProjectId = uncompleted.first?.projectId ?? completed.first?.projectId
        }

        print("[TickTickSync] filter: \(uncompleted.count) uncompleted, completed: \(completed.count) today")

        // Combine, dedup by id
        var seen = Set<String>()
        var result: [TickTickTask] = []
        for task in uncompleted + completed {
            if seen.insert(task.id).inserted {
                result.append(task)
            }
        }
        return result
    }

    // MARK: - API: Create / Update / Complete

    @discardableResult
    private func createTask(title: String, dueDate: String?) async throws -> String? {
        let url = URL(string: "\(Self.apiBase)/task")!
        let body = TickTickTaskCreateBody(
            title: title,
            projectId: defaultProjectId,
            dueDate: dueDate,
            content: nil,
            priority: nil
        )
        let bodyData = try JSONEncoder().encode(body)
        let data = try await performRequest(url: url, method: "POST", body: bodyData)
        let task = try JSONDecoder().decode(TickTickTask.self, from: data)
        return task.id
    }

    private func updateTask(taskId: String, title: String, dueDate: String?, status: Int? = nil) async throws {
        let url = URL(string: "\(Self.apiBase)/task/\(taskId)")!
        var bodyDict: [String: Any] = ["title": title]
        if let dueDate { bodyDict["dueDate"] = dueDate }
        if let status { bodyDict["status"] = status }
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        _ = try await performRequest(url: url, method: "POST", body: bodyData)
    }

    private func completeTask(taskId: String, projectId: String) async throws {
        let url = URL(string: "\(Self.apiBase)/project/\(projectId)/task/\(taskId)/complete")!
        _ = try await performRequest(url: url, method: "POST")
    }

    // MARK: - HTTP Helper

    private func performRequest(url: URL, method: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        if let body {
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TickTickSyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw TickTickSyncError.httpError(code: http.statusCode, body: bodyStr)
        }
        return data
    }

    // MARK: - Date Helpers

    /// Parse TickTick date format: "2026-07-21T16:00:00.000+0000"
    private static func parseTickTickDate(_ str: String) -> Date? {
        // TickTick uses format: yyyy-MM-dd'T'HH:mm:ss.SSSZ (e.g. "2026-07-21T16:00:00.000+0000")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: str) { return date }

        // Fallback: try ISO 8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: str) { return date }

        // Fallback: without fractional seconds
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: str)
    }

    /// Returns a Date representing end of today (23:59:59) in local timezone.
    private static func endOfTodayDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay)!
    }

    /// Format a Date to local timezone string: "2026-07-23T23:59:59.000+0800"
    private static func formatLocalDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}

// MARK: - Errors

enum TickTickSyncError: LocalizedError {
    case invalidResponse
    case httpError(code: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "TickTick API 返回无效响应"
        case .httpError(let code, let body):
            return "TickTick API 错误 (\(code)): \(body.prefix(200))"
        }
    }
}
