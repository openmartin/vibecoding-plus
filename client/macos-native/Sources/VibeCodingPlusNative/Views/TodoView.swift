import SwiftUI
// MARK: - Todo

struct TodoView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var dueDate: Date?
    @State private var isEditingDate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                eyebrow: "TASKS",
                title: "待办",
                subtitle: state.inlineStatus,
                trailing: {
                    Text("\(state.todos.count) 进行中")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            )

            InkPanel(title: "新增待办", symbol: "plus.circle", accent: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("输入待办内容，回车快速添加", text: $title)
                            .textFieldStyle(.plain)
                            .onSubmit { add() }
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.18), lineWidth: 1))

                        dueDateChip

                        Button { add() } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .inkProminentButton()
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                }
            }

            HStack(alignment: .top, spacing: 16) {
                TodoSection(title: "进行中", items: state.todos, archived: false)
                TodoSection(title: "归档", items: state.archivedTodos, archived: true)
                    .frame(maxWidth: 380)
            }
        }
    }

    private func add() {
        let value = title
        title = ""
        let dueISO = dueDate.map { ISO8601DateFormatter().string(from: $0) }
        dueDate = nil
        isEditingDate = false
        Task { await state.addTodo(value, dueAt: dueISO) }
    }

    @ViewBuilder
    private var dueDateChip: some View {
        if isEditingDate {
            HStack(spacing: 6) {
                DatePicker("截止日期", selection: Binding(
                    get: { dueDate ?? Date() },
                    set: { dueDate = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .frame(width: 132)
                Button {
                    dueDate = nil
                    isEditingDate = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .inkIconButton()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(InkTheme.ink.opacity(0.3), lineWidth: 1))
        } else if let date = dueDate {
            Button {
                isEditingDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(formatDate(date))
                        .font(.callout.weight(.medium))
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(InkTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(InkTheme.ink.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
                dueDate = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .inkIconButton()
        } else {
            Button {
                dueDate = Date()
                isEditingDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.caption)
                    Text("添加日期")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

struct TodoSection: View {
    let title: String
    let items: [TodoItem]
    let archived: Bool

    var body: some View {
        InkPanel(title: title, symbol: archived ? "archivebox" : "checklist", accessory: AnyView(
            Text("\(items.count)")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
        )) {
            if items.isEmpty {
                Text(archived ? "暂无归档" : "暂无待办")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        TodoRow(item: item, archived: archived)
                    }
                }
            }
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var state: AppState
    let item: TodoItem
    var archived: Bool = false
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var isHovering = false

    var body: some View {
        InkCard(hoverable: true) {
            HStack(alignment: .center, spacing: 12) {
                if !archived {
                    Button {
                        Task { await state.setTodo(item, completed: !item.completed) }
                    } label: {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(item.completed ? InkTheme.ink : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isEditing {
                    TextField("", text: $editTitle)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(InkTheme.ink.opacity(0.5), lineWidth: 1))
                        .onSubmit { saveEdit() }
                    Button("保存") { saveEdit() }.inkProminentButton()
                    Button("取消") { isEditing = false }.inkButton()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .strikethrough(item.completed)
                            .foregroundStyle(item.completed ? .secondary : .primary)
                        HStack(spacing: 8) {
                            if let dueAt = item.dueAt, !dueAt.isEmpty {
                                let info = formatDueDate(dueAt, isAllDay: item.isAllDay, timeZone: item.timeZone)
                                Label(info.text, systemImage: info.icon)
                                    .font(.caption)
                                    .foregroundStyle(info.overdue ? Color.orange : .secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                if !isEditing {
                    HStack(spacing: 6) {
                        if !archived {
                            Button {
                                editTitle = item.title
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                            }
                            .inkIconButton()
                            .opacity(isHovering ? 1 : 0.5)
                        }
                        Button {
                            Task { await state.deleteTodo(item) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption.weight(.semibold))
                        }
                        .inkIconButton(danger: true)
                        .opacity(isHovering ? 1 : 0.5)
                    }
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private func saveEdit() {
        isEditing = false
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        Task { await state.editTodo(item, title: trimmed, dueAt: item.dueAt) }
    }

    private func formatDueDate(_ iso: String, isAllDay: Bool?, timeZone: String?) -> (text: String, icon: String, overdue: Bool) {
        // Parse TickTick date format: "2026-07-21T16:00:00.000+0000"
        guard let date = Self.parseDate(iso) else { return (iso, "calendar", false) }

        // Determine the display timezone (use task's timezone or local)
        let displayTZ: TimeZone
        if let tzId = timeZone, let tz = TimeZone(identifier: tzId) {
            displayTZ = tz
        } else {
            displayTZ = .current
        }

        var calendar = Calendar.current
        calendar.timeZone = displayTZ

        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let dueDayStart = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: todayStart, to: dueDayStart).day ?? 0

        let allDay = isAllDay ?? false

        // Date part: relative day name
        let dayText: String
        if dayDiff == 0 {
            dayText = "今天"
        } else if dayDiff == 1 {
            dayText = "明天"
        } else if dayDiff == -1 {
            dayText = "昨天"
        } else if dayDiff < -1 {
            dayText = "逾期\(-dayDiff)天"
        } else if dayDiff <= 7 {
            dayText = "\(dayDiff)天后"
        } else {
            let f = DateFormatter()
            f.timeZone = displayTZ
            f.dateFormat = "M月d日"
            dayText = f.string(from: date)
        }

        // Time part (only for non-all-day tasks)
        if allDay {
            let icon = dayDiff < 0 ? "exclamationmark.circle" : "calendar"
            return (dayText, icon, dayDiff < 0)
        } else {
            let tf = DateFormatter()
            tf.timeZone = displayTZ
            tf.dateFormat = "HH:mm"
            let timeText = tf.string(from: date)
            let icon = dayDiff < 0 ? "exclamationmark.circle" : "clock"
            return ("\(dayText) \(timeText)", icon, dayDiff < 0)
        }
    }

    /// Parse various ISO 8601 date formats from TickTick.
    private static func parseDate(_ str: String) -> Date? {
        // TickTick format: "2026-07-21T16:00:00.000+0000"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        df.locale = Locale(identifier: "en_US_POSIX")
        if let d = df.date(from: str) { return d }

        // ISO 8601 with fractional seconds
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }

        // ISO 8601 without fractional seconds
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }

        return nil
    }
}
