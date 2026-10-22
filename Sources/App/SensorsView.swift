import SwiftUI
import UIKit

struct SensorsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sensors: SensorHub
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up your instruments").font(.title2.weight(.semibold))
                    Text("Turn on the sensors your study needs. Allow access here before you record. Your selection is saved between sessions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                LabeledContent("Selected for the next session", value: "\(sensors.enabled.count)")
            }
            if let message = sensors.setupMessage {
                Section { Label(message, systemImage: "info.circle").font(.subheadline) }
            }
            if model.active != nil {
                Section {
                    Label("Session in progress", systemImage: "record.circle")
                    Text("Finish the session before changing its sensor selection. You can pause or resume from Record.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(Sensor.allCases) { sensor in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { sensors.enabled.contains(sensor) }, set: { sensors.setEnabled(sensor, to: $0) })) {
                            Label(sensor.title, systemImage: sensor.symbol).font(.headline)
                        }
                        .disabled(model.active != nil || model.busy || sensors.requesting != nil || (!sensors.available.contains(sensor) && !sensors.enabled.contains(sensor)))
                        Text(sensor.detail).font(.subheadline).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 7) {
                            if sensors.requesting == sensor { ProgressView().controlSize(.small) }
                            else { Image(systemName: sensors.ready(sensor) ? "checkmark.circle" : "info.circle") }
                            Text(sensors.requesting == sensor ? "Waiting for iOS permission…" : sensors.permissionText(sensor))
                        }.font(.caption).foregroundStyle(.secondary)
                        if let active = model.active, active.selected.contains(sensor) {
                            Text(model.paused ? "Paused in this session" : "Recording · \(active.count(sensor).formatted()) samples saved")
                                .font(.caption.weight(.medium))
                        } else {
                            Text(sensors.enabled.contains(sensor) ? (sensors.ready(sensor) ? "On for the next session" : "Selected — permission needs attention") : "Off")
                                .font(.caption.weight(.medium))
                        }
                    }.padding(.vertical, 7)
                }
            } header: { Text("Device sensors") } footer: {
                Text("iOS shares Motion & Fitness permission across several sensors and may show that prompt only once. Permission checks discard their readings. Selecting a sensor does not start a saved recording.")
            }
            Section {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Refresh sensor status") { sensors.refreshPermissions() }
                Button("Go to recording") { model.selectedTab = 0 }
                    .disabled(sensors.enabled.isEmpty || sensors.requesting != nil)
            } footer: { Text("If access was denied, iOS may require changing it in Settings. Proximity can turn the display off during a session when an object is near the sensor.") }
        }
        .navigationTitle("Sensors")
        .refreshable { sensors.refreshPermissions() }
        .onAppear { sensors.refreshPermissions() }
    }
}
