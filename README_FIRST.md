# SCOPE Capture — complete replacement package

SCOPE means **Scientific Collection & Observation Platform for Experiments**. SCOPE Capture is its local-first iPhone research recorder, targeting iOS 17 and later. It contains five complete Swift source files, a standalone Xcode project, an app icon, privacy configuration, core regression tests, and an independent export validator. There are no external Swift packages, Firebase services, analytics SDKs, or accounts.

**Release status: implementation candidate awaiting Xcode compilation and real-device acceptance testing.** This workspace cannot run Xcode or iOS. Syntax parsing and export-file checks are not a successful iPhone build or an App Store approval. Read `VALIDATION.md` for exactly what was checked.

## Replace the code in your existing project — recommended

1. Export your important sessions first. Duplicate your Xcode project folder as a backup. **Keep your existing bundle identifier, signing team, and installed app. Do not uninstall it.** The new store continues using `Application Support/ResearchSessions`.
2. Open the existing project in Xcode. Replace the **entire contents**, not selected snippets, of these files with the matching files in this package:

| Existing file | Complete replacement |
|---|---|
| Core.swift | Sources/Core/Core.swift |
| SensorHub.swift | Sources/App/SensorHub.swift |
| AppModel.swift | Sources/App/AppModel.swift |
| Views.swift | Sources/App/Views.swift |
| ResearchDataCollectorApp.swift | Sources/App/SCOPECaptureApp.swift |

3. Each complete file is ready to open and copy/paste. Every file must belong to the app target exactly once. Remove old duplicate declarations if you previously split these types into other files. There must be only one `@main` app declaration.
4. Add `Configuration/PrivacyInfo.xcprivacy` to the project, selecting the app target. Confirm it appears once under **Build Phases → Copy Bundle Resources**. Do not add `Tests` or `Package.swift` to the app target.
5. Merge the motion and location purpose strings and `ResearchPrivacyPolicyURL` / `ResearchSupportURL` keys from `Configuration/Info.plist` into your existing Info.plist. You may replace the full plist if it contains no other configuration you need; retain your target’s bundle/signing settings. If using the supplied full plist, set **Generate Info.plist File = No** and **Info.plist File** to its actual relative path. Do not put Info.plist in Copy Bundle Resources.
6. For the supplied icon, replace the existing AppIcon set with `Assets.xcassets/AppIcon.appiconset`. Keep only one AppIcon set in the target. Set **App Icons Source = AppIcon**. Your existing other assets can remain.
7. Use these target settings: **iOS Deployment Target = 17.0**, **Swift Language Version = Swift 5**, leave **Default Actor Isolation** at its normal nonisolated default, and set **Strict Concurrency Checking = Complete**. The compiler comes from current Xcode even though the language mode is Swift 5. This source uses modern compiler support for `@preconcurrency` delegate conformance. The supplied project is iPhone-only and supports portrait and landscape.
8. Set app version to **1.1.1** and build number above your last uploaded build. Remove any old, unused Background Modes capabilities; this recorder does not collect in the background. Keep the existing signing team and bundle identifier.
9. Select your connected iPhone and press **Command-R**. If Xcode reports stale duplicate errors, use **Product → Clean Build Folder** and check target membership. An upgrade with the same identity should retain the app’s data; confirm the old sessions appear before recording new ones.

## Open the included project instead

Unzip the entire package and open `SCOPECapture.xcodeproj`, **not Package.swift**. Select the **SCOPE Capture** scheme. In Signing & Capabilities, set your own bundle identifier and team. The included `org.example.scope.capture` is a development placeholder, not an App Store identity. To upgrade the app already on your phone, use that app’s existing bundle identifier and team.

The project is already generated. `Tools/create_project.py` is included only for reproducibility; rerunning it resets this reference project’s build settings, so do not run it after customizing signing or identifiers.

## Verify on your Mac

In Terminal, change into the unzipped folder and run:

```bash
bash Tools/verify_mac.sh
```

This runs the core XCTest package and compiles unsigned simulator Debug and device Release builds of the supplied project. It does not launch a simulator, so it avoids the memory load you experienced. It does not sign or submit the app. Then run the real-device checks in `RELEASE_CHECKLIST.md`.

To verify an exported recording independently:

```bash
python3 Tools/validate_session.py "/path/to/Session-example.zip"
```

Python 3.10 or later is needed for the Python tools. The iPhone app itself has no Python dependency.

## What changed

- Native Record, Sessions, and About tabs; light/dark appearance; scalable text; clear empty states; event markers; explicit export and deletion confirmations.
- Study title, protocol code, participant code, setup notes, optional timed stop, and optional keep-screen-awake behavior.
- Bounded sensor buffer; collector-generation guards; one serialized storage actor; synchronized checkpoints; atomic manifests; storage reserve; no main-thread CSV scanning.
- Separate measurement and callback-arrival time; fractional event timing; collector-run identifiers; distinct overflow, timestamp, and sensor diagnostics.
- Session details with counts, observed motion rates, gaps, file fingerprints, and full event history. Statistics communicate limitations instead of claiming perfect data quality.
- Recovery keeps original manifests and unfinished CSV originals, marks the session Recovered, and refuses to silently repair a malformed complete row.
- Export checks counts, paths, hashes, and inventory before creating the ZIP. Legacy export omits raw uptime fields in a separately fingerprinted copy; the original recordings remain on the phone.
- In-app privacy explanation, just-in-time permission descriptions, required-reason API declarations, publisher URL configuration, and release checks.

## Scope and limitations

Recording pauses when the app becomes inactive; **Resume is deliberate**, including after some permission prompts. Timed stops count paused time and execute when the app next runs its timer. Force termination can lose the bounded, not-yet-written buffer; recovery cannot reconstruct those measurements. Unsupported or denied sensors may produce no samples and appear in the event log. There is no import workflow or automatic cloud backup. Export important sessions deliberately.

The first-use acknowledgment is not research participant consent. This general-purpose recorder does not manage recruitment, study consent, clinical decisions, or institutional review. Firebase and the web app remain future work; adding them requires new data-flow, security, and privacy reviews.
