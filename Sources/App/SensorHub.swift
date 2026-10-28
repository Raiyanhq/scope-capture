import Foundation
import UIKit
import CoreMotion
import CoreLocation
import Darwin
import Combine

/// Framework ownership stays on the main actor. High-rate callbacks write only
/// to the locked, bounded buffer; no SwiftUI state is touched from those queues.
@MainActor
final class SensorHub: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var enabled: Set<Sensor> = []
    @Published private(set) var requesting: Sensor?
    @Published private(set) var permissionRevision = 0
    @Published private(set) var setupMessage: String?
    private let activity = CMMotionActivityManager()
    private var permissionCompletion: (() -> Void)?
    private var permissionTimeout: Task<Void, Never>?
    private var permissionToken: UUID?
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let location = CLLocationManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SCOPECapture.sensors"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var buffer: SampleBuffer?
    private var generation = 0
    private var selected: Set<Sensor> = []
    private var proximityObserver: NSObjectProtocol?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        let saved = UserDefaults.standard.stringArray(forKey: "scope.enabledSensors") ?? []
        enabled = Set(saved.compactMap(Sensor.init(rawValue:)))
    }

    var available: [Sensor] {
        Sensor.allCases.filter { sensor in
            switch sensor {
            case .accelerometer: return motion.isAccelerometerAvailable
            case .gyroscope: return motion.isGyroAvailable
            case .deviceMotion: return motion.isDeviceMotionAvailable
            case .magnetometer: return motion.isMagnetometerAvailable
            case .location:
                // Availability describes the capability.
                // Authorization is checked separately by ready(_:).
                return true
            case .altitude: return CMAltimeter.isRelativeAltitudeAvailable()
            case .steps: return CMPedometer.isStepCountingAvailable()
            case .proximity: return UIDevice.current.userInterfaceIdiom == .phone
            }
        }
    }
    var hardwareModel: String {
        var system = utsname()
        guard uname(&system) == 0 else { return UIDevice.current.model }
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    var deviceDescription: String { UIDevice.current.model }

    func ready(_ sensor: Sensor) -> Bool {
        guard available.contains(sensor) else { return false }
        switch sensor {
        case .location:
            return [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus)
        case .altitude: return CMAltimeter.authorizationStatus() == .authorized
        case .steps: return CMPedometer.authorizationStatus() == .authorized
        case .proximity: return true
        default:
            return !CMMotionActivityManager.isActivityAvailable() || CMMotionActivityManager.authorizationStatus() == .authorized
        }
    }
    func permissionText(_ sensor: Sensor) -> String {
        if !available.contains(sensor) { return "Not available on this device" }
        switch sensor {
        case .location: return locationPermission
        case .proximity: return "No iOS permission required · checked when enabled"
        case .altitude: return statusText(CMAltimeter.authorizationStatus())
        case .steps: return statusText(CMPedometer.authorizationStatus())
        default:
            return CMMotionActivityManager.isActivityAvailable() ? statusText(CMMotionActivityManager.authorizationStatus()) : "No separate iOS permission required"
        }
    }
    private func statusText(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Permission allowed"
        case .denied: return "Permission denied · open Settings"
        case .restricted: return "Access restricted by iOS"
        case .notDetermined: return "Permission not requested"
        @unknown default: return "Permission status unknown"
        }
    }
    func refreshPermissions() { permissionRevision += 1 }
    private func saveSelection() {
        UserDefaults.standard.set(Sensor.allCases.filter(enabled.contains).map(\.rawValue), forKey: "scope.enabledSensors")
    }
    func setEnabled(_ sensor: Sensor, to value: Bool) {
        guard buffer == nil, requesting == nil else { return }
        setupMessage = nil
        if !value { enabled.remove(sensor); saveSelection(); return }
        guard available.contains(sensor) else { return }
        if sensor == .proximity {
            UIDevice.current.isProximityMonitoringEnabled = true
            let supported = UIDevice.current.isProximityMonitoringEnabled
            UIDevice.current.isProximityMonitoringEnabled = false
            if supported { enabled.insert(sensor); saveSelection() }
            else { setupMessage = "This device does not support proximity monitoring." }
            return
        }
        if ready(sensor) { enabled.insert(sensor); saveSelection(); return }
        requesting = sensor
        let token = UUID()
        permissionToken = token
        permissionCompletion = { [weak self] in
            guard let self else { return }
            if self.ready(sensor) { self.enabled.insert(sensor); self.saveSelection() }
            else { self.enabled.remove(sensor); self.saveSelection(); self.setupMessage = "\(sensor.title) is off. \(self.permissionText(sensor)). You can retry or change access in iOS Settings." }
            self.requesting = nil; self.refreshPermissions()
        }
        permissionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.completePermission(token: token)
        }
        switch sensor {
        case .location:
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            else { completePermission() }
        case .altitude:
            if CMAltimeter.authorizationStatus() == .notDetermined {
                altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.completePermission(token: token) }
                }
            } else { completePermission() }
        case .steps:
            if CMPedometer.authorizationStatus() == .notDetermined {
                let now = Date()
                pedometer.queryPedometerData(from: now.addingTimeInterval(-1), to: now) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.completePermission(token: token) }
                }
            } else { completePermission() }
        default:
            if CMMotionActivityManager.authorizationStatus() == .notDetermined {
                let now = Date()
                activity.queryActivityStarting(from: now.addingTimeInterval(-1), to: now, to: .main) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.completePermission(token: token) }
                }
            } else { completePermission() }
        }
    }
    private func completePermission(token: UUID? = nil) {
        if let token, token != permissionToken { return }
        guard let completion = permissionCompletion else { return }
        permissionCompletion = nil
        permissionToken = nil
        permissionTimeout?.cancel(); permissionTimeout = nil
        if requesting == .altitude { altimeter.stopRelativeAltitudeUpdates() }
        completion()
    }

    var locationPermission: String {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return location.accuracyAuthorization == .fullAccuracy ? "Allowed · precise" : "Allowed · approximate"
        case .denied: return "Denied — change in Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
    var motionPermission: String {
        switch CMPedometer.authorizationStatus() {
        case .authorized: return "Allowed"
        case .denied: return "Denied — change in Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    func start(selected sensors: [Sensor], buffer sink: SampleBuffer) {
        stop()
        buffer = sink; selected = Set(sensors)
        let run = sink.startRun(); generation = run
        sink.event("COLLECTOR_START", "Collector run \(run). Relative altitude and step counters restart for this run.")
        let accept: @Sendable (Sensor, Double, [Double]) -> Void = { sensor, uptime, values in
            sink.append(sensor, run: run, elapsed: sink.elapsed(uptime: uptime),
                        received: sink.elapsedNow(), values: values)
        }
        let report: @Sendable (Sensor, Error?) -> Void = { sensor, error in
            if let error { sink.sensorError(sensor, run: run, message: error.localizedDescription) }
        }
        if selected.contains(.accelerometer) {
            motion.accelerometerUpdateInterval = 1.0 / (Sensor.accelerometer.requestedHz ?? 100)
            motion.startAccelerometerUpdates(to: queue) { data, error in
                report(.accelerometer, error)
                if let data { accept(.accelerometer, data.timestamp, [data.acceleration.x, data.acceleration.y, data.acceleration.z]) }
            }
        }
        if selected.contains(.gyroscope) {
            motion.gyroUpdateInterval = 1.0 / (Sensor.gyroscope.requestedHz ?? 100)
            motion.startGyroUpdates(to: queue) { data, error in
                report(.gyroscope, error)
                if let data { accept(.gyroscope, data.timestamp, [data.rotationRate.x, data.rotationRate.y, data.rotationRate.z]) }
            }
        }
        if selected.contains(.magnetometer) {
            motion.magnetometerUpdateInterval = 1 / 25
            motion.startMagnetometerUpdates(to: queue) { data, error in
                report(.magnetometer, error)
                if let data { accept(.magnetometer, data.timestamp, [data.magneticField.x, data.magneticField.y, data.magneticField.z]) }
            }
        }
        if selected.contains(.deviceMotion) {
            motion.deviceMotionUpdateInterval = 1.0 / (Sensor.deviceMotion.requestedHz ?? 100)
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { data, error in
                report(.deviceMotion, error)
                guard let data else { return }
                let q = data.attitude.quaternion, g = data.gravity, a = data.userAcceleration, r = data.rotationRate
                accept(.deviceMotion, data.timestamp, [q.x, q.y, q.z, q.w, g.x, g.y, g.z, a.x, a.y, a.z, r.x, r.y, r.z])
            }
        }
        if selected.contains(.altitude) {
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, error in
                report(.altitude, error)
                if let data { accept(.altitude, data.timestamp, [data.relativeAltitude.doubleValue, data.pressure.doubleValue]) }
            }
        }
        if selected.contains(.steps) {
            pedometer.startUpdates(from: Date()) { data, error in
                report(.steps, error)
                guard let data else { return }
                // Measurement end time and callback arrival are deliberately separate.
                sink.append(.steps, run: run, elapsed: sink.elapsed(for: data.endDate),
                            received: sink.elapsedNow(), values: [data.numberOfSteps.doubleValue])
            }
        }
        if selected.contains(.location) {
            switch location.authorizationStatus {
            case .notDetermined: sink.sensorError(.location, run: run, message: "Enable location permission in Sensors before recording.")
            case .authorizedAlways, .authorizedWhenInUse: location.startUpdatingLocation()
            default: sink.sensorError(.location, run: run, message: "Location permission is unavailable.")
            }
        }
        if selected.contains(.proximity) {
            UIDevice.current.isProximityMonitoringEnabled = true
            if UIDevice.current.isProximityMonitoringEnabled {
                recordProximity()
                proximityObserver = NotificationCenter.default.addObserver(
                    forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == run else { return }
                        self.recordProximity()
                    }
                }
            } else { sink.sensorError(.proximity, run: run, message: "Proximity monitoring is not supported on this device.") }
        }
    }

    func stop() {
        buffer?.pause() // Reject queued callbacks before stopping the frameworks.
        buffer = nil; selected = []
        motion.stopAccelerometerUpdates(); motion.stopGyroUpdates()
        motion.stopMagnetometerUpdates(); motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates(); pedometer.stopUpdates()
        location.stopUpdatingLocation()
        if let proximityObserver { NotificationCenter.default.removeObserver(proximityObserver) }
        proximityObserver = nil
        UIDevice.current.isProximityMonitoringEnabled = false
    }
    private func recordProximity() {
        guard selected.contains(.proximity), let buffer else { return }
        let elapsed = buffer.elapsedNow()
        buffer.append(.proximity, run: generation, elapsed: elapsed, received: elapsed,
                      values: [UIDevice.current.proximityState ? 1 : 0])
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshPermissions()
        if requesting == .location, manager.authorizationStatus != .notDetermined { completePermission() }
        guard selected.contains(.location), let buffer else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            buffer.event("LOCATION_AUTHORIZATION", locationPermission)
            manager.startUpdatingLocation()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            buffer.sensorError(.location, run: generation, message: "Location permission denied or restricted.")
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard selected.contains(.location), let buffer else { return }
        for value in locations where value.horizontalAccuracy >= 0 {
            buffer.append(.location, run: generation, elapsed: buffer.elapsed(for: value.timestamp),
                received: buffer.elapsedNow(), values: [value.coordinate.latitude, value.coordinate.longitude,
                    value.altitude, value.horizontalAccuracy, value.verticalAccuracy, value.speed, value.course])
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        buffer?.sensorError(.location, run: generation, message: error.localizedDescription)
    }
}
