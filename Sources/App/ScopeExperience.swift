//
//  ScopeExperience.swift
//  SCOPECaptureCore
//
//  Created by MD. Raiyan Haque on 9/21/26.
//

import SwiftUI
import UIKit

enum ScopeRelease {
    static let agreementKey = "scope.agreement.2026-10-28.ble"
    static let policyVersion = "October 28, 2026"

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]

        let version =
            info["CFBundleShortVersionString"] as? String ?? "—"

        let build =
            info["CFBundleVersion"] as? String ?? "—"

        return "\(version) (\(build))"
    }

    static func text(_ key: String) -> String? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: key
        ) as? String else {
            return nil
        }

        let clean = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return clean.isEmpty ? nil : clean
    }

    static func url(_ key: String) -> URL? {
        guard let value = text(key),
              let url = URL(string: value),
              url.scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        return url
    }
}

struct ScopeBrandHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform.path")
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(.tint)
                .padding(16)
                .background(
                    Color.teal.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .accessibilityHidden(true)

            Text("SCOPE Capture")
                .font(.largeTitle.weight(.bold))

            Text("Observe. Record. Explore.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .padding(.vertical, 12)
    }
}

struct ScopeWelcomeScreen: View {
    let continueAction: () -> Void

    @State private var agreed = false

    var body: some View {
        List {
            Section {
                ScopeBrandHeader()
            }
            .listRowBackground(Color.clear)

            Section {
                Label(
                    "Choose the sensors for your study",
                    systemImage: "slider.horizontal.3"
                )

                Label(
                    "Keep recordings on your device",
                    systemImage: "internaldrive"
                )

                Label(
                    "Review and export when ready",
                    systemImage: "square.and.arrow.up"
                )
            }

            Section {
                NavigationLink("Privacy policy") {
                    ScopePolicyScreen(document: .privacy)
                }

                NavigationLink("Terms of use") {
                    ScopePolicyScreen(document: .terms)
                }

                Toggle(
                    "I agree to the terms and acknowledge the privacy policy",
                    isOn: $agreed
                )
                .font(.subheadline)
            } footer: {
                Text(
                    "This agreement is for using the app. " +
                    "It is not participant consent for a research study. " +
                    "Sensor permissions are requested separately."
                )
            }

            Section {
                Button(action: continueAction) {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 36
                        )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agreed)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Welcome")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ScopePreferencesScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ScopeAboutScreen()
                } label: {
                    Label(
                        "About SCOPE",
                        systemImage: "info.circle"
                    )
                }

                NavigationLink {
                    ScopeSupportScreen()
                } label: {
                    Label(
                        "Help & support",
                        systemImage: "questionmark.circle"
                    )
                }
            }

            Section("Privacy & legal") {
                NavigationLink("Privacy policy") {
                    ScopePolicyScreen(document: .privacy)
                }

                NavigationLink("Terms of use") {
                    ScopePolicyScreen(document: .terms)
                }

                Button("Manage iOS permissions") {
                    if let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) {
                        UIApplication.shared.open(url)
                    }
                }
            }

            Section {
                LabeledContent(
                    "Saved sessions",
                    value: model.sessions.count.formatted()
                )

                LabeledContent(
                    "Available storage",
                    value: model.storageText
                )

                Button("Open saved sessions") {
                    model.selectedTab = 1
                    dismiss()
                }
            } header: {
                Text("Your data")
            } footer: {
                Text(
                    "Delete recordings from their session menu. " +
                    "Exported copies are managed separately at their destination. " +
                    "Export important recordings: the session folder is " +
                    "excluded from automatic device backups."
                )
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .refreshable {
            await model.refresh()
        }
    }
}

struct ScopeAboutScreen: View {
    var body: some View {
        List {
            Section {
                ScopeBrandHeader()
            }
            .listRowBackground(Color.clear)

            Section {
                Text(
                    "Scientific Collection & Observation Platform for Experiments"
                )
                .font(.headline)

                Text(
                    "A local recording workspace for selected iPhone sensors, " +
                    "timestamped observations, and portable research datasets."
                )

                LabeledContent(
                    "Version",
                    value: ScopeRelease.version
                )

                if let publisher = ScopeRelease.text(
                    "ResearchPublisherName"
                ) {
                    LabeledContent(
                        "Publisher",
                        value: publisher
                    )
                }
            }

            Section("Research tools") {
                Text(
                    "The Research tab records iPhone IMU streams and phone " +
                    "placement. Model evaluation takes place after export. " +
                    "Reference markers are unreviewed annotations, " +
                    "not confirmed falls."
                )

                Text(
                    "The Devices tab connects to Bluetooth LE sensors and preserves " +
                    "selected notification payloads with phone arrival times. " +
                    "Compatibility and measurement decoding depend on device firmware."
                )

                Text(
                    "Apple Watch fall detection is not integrated. " +
                    "SCOPE does not provide medical diagnosis, emergency " +
                    "monitoring, or guaranteed background acquisition."
                )
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ScopeSupportScreen: View {
    var body: some View {
        List {
            Section("Recording") {
                DisclosureGroup("How do I start?") {
                    Text(
                        "Open Sensors and enable the measurements you need. " +
                        "Return Home and choose New recording. The Research " +
                        "tab provides a separate IMU workflow."
                    )
                }

                DisclosureGroup("Why did recording pause?") {
                    Text(
                        "Leaving SCOPE or locking the phone pauses acquisition. " +
                        "Return to the app and tap Resume. Keep screen awake " +
                        "can help during a session. Elapsed time includes pauses."
                    )
                }

                DisclosureGroup("What if a sensor is unavailable?") {
                    Text(
                        "Hardware support and permissions vary. Open Sensors " +
                        "to inspect availability. If access was denied, change " +
                        "it in iPhone Settings. An enabled sensor is not a " +
                        "guarantee of complete data: review the saved stream " +
                        "and events."
                    )
                }
            }

            Section("Files & devices") {
                DisclosureGroup("How do I export or delete a session?") {
                    Text(
                        "Open Sessions, select a recording, and choose Export " +
                        "ZIP. Use Save to Files or Share. For deletion, use " +
                        "the session’s actions menu. Deleting a session does " +
                        "not remove copies previously exported."
                    )
                }

                DisclosureGroup("Why is my Bluetooth board missing?") {
                    Text(
                        "The board must be powered and running Bluetooth LE " +
                        "advertising firmware. An empty board cannot advertise. " +
                        "Allow SCOPE Bluetooth access and try Find device again."
                    )
                }

                DisclosureGroup("What should I send with a bug report?") {
                    Text(
                        "Describe the steps, expected result, and what happened. " +
                        "Include app and iOS versions. Do not send participant " +
                        "information or research recordings unless your study " +
                        "authorizes sharing them."
                    )
                }
            }

            Section("Contact") {
                if let url = ScopeRelease.url("ResearchSupportURL") {
                    Link(
                        "Contact support",
                        destination: url
                    )
                } else {
                    Text(
                        "An online support address has not been configured for this build."
                    )
                    .foregroundStyle(.secondary)
                }

                ShareLink(
                    item:
                        "SCOPE Capture \(ScopeRelease.version)\n" +
                        "iOS \(UIDevice.current.systemVersion)"
                ) {
                    Label(
                        "Share app version",
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
        }
        .navigationTitle("Help & support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum ScopePolicyDocument {
    case privacy
    case terms

    var title: String {
        self == .privacy
            ? "Privacy policy"
            : "Terms of use"
    }

    var linkKey: String {
        self == .privacy
            ? "ResearchPrivacyPolicyURL"
            : "ResearchTermsURL"
    }

    var sections: [(String, String)] {
        switch self {
        case .privacy:
            return [
                (
                    "Scope",
                    """
                    This notice describes this local-storage version of SCOPE \
                    Capture. It has no user account, automatic cloud upload, \
                    advertising SDK, or developer-operated analytics service. \
                    A future cloud-connected release will require an updated notice.
                    """
                ),
                (
                    "Information on your device",
                    """
                    Sessions store selected sensor readings, timestamps, device \
                    and software information, recording titles, participant codes, \
                    notes, and event markers. Research sessions also store \
                    researcher-selected placement and orientation. Location is \
                    recorded only when selected and permitted. Preferences store \
                    sensor choices and acceptance of the current app agreement.
                    """
                ),
                (
                    "Permissions",
                    """
                    Sensor access is requested when needed. Several measurements \
                    share Motion & Fitness access. Permission checks may briefly \
                    query motion activity, steps, or altitude; these setup results \
                    are not retained as session measurements. Location permission \
                    is requested separately. You can revoke access in iOS Settings \
                    or deselect sensors before a new session.
                    """
                ),
                (
                    "Bluetooth",
                    """
                    Searching discovers nearby advertising Bluetooth LE devices. \
                    Device labels are saved locally. When Record with sessions is \
                    enabled, selected notification payloads, phone arrival times, \
                    device identity details and GATT stream identifiers are saved \
                    with your research session and included in its export. \
                    Review the device and streams before collecting or sharing data.
                    """
                ),
                (
                    "Storage and retention",
                    """
                    Recordings are kept in the app’s private storage using iOS \
                    file protection. The recording folder is excluded from \
                    automatic device backups. Recordings remain until deleted or \
                    the app is removed. Storage failures or interruptions can \
                    cause data loss; export important work. Preferences may be \
                    handled by the device’s backup settings.
                    """
                ),
                (
                    "Export and deletion",
                    """
                    Export creates a temporary, unencrypted ZIP containing the \
                    selected session and its metadata. You choose its destination. \
                    The receiving app, service, or person controls the exported \
                    copy. Temporary session ZIPs are cleaned up after the export \
                    screen closes or on a later app launch. Deleting a local \
                    session does not delete exported copies.
                    """
                ),
                (
                    "Your choices",
                    """
                    You can stop or pause acquisition, change sensor selections, \
                    revoke iOS permissions, export a session, or delete local \
                    recordings. The app has no account to delete. For data already \
                    supplied to a study, contact the study organizer about \
                    withdrawal and deletion. Removing app access does not \
                    automatically withdraw you from a study.
                    """
                ),
                (
                    "Support and policy changes",
                    """
                    Opening a published policy or support link uses your browser \
                    and the destination website’s privacy practices. If you \
                    voluntarily send a support message, its recipient receives \
                    the information you include. Avoid sending sensitive research \
                    data. Publisher and support details are provided through About \
                    and Help when configured. Review updated notices when the \
                    app’s handling of data changes.
                    """
                )
            ]

        case .terms:
            return [
                (
                    "Purpose",
                    """
                    SCOPE Capture is a tool for recording selected device \
                    measurements and organizing local research files. Use it only \
                    for lawful activities and information you are authorized to \
                    collect. The applicable software license accompanying the \
                    app continues to govern the software.
                    """
                ),
                (
                    "Research responsibilities",
                    """
                    The study organizer is responsible for the research protocol, \
                    appropriate ethics review, participant information and consent, \
                    supervision, and data-handling arrangements. Acceptance of \
                    these app terms and iOS permissions is not research participant \
                    consent. Do not conduct undisclosed monitoring or record \
                    unnecessary identifying information.
                    """
                ),
                (
                    "Measurement limitations",
                    """
                    Sensor availability, accuracy, timestamps, and sampling rates \
                    vary by device and operating conditions. Requested rates are \
                    not guaranteed. Leaving the app pauses acquisition. Review \
                    missing intervals, warnings, and recovered-session status \
                    before analysis. A checksum verifies file consistency, \
                    not scientific validity.
                    """
                ),
                (
                    "Health and safety",
                    """
                    This app does not diagnose conditions, provide emergency \
                    assistance, or guarantee fall detection. The IMU research \
                    page records data for later analysis; it does not run Apple’s \
                    fall detector. Do not rely on this app for personal safety \
                    or use it to direct unsafe physical activities.
                    """
                ),
                (
                    "Data and sharing",
                    """
                    Choose participant codes carefully, protect access to the \
                    device, and follow your study’s retention policy. You control \
                    the export destination and are responsible for authorization \
                    to share the data. ZIP exports are not encrypted by SCOPE. \
                    Keep appropriate copies because device loss, removal of the \
                    app, and storage failures may make recordings unavailable.
                    """
                ),
                (
                    "External devices",
                    """
                    Connect only to devices you are authorized to use. \
                    Bluetooth compatibility depends on device firmware, accessible \
                    GATT characteristics and any required authorization. Received \
                    payloads are preserved with phone receipt times; sample framing, \
                    calibration and completeness require device-specific validation. \
                    Phone sampling settings do not reconfigure external hardware.
                    """
                ),
                (
                    "Updates and support",
                    """
                    Capabilities and these notices may change as the app develops. \
                    Keep a record of the app version used in a study. Contact the \
                    published support channel for app issues and the study \
                    organizer for participant or protocol questions. These terms \
                    do not restrict rights that cannot be restricted under \
                    applicable law.
                    """
                )
            ]
        }
    }
}

struct ScopePolicyScreen: View {
    let document: ScopePolicyDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(document.title)
                    .font(.largeTitle.weight(.bold))

                Text("Updated \(ScopeRelease.policyVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let publisher = ScopeRelease.text(
                    "ResearchPublisherName"
                ) {
                    Text("Publisher: \(publisher)")
                        .font(.subheadline)
                }

                ForEach(document.sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.0)
                            .font(.headline)

                        Text(section.1)
                            .foregroundStyle(.secondary)
                    }
                }

                if let url = ScopeRelease.url(document.linkKey) {
                    Link(
                        "Read published version",
                        destination: url
                    )
                }

                if let url = ScopeRelease.url("ResearchSupportURL") {
                    Link(
                        "Contact support",
                        destination: url
                    )
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(
                maxWidth: 680,
                alignment: .leading
            )
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
