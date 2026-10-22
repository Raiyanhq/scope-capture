# Release checklist — publisher action required

This package prepares an app for further release validation. It is not a certification of App Store eligibility or approval. No device build, accessibility audit, Instruments trace, TestFlight distribution, or Apple review was performed in this workspace.

## Build and identity

- Use a current production Xcode release. Since April 28, 2026, Apple requires App Store uploads to use Xcode 26 or later and the iOS 26 SDK or later. An iOS 17 deployment target is separate from that SDK requirement. Source: [Apple upcoming requirements](https://developer.apple.com/news/upcoming-requirements/).
- Set your registered bundle identifier, signing team, version, and unique build number. Preserve the installed app’s identity when testing upgrades.
- Run `bash Tools/verify_mac.sh`. Resolve any compiler warnings/errors before release. Test signed builds on supported iPhones; a simulator cannot validate real sensor availability.
- Supply your organization’s real HTTPS privacy and support pages in `ResearchPrivacyPolicyURL` and `ResearchSupportURL`. They are intentionally blank until you provide them. The app’s in-app explanation is included; the published policy needs publisher identity/contact, current data handling, retention, deletion, and export details.
- Run `python3 Tools/release_preflight.py`. Its initial failure for missing publisher URLs is expected. This is a manual release gate, not an automatic build phase. After archiving, run it again with `--app` pointing to the archived `.app`.
- Confirm `PrivacyInfo.xcprivacy` is present inside the archived app and generate Xcode’s privacy report. Retain the unrounded, opaque 1024px icon. Supply screenshots from the actual app, not design mockups.
- Use Organizer → Validate App, then TestFlight. Submit only after the acceptance tests pass. Complete age-rating, export-compliance, content-rights, accessibility disclosures, and territory/account requirements accurately in App Store Connect.

## Privacy declarations

The source includes no developer-operated collection, cloud sync, analytics, tracking, or ads. Apple distinguishes processing that remains on-device from data collection transmitted off-device. Review your entire distributed app and any added SDKs before choosing its App Privacy labels. User-directed sharing needs an accurate explanation, and the receiving service has its own behavior. Source: [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).

The included required-reason entries correspond to actual code behavior:

| API category | Reasons | Use |
|---|---|---|
| System boot time | 35F9.1, 8FFB.1 | Session elapsed timers and absolute timestamps for app acquisition events; raw uptime is not exported by the update. |
| Disk space | E174.1, B728.1 | Refuse recording/export when space is insufficient, and show available storage to the user. Disk-space measurements are not exported. |
| User defaults | CA92.1 | Store this app’s first-use privacy acknowledgment through AppStorage. |

Review these against the compiled app and any dependencies: [Apple required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons). Adding new APIs or SDKs can change the required entries. Do not copy declarations into unrelated apps without checking their use.

Apple requires a privacy policy in the app and in App Store Connect, accurate metadata, working support contact, and a complete, tested product. If you later run human-subject or health research through the app, assess the applicable consent and ethics requirements for that actual study; the current acknowledgment is not study consent. Source: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), particularly 1.5, 2.1, 2.4, and 5.1.

## Real-device acceptance tests

Record results with device model, iOS version, build number, and pass/fail evidence. Do not mark these complete merely because a build succeeds.

| Scenario | Acceptance criterion |
|---|---|
| Upgrade installation | Existing sessions still appear; original exported checksums match pre-upgrade evidence apart from documented portable-export transformation. |
| First launch | Clear privacy acknowledgment; recorder disabled until acknowledged; no permission request for unselected location. |
| New session | Empty title/empty selection rejected; identifiers and notes saved correctly; unsupported sensors disabled. |
| Five-minute motion test | All selected available motion streams produce rows; end-to-end validator passes; inspect rates, gaps and warnings. |
| Multi-segment test | Record past two minute boundaries; sequences remain continuous across actual segment files. |
| Permission granted/denied | No crash or silent fabricated data; denied sensors generate understandable warnings; resume after system prompts if paused. |
| Pause / Resume | Counts stop advancing after queued data is checkpointed; a new collector_run begins; elapsed time includes pause. |
| Home / lock / phone interruption | Acquisition pauses, checkpoint is attempted, and no automatic hidden resumption occurs. Resume button works. |
| Timed stop | Foreground session stops near its target; suspended session finalizes when the app can next execute. Actual elapsed end is recorded. |
| Rapid stop/start | Old callbacks do not reach the next session; final export passes validation. |
| Forced termination | Reopen identifies interrupted session; recovery retains originals and marks output Recovered. Unwritten rows may be lost. |
| Corrupt-copy fixture | Modified bytes cause verification failure; complete malformed rows are not silently repaired. Do this with a test copy, not valuable data. |
| Storage pressure | Space reserve prevents starting/exporting; a write failure stops acquisition and leaves recovery available. |
| Export | Share to Files and an approved destination; cancel share; validate ZIP; repeat export; temporary files are cleaned on dismissal. |
| Delete | Cancel retains session; confirmed delete removes it locally; previously exported copy remains. |
| UI/accessibility | Test light/dark, large Dynamic Type, VoiceOver, landscape, small-screen iPhone, keyboard dismissal, and readable alerts. No information depends only on color. |
| Sustained operation | Run at least 30–60 minutes and profile memory, CPU, disk writes, thermal behavior and battery with Instruments. Establish device/protocol-specific limits. |

## Suggested review notes to adapt

“This app is a foreground-only, local device-sensor recorder. No sign-in is required. A reviewer can acknowledge the data-storage explanation, create a session, choose an available sensor, record briefly, then finish and export from Sessions. Core Motion requires a physical iPhone for meaningful sensor data. Location is optional and requested only if selected. Leaving the app pauses acquisition; Resume is explicit. The app provides no medical diagnosis or cloud upload.”

Adapt the notes to your final build and describe any actual changes. Do not claim ethics approval, calibration, institutional endorsement, or clinical suitability without evidence.
