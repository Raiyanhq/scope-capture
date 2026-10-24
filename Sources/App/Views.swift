import SwiftUI
import UIKit

private enum ScopeUI {
    static let agreementKey = ScopeRelease.agreementKey

    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.85, blue: 0.76, alpha: 1)
            : UIColor(red: 0.02, green: 0.38, blue: 0.34, alpha: 1)
    })

    static func time(_ seconds: Double) -> String {
        let n = seconds.isFinite ? max(0, Int(seconds)) : 0
        return n >= 3600
            ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%02d:%02d", n / 60, n % 60)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: value,
            countStyle: .file
        )
    }

    static func link(_ key: String) -> URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: text),
              url.scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}

private struct ScopePrimaryButton: View {
    let title: String
    let symbol: String
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: symbol)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .disabled(disabled || busy)
    }
}

private struct ScopeMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScopeDashboardIntro: View {
    let ready: Bool
    let sensorCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("ON-DEVICE RESEARCH", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold)).tracking(1)
                Spacer()
                Image(systemName: "lock.shield").accessibilityLabel("Stored locally")
            }
            .foregroundStyle(.secondary)
            Text("Your next\nobservation starts here.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: ready ? "checkmark.circle.fill" : "slider.horizontal.3")
                Text(ready ? "Ready · \(sensorCount) sensors selected" : "Choose sensors to get started")
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.tint)
            HStack(spacing: 16) {
                Label("Local storage", systemImage: "internaldrive")
                Label("Named exports", systemImage: "square.and.arrow.up")
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 44, height: 3).padding(.top, 1)
                .accessibilityHidden(true)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var wired: WiredAccessoryController
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(ScopeUI.agreementKey)
    private var accepted = false

    var body: some View {
        Group {
            if accepted {
                TabView(selection: $model.selectedTab) {
                    NavigationStack {
                        ScopeRecordScreen(
                            showAgreement: {
                                accepted = false
                            }
                        )
                    }
                    .tabItem {
                        Label("Home", systemImage: "house")
                    }
                    .tag(0)

                    NavigationStack {
                        ScopeSessionsScreen()
                    }
                    .tabItem {
                        Label("Sessions", systemImage: "tray.full")
                    }
                    .tag(1)

                    NavigationStack {
                        ScopeSensorsScreen()
                    }
                    .tabItem {
                        Label(
                            "Sensors",
                            systemImage: "slider.horizontal.3"
                        )
                    }
                    .tag(2)

                    NavigationStack {
                        ResearchView()
                    }
                    .tabItem {
                        Label(
                            "Research",
                            systemImage: "waveform.path.ecg"
                        )
                    }
                    .tag(3)

                    NavigationStack { DevicesView() }
                        .tabItem { Label("Devices", systemImage: "cable.connector") }
                        .tag(4)
                }
            } else {
                NavigationStack {
                    ScopeWelcomeScreen {
                        UserDefaults.standard.set(
                            Date().timeIntervalSince1970,
                            forKey: "scope.agreementAcceptedAt"
                        )

                        UserDefaults.standard.set(
                            ScopeRelease.policyVersion,
                            forKey: "scope.agreementVersion"
                        )

                        accepted = true
                    }
                }
            }
        }
        .environmentObject(model.hub)
        .tint(ScopeUI.accent)
        .task {
            if !(0...4).contains(model.selectedTab) {
                model.selectedTab = 0
            }

            await model.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            model.sceneChanged(phase)
            if phase != .active && (wired.capturing || wired.connectedID != nil) {
                wired.stop(reason: "App left the foreground. Capture stopped; reconnect before continuing.")
            }
        }
        .alert(item: $model.message) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.detail),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(
            item: $model.exportItem,
            onDismiss: model.exportDismissed
        ) { item in
            ExportView(url: item.url)
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ScopeRecordScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sensors: SensorHub
    @AppStorage(ScopeUI.agreementKey) private var accepted = false

    let showAgreement: () -> Void

    @State private var setup = false
    @State private var settings = false
    @State private var stop = false
    @State private var marker = false
    @State private var markerText = ""

    private var ready: Bool {
        !sensors.enabled.isEmpty
            && sensors.enabled.allSatisfy { sensors.ready($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let session = model.active {
                    VStack(spacing: 18) {
                        Label(
                            model.status,
                            systemImage: model.paused
                                ? "pause.circle.fill"
                                : "record.circle"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(
                            model.paused ? Color.orange : ScopeUI.accent
                        )

                        Text(session.experiment)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)

                        Text(ScopeUI.time(model.elapsed))
                            .font(
                                .system(
                                    size: 64,
                                    weight: .light,
                                    design: .monospaced
                                )
                            )
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .accessibilityLabel(
                                "Elapsed time, \(ScopeUI.time(model.elapsed))"
                            )

                        Text(
                            model.paused
                                ? "Paused · elapsed time continues"
                                : "Keep SCOPE open while recording"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        HStack {
                            ScopeMetric(
                                value: session.totalSamples.formatted(),
                                title: "Saved samples"
                            )
                            ScopeMetric(
                                value: ScopeUI.bytes(session.totalBytes),
                                title: "On device"
                            )
                        }
                        .padding(.top, 8)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 24)
                    )

                    HStack(spacing: 12) {
                        Button {
                            model.paused ? model.resume() : model.pause()
                        } label: {
                            Label(
                                model.paused ? "Resume" : "Pause",
                                systemImage: model.paused
                                    ? "play.fill"
                                    : "pause.fill"
                            )
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            markerText = ""
                            marker = true
                        } label: {
                            Label("Mark event", systemImage: "flag")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(model.busy)

                    VStack(spacing: 16) {
                        ForEach(session.selected) { sensor in
                            HStack {
                                Label(
                                    sensor.title,
                                    systemImage: sensor.symbol
                                )
                                Spacer()
                                Text(session.count(sensor).formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }

                        Text("Saved counts refresh every few seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20)
                    )

                    if session.warningCount > 0 {
                        Label(
                            "\(session.warningCount) warnings · review after saving",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                } else {
                    ScopeDashboardIntro(ready: ready, sensorCount: sensors.enabled.count)

                    HStack(spacing: 12) {
                        Button { model.selectedTab = 3 } label: {
                            Label("IMU research", systemImage: "waveform.path.ecg")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        Button { model.selectedTab = 4 } label: {
                            Label("Devices", systemImage: "cable.connector")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .font(.subheadline.weight(.medium)).buttonStyle(.bordered)

                    Button {
                        model.selectedTab = 2
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title2)
                                .foregroundStyle(ScopeUI.accent)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    sensors.enabled.isEmpty
                                        ? "Choose your sensors"
                                        : "\(sensors.enabled.count) sensors selected"
                                )
                                .font(.headline)
                                .foregroundStyle(.primary)

                                Text(
                                    ready
                                        ? "Ready to record"
                                        : "Set up before recording"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                    }
                    .buttonStyle(.plain)

                    HStack {
                        ScopeMetric(
                            value: model.sessions.count.formatted(),
                            title: "Sessions"
                        )
                        ScopeMetric(
                            value: model.storageText,
                            title: "Available storage"
                        )
                    }
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                    if let latest = model.sessions.first(
                        where: { $0.id != model.active?.id }
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RECENT RECORDING")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            NavigationLink {
                                ScopeSessionScreen(id: latest.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(latest.experiment)
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text(
                                            latest.startedAt.formatted(
                                                date: .abbreviated,
                                                time: .shortened
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(20)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("SCOPE Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.selectedTab = 4
                } label: {
                    Image(
                        systemName: "cable.connector"
                    )
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("External device setup")
                .disabled(model.active != nil || model.busy)

                Button {
                    settings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if model.active != nil {
                    ScopePrimaryButton(
                        title: model.busy ? "Saving…" : "Finish & save",
                        symbol: "stop.fill",
                        busy: model.busy
                    ) {
                        stop = true
                    }
                } else {
                    ScopePrimaryButton(
                        title: !accepted
                            ? "Review & continue"
                            : ready ? "New session" : "Choose sensors",
                        symbol: ready ? "record.circle" : "slider.horizontal.3",
                        busy: model.busy,
                        disabled: sensors.requesting != nil || !model.canStart
                    ) {
                        if !accepted {
                            showAgreement()
                        } else if ready {
                            setup = true
                        } else {
                            model.selectedTab = 2
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .sheet(isPresented: $setup) {
            ScopeSetupScreen()
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                ScopePreferencesScreen()
            }
        }
        .confirmationDialog(
            "Finish this recording?",
            isPresented: $stop,
            titleVisibility: .visible
        ) {
            Button("Finish & save") {
                Task { await model.finish() }
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("You can review and export it from Sessions.")
        }
        .alert("Mark event", isPresented: $marker) {
            TextField("Event label", text: $markerText)

            Button("Save") {
                model.marker(markerText)
            }
            .disabled(
                markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || markerText.count > 240
                    || model.busy
                    || model.active == nil
            )

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds a timestamped note. Use up to 240 characters.")
        }
    }
}

private struct ScopeSetupScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sensors: SensorHub
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var participant = ""
    @State private var protocolCode = ""
    @State private var notes = ""
    @State private var duration = 0
    @State private var awake = true
    @State private var error: String?

    private var selected: [Sensor] {
        Sensor.allCases.filter { sensors.enabled.contains($0) }
    }

    private var valid: Bool {
        model.canStart
            && !selected.isEmpty
            && selected.allSatisfy { sensors.ready($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recording title", text: $title)

                    NavigationLink {
                        ScopeSensorsScreen()
                    } label: {
                        LabeledContent(
                            "Sensors",
                            value: "\(selected.count) selected"
                        )
                    }
                }

                Section {
                    Picker("Duration", selection: $duration) {
                        Text("Until stopped").tag(0)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                    }

                    Toggle("Keep screen awake", isOn: $awake)
                } footer: {
                    Text("Leaving SCOPE pauses recording. Timed sessions include pauses.")
                }

                Section {
                    DisclosureGroup("Study details", content: {
                        TextField("Protocol code", text: $protocolCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Participant code", text: $participant)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(3...6)

                        Text("Optional. Use participant codes rather than names.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    })
                }
            }
            .navigationTitle("New recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(model.busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ScopePrimaryButton(
                    title: model.busy ? "Starting…" : "Start recording",
                    symbol: "record.circle",
                    busy: model.busy,
                    disabled: !valid
                ) {
                    Task {
                        do {
                            let name = title.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )

                            try await model.start(
                                experiment: name.isEmpty ? "Recording" : name,
                                participant: participant,
                                notes: notes,
                                protocolCode: protocolCode,
                                selected: selected,
                                plannedSeconds: duration == 0
                                    ? nil
                                    : Double(duration),
                                keepAwake: awake
                            )
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .padding(20)
                .background(.regularMaterial)
            }
            .onAppear {
                if title.isEmpty {
                    title = "Recording · " + Date().formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                }
            }
            .interactiveDismissDisabled(model.busy)
            .alert(
                "Unable to start",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                )
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }
}

private struct ScopeSensorsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sensors: SensorHub
    @AppStorage(ScopeUI.agreementKey) private var accepted = false
    @State private var info: Sensor?

    var body: some View {
        List {
            if !accepted {
                Section {
                    Text("Review the agreement from Record before enabling sensors.")
                }
            }

            if model.active != nil {
                Section {
                    Label(
                        "Selection locked during recording",
                        systemImage: "lock"
                    )
                }
            }

            Section {
                ForEach(Sensor.allCases) { sensor in
                    HStack(spacing: 12) {
                        Image(systemName: sensor.symbol)
                            .font(.title3)
                            .foregroundStyle(ScopeUI.accent)
                            .frame(width: 28)

                        Toggle(
                            isOn: Binding(
                                get: { sensors.enabled.contains(sensor) },
                                set: { sensors.setEnabled(sensor, to: $0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sensor.title)
                                    .font(.body.weight(.medium))

                                if sensors.requesting == sensor {
                                    Text("Waiting for permission…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if !sensors.available.contains(sensor)
                                    || (
                                        sensors.enabled.contains(sensor)
                                            && !sensors.ready(sensor)
                                    ) {
                                    Text(sensors.permissionText(sensor))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        sensors.enabled.contains(sensor)
                                            ? "Selected"
                                            : "Available"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(
                            !accepted
                                || model.active != nil
                                || model.busy
                                || sensors.requesting != nil
                                || (
                                    !sensors.available.contains(sensor)
                                        && !sensors.enabled.contains(sensor)
                                )
                        )

                        Button {
                            info = sensor
                        } label: {
                            Image(systemName: "info.circle")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("About \(sensor.title)")
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                Text("\(sensors.enabled.count) selected")
            } footer: {
                Text("Access is requested when needed. Your selection is saved.")
            }

            if let message = sensors.setupMessage {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("Sensors")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings") {
                    if let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .onAppear {
            sensors.refreshPermissions()
        }
        .refreshable {
            sensors.refreshPermissions()
        }
        .sheet(item: $info) { sensor in
            NavigationStack {
                List {
                    Section {
                        Label(
                            sensor.title,
                            systemImage: sensor.symbol
                        )
                        .font(.title2.weight(.semibold))

                        Text(sensor.detail)
                    }

                    Section {
                        Text(sensors.permissionText(sensor))
                    }

                    if let hz = sensor.requestedHz {
                        Section {
                            LabeledContent(
                                "Requested rate",
                                value: "\(Int(hz)) Hz"
                            )
                        }
                    }

                    Section {
                        Text("Selecting a sensor prepares access. Measurements are saved only after you start a recording.")
                    }
                }
                .navigationTitle("Sensor information")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { info = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ScopeSessionsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var newestFirst = true
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All", shareable = "Exportable", review = "Review"
        var id: String { rawValue }
    }

    private var sessions: [ResearchSession] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.sessions.filter {
            $0.id != model.active?.id
                && (filter == .all || (filter == .shareable && $0.state.exportable)
                    || (filter == .review && ($0.needsReview || $0.state.recoverable)))
                && (
                    search.isEmpty
                        || [
                            $0.experiment,
                            $0.participant,
                            $0.protocolCode ?? "",
                            $0.id.uuidString,
                            ($0.externalFiles ?? []).map { $0.device.name }.joined(separator: " ")
                        ].contains {
                            $0.localizedCaseInsensitiveContains(search)
                        }
                )
        }.sorted { newestFirst ? $0.startedAt > $1.startedAt : $0.startedAt < $1.startedAt }
    }

    var body: some View {
        List {
            if !model.catalogIssues.isEmpty {
                DisclosureGroup("Some recordings need attention") {
                    ForEach(model.catalogIssues, id: \.self) {
                        Text($0)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                    Text("Keep the app installed to preserve its files.")
                        .font(.footnote)
                }
            }

            ForEach(sessions) { session in
                NavigationLink {
                    ScopeSessionScreen(id: session.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform.path")
                            .foregroundStyle(ScopeUI.accent)
                            .frame(width: 42, height: 48)
                            .background(
                                ScopeUI.accent.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12)
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.experiment)
                                .font(.headline)
                                .lineLimit(2)

                            Text(
                                session.startedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Text(
                                "\(ScopeUI.time(session.duration)) · \(session.state.title)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        if session.needsReview || session.state.recoverable {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Review needed")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        renameID = session.id; renameText = session.experiment; showRename = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    .tint(.teal).disabled(model.busy || model.active != nil)
                    Button { Task { await model.export(session.id) } } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue).disabled(model.busy || model.active != nil || !session.state.exportable)
                }
            }
        }
        .overlay {
            if sessions.isEmpty && model.catalogIssues.isEmpty {
                ContentUnavailableView(
                    model.sessions.isEmpty ? "Your recordings live here" : "No matching recordings",
                    systemImage: "waveform.path",
                    description: Text(
                        model.sessions.isEmpty
                            ? "Finish a recording to review and share it."
                            : "Try another filter, title, study code or device name."
                    )
                )
            }
        }
        .navigationTitle("Sessions")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Filter recordings", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newestFirst = true } label: {
                        Label("Newest first", systemImage: newestFirst ? "checkmark" : "clock")
                    }
                    Button { newestFirst = false } label: {
                        Label("Oldest first", systemImage: newestFirst ? "clock" : "checkmark")
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort recordings")
            }
        }
        .alert("Rename session", isPresented: $showRename) {
            TextField("Session name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = renameID { Task { await model.rename(id, title: renameText) } }
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText.count > 120)
        } message: { Text("Your exported ZIP will use this name.") }
        .searchable(text: $query, prompt: "Search recordings")
        .refreshable {
            await model.refresh()
        }
        .task {
            await model.refresh()
        }
    }
}

private struct ScopeSessionScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let id: UUID

    @State private var deleting = false
    @State private var recovering = false
    @State private var renaming = false
    @State private var sessionName = ""

    private var session: ResearchSession? {
        model.sessions.first { $0.id == id }
    }

    var body: some View {
        List {
            if let session {
                Section {
                    Text(session.experiment)
                        .font(.title2.weight(.bold))

                    Text(
                        session.startedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .foregroundStyle(.secondary)

                    Label(
                        session.state.title,
                        systemImage: session.state.exportable
                            ? "checkmark.circle"
                            : "exclamationmark.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(ScopeUI.accent)

                    HStack {
                        ScopeMetric(
                            value: ScopeUI.time(session.duration),
                            title: session.recovered
                                ? "Known duration"
                                : "Duration"
                        )
                        ScopeMetric(
                            value: ScopeUI.bytes(session.totalBytes),
                            title: "Data size"
                        )
                    }
                    .padding(.vertical, 8)
                }

                if session.needsReview {
                    Section {
                        Label(
                            "Review sensor results and events before analysis.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    }
                }

                Section {
                    DisclosureGroup(
                        "Sensor results · \(session.totalSamples.formatted()) samples"
                    ) {
                        ForEach(session.selected) { sensor in
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent(
                                    sensor.title,
                                    value: session.count(sensor).formatted()
                                )

                                if let summary = session.summary(sensor),
                                   sensor.requestedHz != nil,
                                   let hz = summary.averageHz {
                                    Text(
                                        String(
                                            format: "%.2f Hz observed · %.3f s largest gap",
                                            hz,
                                            summary.largestGapSeconds
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Text("Observed rates include pauses. Event-based sensors may report infrequently. Step counts accumulate within each collector run; do not sum every row.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink("Events & files") {
                        ScopeEvidenceScreen(session: session)
                    }

                    if let external = session.externalFiles, !external.isEmpty {
                        DisclosureGroup("External files · \(external.count)") {
                            ForEach(external) { file in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.originalName).font(.subheadline.weight(.medium))
                                    Text("\(file.device.name) · \(ScopeUI.bytes(file.bytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("SHA-256: \(file.sha256)").font(.caption2.monospaced()).textSelection(.enabled)
                                }.padding(.vertical, 4)
                            }
                        }
                    }

                    DisclosureGroup("Study & device details") {
                        if let code = session.protocolCode, !code.isEmpty {
                            LabeledContent("Protocol", value: code)
                        }

                        if !session.participant.isEmpty {
                            LabeledContent(
                                "Participant",
                                value: session.participant
                            )
                        }

                        if !session.notes.isEmpty {
                            Text(session.notes)
                                .textSelection(.enabled)
                        }

                        LabeledContent("Device", value: session.device)
                        LabeledContent("iOS", value: session.osVersion)
                        LabeledContent("App", value: session.appVersion)
                        LabeledContent(
                            "Data format",
                            value: "\(session.schemaVersion)"
                        )

                        Text(session.id.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if model.active != nil {
                    Section {
                        Text("Finish the active recording to export or recover this session.")
                            .font(.footnote)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Recording unavailable",
                    systemImage: "tray"
                )
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sessionName = session?.experiment ?? ""
                        renaming = true
                    } label: { Label("Rename session", systemImage: "pencil") }
                    .disabled(model.busy || model.active != nil || session == nil)

                    Button {
                        model.selectedTab = 4
                    } label: { Label("Add external files", systemImage: "cable.connector") }
                    .disabled(model.busy || model.active != nil)

                    Button("Delete recording", role: .destructive) {
                        deleting = true
                    }
                    .disabled(
                        model.busy
                            || model.active != nil
                            || session == nil
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Recording actions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let session {
                ScopePrimaryButton(
                    title: model.busy
                        ? "Preparing…"
                        : session.state.recoverable
                            ? "Recover recording"
                            : "Export ZIP",
                    symbol: session.state.recoverable
                        ? "arrow.counterclockwise"
                        : "square.and.arrow.up",
                    busy: model.busy,
                    disabled: model.active != nil
                        || (
                            !session.state.exportable
                                && !session.state.recoverable
                        )
                ) {
                    if session.state.recoverable {
                        recovering = true
                    } else {
                        Task { await model.export(id) }
                    }
                }
                .padding(20)
                .background(.regularMaterial)
            }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Session name", text: $sessionName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await model.rename(id, title: sessionName) } }
                .disabled(sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionName.count > 120)
        } message: {
            Text("The new name will also be used for your exported ZIP.")
        }
        .confirmationDialog(
            "Recover saved data?",
            isPresented: $recovering,
            titleVisibility: .visible
        ) {
            Button("Recover") {
                Task { await model.recover(id) }
            }
        } message: {
            Text("Original evidence is retained. Unwritten measurements cannot be restored.")
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $deleting,
            titleVisibility: .visible
        ) {
            Button("Delete recording", role: .destructive) {
                Task {
                    await model.delete(id)
                    if !model.sessions.contains(where: { $0.id == id }) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This removes the local recording permanently. Exported copies are not affected.")
        }
    }
}

private struct ScopeEvidenceScreen: View {
    let session: ResearchSession

    var body: some View {
        List {
            Section("Events") {
                ForEach(
                    Array(session.events.enumerated()),
                    id: \.offset
                ) { _, event in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            event.kind
                                .replacingOccurrences(of: "_", with: " ")
                                .capitalized,
                            systemImage: event.isWarning
                                ? "exclamationmark.triangle"
                                : "clock"
                        )
                        .font(.subheadline.weight(.semibold))

                        Text(event.detail)
                            .font(.subheadline)

                        Text(
                            event.time.formatted(
                                date: .abbreviated,
                                time: .standard
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let elapsed = event.elapsedSeconds {
                            Text(String(format: "+%.3f seconds", elapsed))
                                .font(.caption.monospaced())
                        }

                        if let count = event.count {
                            Text("\(count) occurrences")
                                .font(.caption)
                        }

                        if let sensor = event.sensor {
                            Text(sensor.title)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                }
            }

            Section("Files") {
                ForEach(session.files) { file in
                    DisclosureGroup(file.path) {
                        Text(
                            "\(file.samples.formatted()) rows · \(ScopeUI.bytes(file.bytes))"
                        )

                        Text(
                            file.sha256.isEmpty
                                ? "Fingerprint pending recovery"
                                : "SHA-256: " + file.sha256
                        )
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    }
                    .font(.subheadline)
                }
            }
        }
        .navigationTitle("Events & files")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ScopeSettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sensors: SensorHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Label(
                    "SCOPE Capture",
                    systemImage: "waveform.path"
                )
                .font(.title2.weight(.semibold))

                Text("Scientific Collection & Observation Platform for Experiments")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LabeledContent(
                    "Version",
                    value: (
                        Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String
                    ) ?? "—"
                )
            }

            Section("This device") {
                LabeledContent("Type", value: sensors.deviceDescription)
                LabeledContent("Hardware code", value: sensors.hardwareModel)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Available space", value: model.storageText)

                DisclosureGroup("About device information") {
                    Text("Hardware codes are identifiers, not retail model names. Available space is reported by iOS for app writes and may include reclaimable storage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink("Recording guide") {
                    ScopeGuideScreen()
                }

                NavigationLink("Privacy & terms") {
                    ScopeLegalScreen()
                }

                if let url = ScopeUI.link("ResearchSupportURL") {
                    Link("Contact support", destination: url)
                }

                if let url = ScopeUI.link("ResearchPrivacyPolicyURL") {
                    Link("Published privacy policy", destination: url)
                }

                if let url = ScopeUI.link("ResearchTermsURL") {
                    Link("Published terms", destination: url)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .refreshable {
            await model.refresh()
        }
    }
}

private struct ScopeGuideScreen: View {
    var body: some View {
        List {
            Section("Record") {
                Text("Choose sensors, then start a recording. Keep SCOPE open. Leaving the app or locking the device pauses collection; return and tap Resume. The elapsed timer includes pauses.")
            }

            Section("Review") {
                Text("Saved counts update at disk checkpoints. Actual sensor rates vary. Review events and sensor results before analysis. Relative altitude and step counts restart with each collector run.")
            }

            Section("Export") {
                Text("Open a saved session and tap Export ZIP. Files are checked before export. Choose Save to Files or Share. The ZIP is not encrypted; use a destination approved for your study.")
            }

            Section("Preserve") {
                Text("Recordings are excluded from automatic device backups. Export important work. Recovery retains available saved evidence but cannot reconstruct unwritten samples. Legacy exports omit raw device uptime; originals remain on this phone.")
            }
        }
        .navigationTitle("Recording guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ScopeAgreementScreen: View {
    @Environment(\.dismiss) private var dismiss
    let accept: () -> Void

    var body: some View {
        NavigationStack {
            ScopeLegalScreen()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not now") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        Text("By continuing, you agree to the terms and acknowledge the privacy notice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        ScopePrimaryButton(
                            title: "Agree & continue",
                            symbol: "checkmark",
                            action: accept
                        )
                    }
                    .padding(20)
                    .background(.regularMaterial)
                }
        }
        .interactiveDismissDisabled()
    }
}

private struct ScopeLegalScreen: View {
    private let sections: [(String, String)] = [
        (
            "Your data stays with you",
            "SCOPE Capture records selected device sensors and saves sessions locally. This version has no account, developer-operated upload, advertising, tracking, or analytics service. Recording works offline."
        ),
        (
            "What is stored",
            "Sessions contain selected measurements, timestamps, study details, participant codes, notes, event markers, device information, and app version. Location is included only when selected and permitted. Sensor choices and your agreement version and acceptance time are stored in app preferences."
        ),
        (
            "Permissions and control",
            "You choose sensors before recording. iOS requests access when needed; several sensors share Motion & Fitness permission. Setup checks may briefly access motion, recent activity, steps, or altitude. Check results are discarded, not saved as research data. You can change permissions in iOS Settings. Selecting a sensor does not begin a saved recording."
        ),
        (
            "Storage and deletion",
            "Session files use the app’s private storage and iOS file protection. They remain until deleted or the app is removed. The recording folder is excluded from automatic device backups. Export important sessions. Deletion is permanent and does not remove copies you have already shared."
        ),
        (
            "Export and sharing",
            "Export checks recorded files and creates a temporary, unencrypted ZIP. You choose where to save or send it. Files may include participant codes, notes, timestamps, and location. Receiving services apply their own terms and privacy practices. Temporary ZIPs are removed when the export screen closes or the app next starts; original recordings are retained."
        ),
        (
            "Responsible research",
            "Use SCOPE only for information you are authorized to collect. Obtain required participant consent and institutional approval before recording. Use participant codes and collect only what your protocol requires. Do not conduct undisclosed tracking or monitoring. Agreeing here and granting iOS access do not constitute research participant consent."
        ),
        (
            "Measurement limits",
            "SCOPE is a general-purpose observation tool, not a medical diagnostic device or a calibration service. Validate your device and protocol before research use. Sensor availability, rates, timing, and accuracy vary. Keep the app open: locking the phone or leaving SCOPE pauses acquisition. Timed sessions include pauses and may finalize late if iOS suspends the app."
        ),
        (
            "Data integrity",
            "Review warnings, gaps, empty streams, and recovered-session labels before analysis. File fingerprints help detect changes relative to a manifest; they do not certify scientific validity, identity, or authorship. Device failure, battery loss, storage pressure, or force termination can cause loss. Recovery cannot restore measurements that were never saved."
        ),
        (
            "Terms and support",
            "Use the app lawfully and follow your study’s retention and security requirements. Any software license provided with the app continues to apply. These terms do not limit rights that cannot be limited under applicable law. For protocol questions contact your study lead; for app questions use the provider’s published support details. Future data-handling changes will be described in an updated notice."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "hand.raised")
                        .font(.largeTitle)
                        .foregroundStyle(ScopeUI.accent)

                    Text("Research with care.")
                        .font(.largeTitle.weight(.bold))

                    Text("Privacy notice & terms of use\nUpdated September 16, 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(sections, id: \.0) { title, body in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline)

                        Text(body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if let url = ScopeUI.link("ResearchSupportURL") {
                    Link("Contact app support", destination: url)
                }
            }
            .padding(24)
            .frame(maxWidth: 650, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Privacy & terms")
        .navigationBarTitleDisplayMode(.inline)
    }
}
