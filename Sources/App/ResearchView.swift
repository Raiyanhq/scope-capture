//
//  ResearchView.swift
//  SCOPECaptureCore
//
//  Created by MD. Raiyan Haque on 9/17/26.
//

import Foundation
import SwiftUI
import Charts

@MainActor
struct ResearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hub: SensorHub

    @State private var study = "IMU research"
    @State private var participant = ""
    @State private var placement = "Chest"
    @State private var attachment = "Handheld"
    @State private var orientation = "Not specified"

    @State private var starting = false
    @State private var confirmFinish = false
    @State private var markerCount = 0

    @State private var acceleration: [ResearchPoint] = []
    @State private var rotation: [ResearchPoint] = []
    @State private var latest: [Sensor: SampleRow] = [:]
    @State private var now: Double = 0

    private let requiredSensors: [Sensor] = [
        .accelerometer,
        .gyroscope
    ]

    private let placements = [
        "Chest",
        "Left arm",
        "Right arm",
        "Left wrist",
        "Right wrist",
        "Other"
    ]

    private var researchActive: Bool {
        model.active?.protocolCode == "SCOPE_IMU_V1"
    }

    private var ready: Bool {
        requiredSensors.allSatisfy {
            hub.enabled.contains($0) && hub.ready($0)
        }
    }

    private var canBegin: Bool {
        model.canStart
            && ready
            && !starting
            && !study.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && !participant.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && study.count <= 120
            && participant.count <= 80
    }

    var body: some View {
        List {
            if researchActive {
                recordingSection
                liveSection
            } else if model.active != nil {
                Section {
                    Label(
                        "Another session is recording",
                        systemImage: "record.circle"
                    )

                    Button("Open recording") {
                        model.selectedTab = 0
                    }
                }
            } else {
                setupSection
                placementSection
                sensorSection

                Section {
                    Button(action: begin) {
                        HStack {
                            if starting {
                                ProgressView()
                            }

                            Label(
                                "Start research session",
                                systemImage: "record.circle"
                            )
                            .fontWeight(.semibold)
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 36
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canBegin)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(
                        "Keep SCOPE open. Leaving the app pauses acquisition. " +
                        "For tomorrow’s demonstration, record ordinary movement; " +
                        "do not stage a fall."
                    )
                }
            }

            Section {
                Label(
                    "Apple comparison unavailable",
                    systemImage: "applewatch"
                )

                Text(
                    "Apple Watch integration has not been added. " +
                    "These sessions contain no Apple fall-detection results."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    model.selectedTab = 1
                } label: {
                    Label(
                        "Saved sessions & export",
                        systemImage: "tray.full"
                    )
                }

                DisclosureGroup("About this dataset") {
                    Text(
                        "Records separate accelerometer and gyroscope streams " +
                        "at a requested 100 Hz. Actual sampling can vary. " +
                        "The manifest records setup, timestamps, interruptions " +
                        "and quality information. ZIP export uses the existing " +
                        "verified export workflow."
                    )

                    Text(
                        "Accelerometer values include gravity and use g. " +
                        "Gyroscope values use rad/s. The live charts show " +
                        "a reduced preview, not every recorded sample."
                    )

                    Text(
                        "Reference markers record a button press, not a " +
                        "confirmed activity or a detector prediction. " +
                        "Independent research labels and model evaluation " +
                        "are performed after export. This page does not " +
                        "detect falls or provide emergency assistance."
                    )
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Research")
        .disabled(starting)
        .confirmationDialog(
            "Finish this research session?",
            isPresented: $confirmFinish,
            titleVisibility: .visible
        ) {
            Button("Finish & save") {
                Task {
                    await model.finish()
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The session will appear in Sessions, " +
                "ready for review and export."
            )
        }
        .task(id: model.active?.id) {
            acceleration = []
            rotation = []
            latest = [:]
            markerCount = 0

            while !Task.isCancelled {
                updatePreview()

                do {
                    try await Task.sleep(
                        for: .milliseconds(100)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private var setupSection: some View {
        Section {
            TextField(
                "Study title",
                text: $study
            )

            TextField(
                "Participant code",
                text: $participant
            )
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        } header: {
            Text("Session")
        } footer: {
            Text(
                "Use a research code, not a participant’s name."
            )
        }
    }

    private var placementSection: some View {
        Section {
            HStack(spacing: 24) {
                Image(systemName: "figure.stand")
                    .font(
                        .system(
                            size: 100,
                            weight: .ultraLight
                        )
                    )
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    Text("Phone placement")
                        .font(.headline)

                    Text(placement)
                        .foregroundStyle(.secondary)

                    Text(
                        "Select the participant’s side below."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .padding(.vertical, 8)

            Picker(
                "Position",
                selection: $placement
            ) {
                ForEach(placements, id: \.self) {
                    Text($0).tag($0)
                }
            }

            Picker(
                "Attachment",
                selection: $attachment
            ) {
                ForEach(
                    [
                        "Handheld",
                        "Secured",
                        "Pocket",
                        "Other"
                    ],
                    id: \.self
                ) {
                    Text($0).tag($0)
                }
            }

            Picker(
                "Initial orientation",
                selection: $orientation
            ) {
                ForEach(
                    [
                        "Not specified",
                        "Portrait upright",
                        "Portrait inverted",
                        "Landscape left",
                        "Landscape right",
                        "Screen up",
                        "Screen down"
                    ],
                    id: \.self
                ) {
                    Text($0).tag($0)
                }
            }
        } header: {
            Text("Placement")
        }
    }

    private var sensorSection: some View {
        Section {
            ForEach(requiredSensors) { sensor in
                HStack {
                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {
                        Text(sensor.title)

                        Text(
                            hub.permissionText(sensor)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if hub.enabled.contains(sensor)
                        && hub.ready(sensor) {
                        Label(
                            "Ready",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    } else if hub.requesting == sensor {
                        ProgressView()
                            .accessibilityLabel(
                                "Requesting access"
                            )
                    } else {
                        Button("Enable") {
                            hub.setEnabled(
                                sensor,
                                to: true
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            !hub.available.contains(sensor)
                                || hub.requesting != nil
                                || model.busy
                        )
                    }
                }
            }

            if let message = hub.setupMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Manage sensors") {
                model.selectedTab = 2
            }
        } header: {
            Text("Required sensors")
        } footer: {
            Text(
                "Enable both sensors before recording. This study uses " +
                "only these two streams; your other sensor selections " +
                "remain saved."
            )
        }
    }

    private var recordingSection: some View {
        Section {
            HStack {
                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {
                    Text(
                        model.active?.experiment
                            ?? "Research session"
                    )
                    .font(.headline)

                    Text(model.status)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(
                    Duration.seconds(max(0, now))
                        .formatted(
                            .time(pattern: .minuteSecond)
                        )
                )
                .font(.title2.monospacedDigit())
            }

            HStack {
                Button(
                    model.paused ? "Resume" : "Pause"
                ) {
                    if model.paused {
                        model.resume()
                    } else {
                        model.pause()
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Finish") {
                    confirmFinish = true
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(model.busy)

            Button {
                model.marker(
                    "IMU_REFERENCE_V1;" +
                    "source=researcher_button;" +
                    "label=unreviewed"
                )

                markerCount += 1
            } label: {
                Label(
                    "Add reference marker",
                    systemImage: "flag"
                )
            }
            .disabled(
                model.paused || model.busy
            )

            if markerCount > 0 {
                Text("Marker saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recording")
        } footer: {
            Text(
                "Markers use the session clock and require review " +
                "after export. Elapsed time includes pauses."
            )
        }
    }

    private var liveSection: some View {
        Section {
            preview(
                sensor: .accelerometer,
                points: acceleration,
                unit: "g"
            )

            preview(
                sensor: .gyroscope,
                points: rotation,
                unit: "rad/s"
            )
        } header: {
            Text("Live IMU · magnitude")
        }
    }

    private func preview(
        sensor: Sensor,
        points: [ResearchPoint],
        unit: String
    ) -> some View {
        let row = latest[sensor]

        let fresh = !model.paused
            && row.map {
                now - $0.received < 1
            } == true

        return VStack(
            alignment: .leading,
            spacing: 8
        ) {
            HStack {
                Text(sensor.title)
                    .font(
                        .subheadline.weight(.semibold)
                    )

                Spacer()

                if fresh, let last = points.last {
                    Text(
                        "\(last.magnitude, specifier: "%.3f") \(unit)"
                    )
                    .monospacedDigit()
                } else {
                    Text(
                        model.paused
                            ? "Paused"
                            : "Waiting for samples"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Chart(points) { point in
                LineMark(
                    x: .value(
                        "Session seconds",
                        point.elapsed
                    ),
                    y: .value(
                        unit,
                        point.magnitude
                    )
                )
                .foregroundStyle(.teal)
            }
            .chartXAxisLabel("Session seconds")
            .frame(height: 95)
            .accessibilityLabel(
                "\(sensor.title) magnitude preview in \(unit)"
            )
        }
        .padding(.vertical, 6)
    }

    private func updatePreview() {
        guard researchActive else {
            return
        }

        now = model.researchElapsed
        latest = model.researchSamples()

        if model.paused {
            acceleration = []
            rotation = []
            return
        }

        append(
            latest[.accelerometer],
            to: &acceleration
        )

        append(
            latest[.gyroscope],
            to: &rotation
        )
    }

    private func append(
        _ row: SampleRow?,
        to points: inout [ResearchPoint]
    ) {
        guard let row,
              row.values.count == 3,
              now - row.received < 1,
              points.last?.id != row.sequence else {
            return
        }

        if let last = points.last,
           last.run != row.run
            || row.elapsed - last.elapsed > 1 {
            points.removeAll()
        }

        let magnitude = sqrt(
            row.values.reduce(0) {
                $0 + $1 * $1
            }
        )

        points.append(
            ResearchPoint(
                id: row.sequence,
                run: row.run,
                elapsed: row.elapsed,
                magnitude: magnitude
            )
        )

        if points.count > 100 {
            points.removeFirst(
                points.count - 100
            )
        }
    }

    private func begin() {
        guard canBegin else {
            return
        }

        starting = true

        Task { @MainActor in
            defer {
                starting = false
            }

            do {
                let metadata: [String: String] = [
                    "schema": "scope.imu-research.v1",
                    "placement": placement,
                    "attachment": attachment,
                    "initial_orientation": orientation,
                    "placement_source": "researcher_selected",
                    "requested_rate_hz": "100",
                    "apple_detection_status":
                        "unavailable_not_integrated",
                    "ground_truth_status": "unreviewed",
                    "marker_semantics":
                        "Button-press time; not confirmed event onset",
                    "model_evaluation": "offline"
                ]

                let data = try JSONSerialization.data(
                    withJSONObject: metadata,
                    options: [.sortedKeys]
                )

                let notes = String(
                    decoding: data,
                    as: UTF8.self
                )

                try await model.start(
                    experiment: study,
                    participant: participant,
                    notes: notes,
                    protocolCode: "SCOPE_IMU_V1",
                    selected: requiredSensors,
                    plannedSeconds: nil,
                    keepAwake: true
                )

                model.selectedTab = 3
            } catch {
                model.message = AppMessage(
                    title: "Could not start research session",
                    detail: error.localizedDescription
                )
            }
        }
    }
}

private struct ResearchPoint: Identifiable {
    let id: Int
    let run: Int
    let elapsed: Double
    let magnitude: Double
}
