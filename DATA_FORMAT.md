# Research recording format

Each session has a UUID folder, a `manifest.json`, and sensor folders with minute-indexed CSV segments. A final partial minute is expected. Time segmentation is based on measurement elapsed time, not callback arrival. Empty minute/sensor combinations do not get fabricated files.

## Version 2 columns

All CSVs begin with `sequence,elapsed_s,utc_epoch_s,received_elapsed_s,collector_run`, followed by the sensor fields defined in `Sensor.fields` in Core.swift.

| Column | Meaning |
|---|---|
| sequence | Accepted row sequence for that sensor, continuing across segments and collector runs. It is not a hardware packet counter. |
| elapsed_s | Measurement time relative to session start, seconds. Core Motion uses its monotonic timestamp; location and pedometer timestamps are mapped from their measurement dates. |
| utc_epoch_s | Session start UTC anchor plus measurement elapsed time. Device clocks are not externally synchronized. |
| received_elapsed_s | Monotonic elapsed time when the callback reached the app. Arrival delay can differ from measurement time. |
| collector_run | Increments whenever acquisition starts or resumes. |

No raw device uptime is persisted in new sessions. For dates supplied by a sensor, changing the device clock can make the measurement time inconsistent; stale, out-of-order, and future measurements are rejected with diagnostics. The app is not a cross-device time-synchronization service.

Accelerometer includes gravity in g. Gyroscope and motion rotation are rad/s. Motion attitude is quaternion x/y/z/w in `xArbitraryZVertical`; gravity and user acceleration are g. Magnetometer is uncalibrated µT. Location includes accuracy; negative vertical accuracy/speed/course means unavailable, not physical negative speed. Altitude is relative metres and pressure is kPa.

`run_cumulative_steps` is cumulative within a collector run. Use the maximum per run, then sum those maxima if the protocol calls for a session estimate. Do not add every CSV row. The pedometer may deliver its final count late; this app does not query or reconcile historical counts after stopping. Relative altitude also resets per collector run.

## Quality and integrity

The manifest contains requested sensor selection, hardware model (not a unique device identifier), OS/app versions, study metadata, state, events, file sizes, counts, and SHA-256 fingerprints. New finalizations include stream summaries. Observed rate is `(rows-1)/(last measurement-first measurement)`, including pauses. A requested-rate gap threshold is 2.5 periods. Event-based sensors have no fixed-rate completeness score. The optional coverage estimate is conservative observed time, not proof that every physical sample was captured.

CSV hashes detect discrepancies relative to the manifest. The manifest is not cryptographically signed and hashes do not establish identity or scientific validity. Incomplete, recovered, and interrupted recordings must retain those qualifications downstream.

## Recovery

Recovery is available for incomplete/interrupted local sessions while no recording is active. It first preserves the manifest, scans complete CSV rows, and only trims a non-newline-terminated final row after copying the whole original CSV into `recovery-originals`. A malformed complete row is rejected. Recovery stores fingerprints of its evidence files. Exact termination time remains unknown; no synthetic end timestamp is invented.

## Existing version 1 sessions

The existing schema, including whole-second manifest dates and `source_time_s`, remains readable. Original CSVs and final manifests are not rewritten by ordinary viewing. Older manifests lack detailed stream summaries; the interface says so. Earlier step timing inconsistencies cannot be retroactively corrected without measurement evidence.

When exporting version 1, the app first verifies the on-device original, then creates a portable copy without `source_time_s` or `clockAnchorUptime`. The copy retains schemaVersion 1, records the transformation in `formatNotes.exportTransformation`, and recalculates file sizes and hashes. Its header begins `sequence,elapsed_s,utc_epoch_s`. Original working files and recovery evidence remain on the device. Legacy recovery originals are deliberately excluded from that portable export because they contain raw uptime. New-format recovery exports include their evidence.

Consumers must read column names and schema metadata, not assume hard-coded column positions. `Tools/validate_session.py` accepts original version 1, portable version 1, and version 2 exports.
