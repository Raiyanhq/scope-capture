"""Generate the complete source companion from the shipped files."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parts = ["# SCOPE Capture 1.2 — complete code\n\nReplace each existing file completely. Add SessionArchive.swift, SensorsView.swift, and ExportView.swift to your app target. Keep only one @main app file. Read README_FIRST.md before installing to preserve your existing recordings.\n"]
for path in sorted((root / "Sources").rglob("*.swift")):
    parts.append(f"\n## {path.relative_to(root).as_posix()}\n\n```swift\n{path.read_text()}\n```\n")
(root / "ALL_COMPLETE_CODE.md").write_text("".join(parts))
