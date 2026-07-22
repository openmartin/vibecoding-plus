import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var state: AppState
    @State private var svcFilter: ServiceLogFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "TRACE", title: "日志", subtitle: state.inlineStatus)

            logCard {
                InkSegmentedPicker(
                    selection: $svcFilter,
                    options: ServiceLogFilter.allCases,
                    label: { $0.label }
                )
                LogText(lines: filteredServiceLines)
                    .frame(maxWidth: .infinity)
                    .frame(height: 480)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(18)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)
    }

    private var filteredServiceLines: [String] {
        let lines = state.liveActivity.serviceLogLines
        switch svcFilter {
        case .all: return lines
        case .device: return lines.filter { $0.localizedCaseInsensitiveContains("设备") || $0.localizedCaseInsensitiveContains("device") }
        case .process: return lines.filter { $0.localizedCaseInsensitiveContains("STT") || $0.localizedCaseInsensitiveContains("服务") || $0.localizedCaseInsensitiveContains("error") }
        }
    }
}
