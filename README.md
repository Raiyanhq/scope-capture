# SCOPE Capture

### Collect, organize, and export research data from your iPhone.

SCOPE Capture is a native iOS application that helps researchers collect timestamped measurements from iPhone sensors. Users can select sensors, create recording sessions, document phone placement, review recordings, and export their data for analysis.

The app saves recordings locally, allowing phone-sensor collection without an internet connection.

> **Project status:** Active development. Core recording and export workflows are implemented. External-device compatibility depends on the hardware and its supported iOS interface. This project is not yet a verified App Store release.

## Who is it for?

- **Researchers and scientists** collecting motion or environmental measurements.
- **Students and educators** conducting sensor-based experiments.
- **Machine-learning researchers** building datasets and comparing models.
- **Developers** extending a native iOS data-collection application.

No programming knowledge is required to operate an installed build. Building and installing the application from this repository requires a Mac and Xcode.

## What can the app do?

| Capability | Description |
|---|---|
| Sensor selection | View supported phone sensors and choose which ones to record. |
| Recording sessions | Create named sessions with research details and participant codes. |
| Recording controls | Pause, resume, finish, and add timestamped event markers. |
| Research workflow | Document phone placement and view compact motion graphs. |
| Local storage | Keep recordings on the iPhone until the user exports or deletes them. |
| Session renaming | Rename saved sessions and use the updated name for ZIP exports. |
| Export | Package recordings and metadata into a ZIP for Files, AirDrop, email, or other available sharing destinations. |
| External files | Import original files from accessible storage without converting their contents. |
| Supported accessories | Capture raw streams from compatible, configured Apple accessories. |

## A typical recording

1. Open **Sensors**.
2. Select the sensors required by your study and grant any necessary permissions.
3. Open **Home** and create a new session.
4. Enter a descriptive session name and relevant research details.
5. Start recording and keep SCOPE Capture open.
6. Add event markers or pause when needed.
7. Finish and save the session.
8. Open **Sessions** to review, rename, or export it.

For motion studies, use the **Research** page to document phone placement and inspect live accelerometer and gyroscope previews.

## Phone sensors and sampling

Availability depends on the iPhone hardware and iOS permissions.

| Sensor | Recorded measurements | Requested rate |
|---|---|---|
| Accelerometer | Three-axis acceleration, including gravity, in g | 100 Hz |
| Gyroscope | Three-axis angular velocity in radians per second | 100 Hz |
| Device motion | Orientation, gravity, user acceleration, and rotation rate | 100 Hz |
| Magnetometer | Three-axis magnetic field in microteslas | 25 Hz |
| Relative altitude | Relative altitude and pressure | System-controlled |
| Location | Coordinates and available accuracy information | System-controlled |
| Steps | Cumulative steps within each collector run | Event-based |
| Proximity | Near/far state changes | Event-based |

**Requested rates are not guaranteed delivery rates.** The app preserves timestamps so researchers can inspect actual sampling intervals and gaps.

Recording pauses when the app becomes inactive. Resume acquisition after returning to the app. Session elapsed time includes pauses.

## Motion research and fall-detection datasets

The Research page supports collecting iPhone motion data for later analysis, including fall-detection research.

Researchers can document:

- Study and participant identifiers.
- Phone placement, such as chest, arm, or wrist.
- Attachment method and initial orientation.
- Reference markers added during recording.

### Understanding the graphs

The live charts display the magnitude of the three sensor axes:

**Magnitude = √(x² + y² + z²)**

The horizontal axis represents elapsed session time. The vertical axis represents acceleration magnitude in g or rotation-rate magnitude in radians per second.

The charts use a reduced preview to limit screen-update work. Exported CSV files retain the recorded axis values independently of the preview.

### Important interpretation limits

- A graph spike is not proof that a fall occurred.
- Reference markers record button-press times and require review.
- The application does not currently classify falls automatically.
- Apple Watch fall detection is not integrated.
- Model training and comparison take place outside the app using exported data.

SCOPE Capture is a research collection tool, not an emergency-monitoring or medical-diagnosis service.

## External-device workflows

The **Devices** page stores device profiles and provides two distinct workflows.

### Import existing files

Import files that are accessible through the iOS Files picker, including files on compatible connected storage.

The app:

- Retains original file contents and filenames.
- Supports regular file types beyond CSV, including binary and other device-specific formats.
- Organizes copies under separate device/import folders.
- Records device details, byte counts, and SHA-256 checksums.
- Checks copied files and verifies them again during export.

Stop the logger’s file-writing operation before importing its files. Import time is not treated as the original acquisition time.

### Capture a supported live stream

Live capture uses Apple’s External Accessory framework and requires a compatible accessory with a manufacturer-supported protocol configured in the app.

Connection status and incoming-data status are separate: opening a connection does not prove that measurements are arriving.

Raw captures preserve incoming bytes with separate receipt-time information. The app does not infer unknown sample boundaries, units, or calibration.

**Connecting a cable does not make every device compatible.** Generic USB serial devices are not automatically supported. Lightning devices may also require a compatible host adapter and external power.

### Current session integration

Starting a Home recording starts the selected iPhone sensors. It does not automatically start external capture.

External capture currently starts and stops separately. After saving, attach its files to the appropriate session before exporting. Phone and external-device acquisition are not automatically synchronized.

The phone’s 100 Hz setting does not reconfigure an external device’s sampling rate.

## Exported data

A session ZIP may contain:

| Item | Purpose |
|---|---|
| `manifest.json` | Session metadata, file inventory, events, and integrity information. |
| Phone-sensor folders | Separate CSV streams for the selected phone sensors. |
| `external/` | Original imported files or supported-accessory captures. |
| Recovery evidence | Preserved evidence when a session required recovery. |

Phone CSV streams include measurement time, arrival time, sequence information, collector-run information, and sensor-specific values. Older recordings may use an earlier schema.

External paths use stable identifiers to avoid filename collisions. Readable device labels and original filenames are recorded in the manifest.

ZIP filenames follow the session name, with filename-safe normalization where necessary.

**Integrity checks detect changes to stored bytes.** They do not prove that the hardware generated every expected sample or that no data was lost before reaching the phone. Device-level sequence numbers, framing, and checksums may be needed for that assessment.

## Privacy and storage

- Recordings remain locally stored until the user exports them.
- No cloud upload is implemented in the current workflow.
- Permissions are requested for features that need them.
- Exported files may contain participant codes, notes, timestamps, or location data.
- ZIP exports are not encrypted by the app.
- Export destinations apply their own privacy and retention practices.
- Deleting the app can remove its locally stored recordings.

Use participant codes and follow the consent, storage, and sharing requirements of your study.

## Build and run

### Requirements

- A Mac with Xcode and an iOS SDK supporting the project’s deployment target.
- iOS 17 or later.
- A physical iPhone for meaningful sensor and accessory testing.
- An Apple account and appropriate signing configuration for device installation.

The application targets iPhone hardware, including iPhone 12 and newer when running a compatible iOS version.

### Installation

1. Clone or download the repository.
2. Open **`SCOPECapture.xcodeproj`** in Xcode.
3. Select the **SCOPE Capture** scheme.
4. Select your connected iPhone.
5. Open **Signing & Capabilities** and choose your development team.
6. Confirm the bundle identifier is appropriate for your installation.
7. Build and run.

`Package.swift` defines the core library and its tests; it is not the launchable iPhone application.

When updating an existing installation, retain the same signing identity and bundle identifier where appropriate. Export important recordings before making installation changes.

## Technical overview

SCOPE Capture uses:

- **SwiftUI and UIKit** for interface and system sharing.
- **Core Motion** for motion and related sensor measurements.
- **Core Location** for optional location recording.
- **External Accessory** for compatible accessory streams.
- **Foundation** for local storage and file operations.
- **CryptoKit** for SHA-256 integrity checks.
- **Swift Charts** for motion previews.

High-rate phone callbacks feed a bounded buffer. The storage layer writes periodic checkpoints and maintains a session manifest. Display previews run separately from the recording stream.

### Main source areas

| Location | Responsibility |
|---|---|
| `Sources/App/` | Screens, application state, sensor ownership, and device workflows. |
| `Sources/Core/` | Session models, local storage, validation, and archive creation. |
| `Configuration/` | App configuration and privacy declarations. |
| `Assets.xcassets/` | Icons and visual assets. |
| `Tests/` | Core storage and recording tests. |
| `Tools/` | Verification and supporting development scripts. |

Use the file references in the Xcode project as the build source of truth. Avoid compiling duplicate copies of the same Swift types.

## Development and verification

Run core tests from the repository root:

```bash
swift test
```

For the supplied Mac verification workflow:

```bash
bash Tools/verify_mac.sh
```

Build checks do not replace physical-device testing. Before relying on a release, verify:

- Actual sensor sampling intervals and interruptions.
- Longer recording sessions and storage limits.
- Session persistence, renaming, and recovery.
- ZIP contents and sharing.
- External-file integrity.
- Accessory disconnects and partial captures with the actual hardware.
- Accessibility, larger text, and light/dark appearance.

Keep recordings, credentials, signing certificates, and generated build output out of Git.

## Current limitations and release work

- Universal wired-device support is not available.
- Live accessories need manufacturer-specific configuration and testing.
- Phone and external recording controls remain separate.
- Continuous background acquisition is not implemented.
- Cloud synchronization and in-app model evaluation are not implemented.
- App Store release requires completed publisher information, working privacy/support URLs, signing, distribution checks, and real-device validation.

## Feedback and contributions

When reporting an issue, include:

- iPhone model and iOS version.
- App version and build number.
- Steps to reproduce the issue.
- Expected and actual behavior.
- Relevant screenshots or error messages.

Remove participant information and sensitive data before sharing diagnostic material.

Keep contributions focused and describe how the change was verified. UI changes should include screenshots when possible.

## Project author

Developed by **Raiyan Haque** as part of an undergraduate research project at **Georgia State University**.

## License

Refer to the repository’s `LICENSE` file, if provided. This README does not grant a license or establish the university’s or contributors’ ownership rights.