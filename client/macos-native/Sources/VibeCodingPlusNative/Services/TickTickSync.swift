import Foundation

// MARK: - TickTick API Models

private struct TickTickProject: Decodable {
    let id: String
    let name: String?
}

private struct TickTickProjectData: Decodable {
    let project: TickTickProject?
    let tasks: [TickTickTask]?
}

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

    // MARK: - Push Local Changes

    private func pushLocalChanges(todoService: TodoService) async throws {
        let dirtyItems = await todoService.getDirtySyncItems()
        guard !dirtyItems.isEmpty else { return }

        for item in dirtyItems {
            if let ticktickId = item.ticktickId, !ticktickId.isEmpty {
                // Existing TickTick task: update or complete
                if item.completed {
                    try await completeTask(taskId: ticktickId, projectId: defaultProjectId ?? "inbox")
                } else {
                    try await updateTask(taskId: ticktickId, title: item.title, dueDate: item.dueAt)
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
                timeZone: task.timeZone
            )
        }

        // Prune local items that no longer exist in TickTick "Today"
        await todoService.pruneRemoteMissingTickTickIds(validIds: validIds)
        return todayTasks.count
    }

    // MARK: - API: Fetch Today Tasks

    /// Fetch all tasks that appear in TickTick "Today" view:
    /// dueDate <= end of today AND status != completed.
    private func fetchTodayTasks() async throws -> [TickTickTask] {
        // Step 1: Get all projects + inbox (inbox is hidden from project list)
        var projects = try await fetchProjects()
        if defaultProjectId == nil {
            defaultProjectId = projects.first?.id ?? "inbox"
        }
        // Always include inbox — it's not returned by GET /project
        let inboxProject = TickTickProject(id: "inbox", name: "Inbox")
        if !projects.contains(where: { $0.id == "inbox" }) {
            projects.insert(inboxProject, at: 0)
        }

        // Step 2: Get tasks from each project, filter for "today"
        let endOfToday = Self.endOfTodayDate()
        var result: [TickTickTask] = []

        for project in projects {
            let tasks = try await fetchTasks(projectId: project.id)
            for task in tasks {
                // Skip completed tasks
                guard (task.status ?? 0) != 2 else { continue }
                // Include if dueDate <= end of today (overdue + today)
                if let dueDateStr = task.dueDate, !dueDateStr.isEmpty,
                   let dueDate = Self.parseTickTickDate(dueDateStr) {
                    if dueDate <= endOfToday {
                        result.append(task)
                    }
                }
                // Tasks without dueDate are not in "Today" view
            }
        }

        return result
    }

    private func fetchProjects() async throws -> [TickTickProject] {
        let url = URL(string: "\(Self.apiBase)/project")!
        let data = try await performRequest(url: url, method: "GET")
        return try JSONDecoder().decode([TickTickProject].self, from: data)
    }

    private func fetchTasks(projectId: String) async throws -> [TickTickTask] {
        let url = URL(string: "\(Self.apiBase)/project/\(projectId)/data")!
        let data = try await performRequest(url: url, method: "GET")
        let projectData = try JSONDecoder().decode(TickTickProjectData.self, from: data)
        return projectData.tasks ?? []
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

    private func updateTask(taskId: String, title: String, dueDate: String?) async throws {
        let url = URL(string: "\(Self.apiBase)/task/\(taskId)")!
        var bodyDict: [String: Any] = ["title": title]
        if let dueDate { bodyDict["dueDate"] = dueDate }
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
