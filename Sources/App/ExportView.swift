import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL

    @State private var destination: Destination?
    @State private var result: String?

    private enum Destination: String, Identifiable {
        case files
        case share

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)

                        Text("Ready to export")
                            .font(.title2.weight(.bold))

                        Text("Your recording has been verified.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)

                    Button {
                        result = nil
                        destination = .files
                    } label: {
                        Label("Save to Files", systemImage: "folder")
                            .font(.headline)
                            .frame(minHeight: 44)
                    }

                    Button {
                        result = nil
                        destination = .share
                    } label: {
                        Label(
                            "Share or AirDrop",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.headline)
                        .frame(minHeight: 44)
                    }
                } footer: {
                    Text("Choose an approved destination. Your original recording stays in SCOPE.")
                }

                if let result {
                    Section {
                        Text(result).font(.subheadline)
                    }
                }

                Section {
                    DisclosureGroup("File details") {
                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)

                        Text("ZIP containing session metadata and sensor CSV files. The ZIP is not encrypted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("AirDrop help") {
                        Text("Keep both devices nearby, with Wi-Fi and Bluetooth on. Turn off Personal Hotspot. Check that the recipient allows AirDrop, then choose Share or AirDrop above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $destination) { target in
                if target == .files {
                    SaveZIPPicker(url: url) {
                        result = $0
                        destination = nil
                    }
                } else {
                    ZIPShareSheet(url: url) {
                        result = $0
                        destination = nil
                    }
                }
            }
        }
    }
}

private final class ZIPActivityItem: NSObject, UIActivityItemSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.zip.identifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        "SCOPE research session"
    }
}

private struct ZIPShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: (String) -> Void

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [ZIPActivityItem(url: url)],
            applicationActivities: nil
        )

        controller.completionWithItemsHandler = {
            _, completed, _, error in

            let message = error.map {
                "Sharing failed: \($0.localizedDescription). You can retry or use Save to Files."
            } ?? (
                completed
                    ? "Sharing completed."
                    : "Sharing cancelled. Your ZIP is still ready."
            )

            DispatchQueue.main.async {
                completion(message)
            }
        }

        return controller
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}

private struct SaveZIPPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(
        context: Context
    ) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forExporting: [url],
            asCopy: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ controller: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (String) -> Void

        init(completion: @escaping (String) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion(
                urls.isEmpty
                    ? "No destination was selected."
                    : "A copy was saved to your selected destination."
            )
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            completion("Save cancelled. Your ZIP is still ready.")
        }
    }
}
