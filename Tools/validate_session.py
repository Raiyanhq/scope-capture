#!/usr/bin/env python3
"""Read-only, streaming verification of SCOPE Capture exports. Python 3.10+."""
import argparse
import csv
from datetime import datetime
import hashlib
import io
import json
import math
from pathlib import PurePosixPath
import zipfile

FIELDS = {
    "accelerometer": "x_g,y_g,z_g",
    "gyroscope": "x_rad_s,y_rad_s,z_rad_s",
    "magnetometer": "x_microtesla,y_microtesla,z_microtesla",
    "deviceMotion": "quaternion_x,quaternion_y,quaternion_z,quaternion_w,gravity_x_g,gravity_y_g,gravity_z_g,user_acceleration_x_g,user_acceleration_y_g,user_acceleration_z_g,rotation_x_rad_s,rotation_y_rad_s,rotation_z_rad_s",
    "location": "latitude_deg,longitude_deg,altitude_m,horizontal_accuracy_m,vertical_accuracy_m,speed_m_s,course_deg",
    "altitude": "relative_altitude_m,pressure_kpa",
    "steps": "run_cumulative_steps",
    "proximity": "near",
}

def require(condition, message):
    if not condition:
        raise ValueError(message)

def validate(path):
    with zipfile.ZipFile(path) as archive:
        names = [item.filename for item in archive.infolist() if not item.is_dir()]
        require(len(names) == len(set(names)), "Duplicate archive paths")
        for name in names:
            require(not name.startswith("/") and ".." not in PurePosixPath(name).parts, "Unsafe archive path")
        manifests = [name for name in names if PurePosixPath(name).name == "manifest.json" and "recovery-originals" not in PurePosixPath(name).parts]
        require(len(manifests) == 1, "Expected one session manifest")
        manifest_name = manifests[0]
        prefix = manifest_name[:-len("manifest.json")]
        with archive.open(manifest_name) as stream:
            manifest = json.load(stream)
        require(manifest["schemaVersion"] in (1, 2), "Unsupported format")
        records = manifest["files"]
        evidence = manifest.get("evidence") or []
        paths = [entry["path"] for entry in records + evidence]
        require(len(paths) == len(set(paths)), "Duplicate inventory paths")
        require(set(names) == {manifest_name} | {prefix+p for p in paths}, "Unlisted or missing files")
        summary = {}
        start = datetime.fromisoformat(manifest["startedAt"].replace("Z", "+00:00")).timestamp()
        for record in sorted(records, key=lambda value: value["path"]):
            sensor = record["sensor"]
            require(sensor in FIELDS, "Unknown sensor")
            digest = hashlib.sha256(); size = count = 0
            stats = summary.setdefault(sensor, {"samples":0, "first":None, "last":None, "sequence":None, "largest_gap_s":0})
            with archive.open(prefix+record["path"]) as stream:
                header_line = stream.readline()
                digest.update(header_line); size += len(header_line)
                header = header_line.decode().rstrip("\n").split(",")
                v2 = "collector_run" in header
                legacy_fields = FIELDS[sensor].replace("run_cumulative_steps", "cumulative_steps")
                expected = ("sequence,elapsed_s,utc_epoch_s,received_elapsed_s,collector_run," + FIELDS[sensor]).split(",") if v2 else (("sequence,source_time_s,elapsed_s,utc_epoch_s," if "source_time_s" in header else "sequence,elapsed_s,utc_epoch_s,") + legacy_fields).split(",")
                require(header == expected, f"Unexpected header: {record['path']}")
                for line in stream:
                    digest.update(line); size += len(line)
                    require(line.endswith(b"\n"), "Incomplete final row")
                    values = [float(value) for value in next(csv.reader([line.decode()]))]
                    require(len(values) == len(header) and all(math.isfinite(value) for value in values), "Invalid numeric row")
                    row = dict(zip(header, values)); sequence, elapsed = row["sequence"], row["elapsed_s"]
                    require(sequence > 0 and sequence.is_integer() and elapsed >= 0, "Invalid sequence/time")
                    if stats["sequence"] is not None:
                        require(sequence == stats["sequence"] + 1 and elapsed >= stats["last"], "Sequence/time discontinuity")
                        stats["largest_gap_s"] = max(stats["largest_gap_s"], elapsed-stats["last"])
                    if v2:
                        require(row["collector_run"] >= 1 and row["collector_run"].is_integer(), "Invalid collector run")
                        require(elapsed <= row["received_elapsed_s"] + 0.25, "Measurement after arrival tolerance")
                        require(abs(row["utc_epoch_s"] - (start+elapsed)) < 0.002, "UTC/elapsed anchor mismatch")
                    if stats["first"] is None: stats["first"] = elapsed
                    stats["last"] = elapsed; stats["sequence"] = sequence
                    count += 1; stats["samples"] += 1
            require(count == record["samples"] and size == record["bytes"] and digest.hexdigest() == record["sha256"], f"Inventory/hash mismatch: {record['path']}")
        for record in evidence:
            digest = hashlib.sha256(); size = 0
            with archive.open(prefix+record["path"]) as stream:
                while chunk := stream.read(65536): digest.update(chunk); size += len(chunk)
            require(size == record["bytes"] and digest.hexdigest() == record["sha256"], "Recovery evidence mismatch")
        for stats in summary.values():
            span = (stats["last"] or 0) - (stats["first"] or 0)
            stats["observed_hz"] = (stats["samples"]-1)/span if span > 0 else None
        return {"session_id":manifest["id"], "state":manifest["state"], "schema_version":manifest["schemaVersion"],
                "csv_files":len(records), "samples":sum(row["samples"] for row in summary.values()),
                "integrity":"passed", "sensors":summary}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    args = parser.parse_args()
    try: print(json.dumps(validate(args.archive), indent=2))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Validation failed: {error}\n")
