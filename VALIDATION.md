# Validation record

Validation performed in the supplied Linux workspace on September 15, 2026:

- Parsed every Swift file with the tree-sitter Swift grammar to detect structural syntax errors.
- Parsed the two property lists, asset-catalog JSON files, and every Python file.
- Confirmed the app icon is an opaque RGB PNG at exactly 1024 × 1024 pixels.
- Ran `Tools/validate_session.py` against both user-supplied real-iPhone exports. The short export passed with 6 CSV files and 5,569 rows. The five-minute export passed with 35 CSV files and 53,600 rows.
- Modified one CSV value inside a disposable copy and confirmed the validator rejected the copy because its SHA-256 fingerprint no longer matched.
- Checked that the release preflight intentionally blocks the package while publisher privacy and support URLs are blank.
- Inspected generated project references for duplicates, missing source/configuration paths, and asset target membership.
- Corrected the iOS `FileManager.setAttributes(_:ofItemAtPath:)` argument label after Xcode type checking identified it in the first candidate.

Not performed here because this environment has no Apple SDK, Swift compiler, Xcode, iOS simulator, signing identity, or physical-device connection:

- Swift type checking or XCTest execution
- Xcode Debug/Release build
- App launch and visual inspection on iOS
- Sensor, permission, interruption, low-storage, thermal, battery, or accessibility behavior
- Archive signing, Organizer validation, TestFlight, or App Store review

Accordingly, this is a carefully reviewed **release candidate**, not a promise of zero defects or guaranteed App Store acceptance. Run `Tools/verify_mac.sh` and every applicable test in `RELEASE_CHECKLIST.md` before distribution. If Xcode reports an error, provide the full error and file/line reference; do not remove validation, recovery, permission, or privacy logic just to silence it.
