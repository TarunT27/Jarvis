import SwiftUI
import Charts
import JarvisCore

/// Overview observes the same Assistant instance as Chat. There are no network requests
/// or broker operations in this view; all metrics are projections of existing state.
struct DashboardView: View {
    @Bindable var assistant: Assistant
    @State private var range: ActivityRange = .week
    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selectedModel: String { assistant.deep ? Configuration.deep : Configuration.everyday }
    private var modelAvailable: Bool { assistant.models.contains(selectedModel) }
    private var activity: ConversationActivity {
        ConversationActivity(messages: assistant.messages, dayCount: range.rawValue)
    }
    private var recentMessages: [ChatMessage] {
        assistant.messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.created > $1.created }.prefix(5).map { $0 }
    }
    private var readiness: String {
        if !assistant.unlocked { return assistant.unlocking ? "Unlocking" : "Locked" }
        if assistant.recording { return "Listening" }
        if assistant.proposal != nil { return "Approval needed" }
        if assistant.busy { return "Working" }
        if assistant.error != nil { return "Needs attention" }
        return modelAvailable ? "Available" : "Not ready"
    }
    private var readinessColor: Color {
        if !assistant.unlocked { return JarvisTheme.warning }
        if assistant.error != nil || !modelAvailable { return JarvisTheme.warning }
        return assistant.recording ? JarvisTheme.recording : JarvisTheme.healthy
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    metrics(columns: dynamicTypeSize.isAccessibilitySize ? 1 : wide ? 4 : 2)
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            activityPanel.frame(maxWidth: .infinity)
                            recentPanel.frame(width: 320)
                        }
                    } else {
                        activityPanel
                        recentPanel
                    }
                    Label("Only data already in Jarvis. No analytics leave your Mac.", systemImage: "lock")
                        .font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
                }
                .padding(geometry.size.width < 650 ? 20 : 28)
                .frame(maxWidth: 1440)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(JarvisTheme.canvas)
        }
        .accessibilityIdentifier("overview")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                heading
                Spacer(minLength: 20)
                openChatButton
            }
            VStack(alignment: .leading, spacing: 16) { heading; openChatButton }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ON YOUR MAC", systemImage: "desktopcomputer")
                .font(JarvisTypography.font(.semibold, style: .caption2)).tracking(1.6).foregroundStyle(JarvisTheme.secondary)
            Text("Overview").font(JarvisTypography.font(.semibold, style: .largeTitle)).accessibilityAddTraits(.isHeader)
            Text("A quiet place to see where things stand.").foregroundStyle(JarvisTheme.secondary)
        }
    }

    private var openChatButton: some View {
        Button { assistant.selectedPage = "Chat" } label: {
            Label("Open chat", systemImage: "arrow.up.right")
        }
        .buttonStyle(.bordered).controlSize(.large)
        .accessibilityLabel("Open current chat")
        .accessibilityIdentifier("overview.open-chat")
    }

    private func metrics(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
            OverviewMetricCard(title: "Local system", value: readiness,
                detail: assistant.status, symbol: "checkmark.shield", tint: readinessColor)
                .overlay(alignment: .bottomTrailing) {
                    // Cancelling Touch ID used to leave the app stranded until relaunch.
                    if !assistant.unlocked {
                        Button(assistant.unlocking ? "Unlocking..." : "Unlock") {
                            Task { await assistant.unlock() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(assistant.unlocking)
                        .padding(12)
                        .accessibilityIdentifier("overview.unlock")
                    }
                }
            OverviewMetricCard(title: "Current local model", value: assistant.deep ? "Qwen3.8 · 27B" : "Qwen3.5 · 9B",
                detail: "\(assistant.deep ? "Deep" : "Everyday") · \(modelAvailable ? "installed" : "not installed")",
                symbol: "cpu", tint: JarvisTheme.information)
            OverviewMetricCard(title: "Conversation", value: assistant.messages.count.formatted(),
                detail: "Messages in the available conversation", symbol: "bubble.left.and.bubble.right", tint: JarvisTheme.information)
            OverviewMetricCard(title: "Approved access", value: (assistant.folders.count + assistant.apps.count).formatted(),
                detail: "\(assistant.folders.count) folders · \(assistant.apps.count) apps", symbol: "folder.badge.gearshape", tint: JarvisTheme.information)
        }
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) { activityHeading; Spacer(minLength: 20); rangePicker }
                VStack(alignment: .leading, spacing: 16) { activityHeading; rangePicker }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(activity.total.formatted()).contentTransition(.numericText()).animation(JarvisMotion.nudging(reduceMotion), value: activity.total).font(JarvisTypography.font(.semibold, style: .largeTitle).monospacedDigit()).monospacedDigit()
                Text("messages").font(JarvisTypography.font(.regular, style: .callout)).foregroundStyle(JarvisTheme.secondary)
                Spacer()
                if let selected = selectedDay {
                    Text("\(selected.date.formatted(.dateTime.month(.abbreviated).day())) · \(selected.count) messages")
                        .font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary).monospacedDigit()
                } else {
                    Text("\(activity.activeDays) active \(activity.activeDays == 1 ? "day" : "days")")
                        .font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
                }
            }.accessibilityElement(children: .combine)
            chart
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: activity.total == 0 ? "bubble.left" : "info.circle").accessibilityHidden(true)
                Text(activity.total == 0 ? "No messages in this range. Start a conversation to see activity here." : "Counts your messages and Jarvis replies by local date.")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
            Divider()
            Text("Based on the conversation currently available to the app, including up to 50 restored messages. A longer range does not recover expired history.")
                .font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .overviewPanel()
    }

    private var activityHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Message activity").font(JarvisTypography.font(.semibold, style: .headline)).accessibilityAddTraits(.isHeader)
            Text("The last \(range.rawValue) days").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
        }
    }

    private var rangePicker: some View {
        Picker("Activity range", selection: $range) {
            ForEach(ActivityRange.allCases) { range in Text("\(range.rawValue) days").tag(range) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 230)
        .accessibilityLabel("Activity date range")
        .accessibilityIdentifier("overview.activity-range")
        .onChange(of: range) { _, _ in selectedDate = nil }
    }

    private var selectedDay: ConversationActivity.Day? {
        guard let selectedDate else { return nil }
        return activity.days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var chart: some View {
        Chart {
            ForEach(activity.days) { day in
                AreaMark(x: .value("Date", day.date), y: .value("Messages", day.count))
                    .foregroundStyle(LinearGradient(colors: [JarvisTheme.information.opacity(0.20), JarvisTheme.information.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                    .accessibilityHidden(true)
                LineMark(x: .value("Date", day.date), y: .value("Messages", day.count))
                    .foregroundStyle(JarvisTheme.information).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.linear)
                    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                    .accessibilityValue("\(day.count) messages")
                if day.count > 0 {
                    PointMark(x: .value("Date", day.date), y: .value("Messages", day.count))
                        .foregroundStyle(JarvisTheme.information).symbolSize(24).accessibilityHidden(true)
                }
            }
            if let day = selectedDay {
                RuleMark(x: .value("Selected day", day.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).accessibilityHidden(true)
            }
        }
        .chartXScale(domain: (activity.days.first?.date ?? Date())...(activity.days.last?.date ?? Date()), range: .plotDimension(padding: 8))
        .chartYScale(domain: 0...max(4, (activity.days.map(\.count).max() ?? 0) + 1))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : range == .month ? 7 : 21)) { value in
                AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(count.formatted()).font(JarvisTypography.font(.regular, style: .caption2)).foregroundStyle(JarvisTheme.secondary) }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 200)
        .accessibilityLabel("Message activity over the last \(range.rawValue) days")
        .accessibilityValue("\(activity.total) messages across \(activity.activeDays) active \(activity.activeDays == 1 ? "day" : "days"). Available conversation only.")
        .accessibilityIdentifier("overview.activity-chart")
        .animation(JarvisMotion.settling(reduceMotion), value: range)
    }

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent activity").font(JarvisTypography.font(.semibold, style: .headline)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Latest \(recentMessages.count)").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
            }
            if recentMessages.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Your latest messages will appear here.")
                } actions: {
                    Button("Start a conversation") { assistant.selectedPage = "Chat" }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                ForEach(recentMessages) { message in
                    RecentMessageRow(message: message)
                    if message.id != recentMessages.last?.id { Divider() }
                }
                Button("Continue in Chat", systemImage: "arrow.right") { assistant.selectedPage = "Chat" }
                    .buttonStyle(.borderless).font(JarvisTypography.font(.medium, style: .callout))
                    .accessibilityIdentifier("overview.continue-chat")
            }
        }
        .overviewPanel()
    }
}

private enum ActivityRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
}

struct OverviewMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(JarvisTypography.font(.regular, style: .subheadline)).foregroundStyle(JarvisTheme.secondary)
                Spacer(minLength: 8)
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(value).font(JarvisTypography.font(.semibold, style: .title2)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(JarvisMotion.nudging(reduceMotion), value: value)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(detail).font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary).lineLimit(2)
                .frame(minHeight: 30, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overviewPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value). \(detail)")
        .help("\(title): \(value). \(detail)")
    }
}

private struct RecentMessageRow: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if message.role == "user" {
                    Image(systemName: "person.crop.circle").font(.system(size: 24, weight: .light)).foregroundStyle(JarvisTheme.secondary)
                } else { JarvisMark().frame(width: 24, height: 24) }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(message.role == "user" ? "You" : "Jarvis").font(JarvisTypography.font(.medium, style: .subheadline))
                    Spacer()
                    Text(message.created, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(JarvisTypography.font(.regular, style: .caption2)).foregroundStyle(JarvisTheme.secondary)
                }
                Text(message.content).font(JarvisTypography.font(.regular, style: .callout)).foregroundStyle(JarvisTheme.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewPanel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20)
            .background(JarvisTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(JarvisTheme.border, lineWidth: 1) }
    }
}

private extension View {
    func overviewPanel() -> some View { modifier(OverviewPanel()) }
}
