#!/usr/bin/env python3
"""Write the zoom and cursor motion source files to allcode.md."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "allcode.md"
FEATURE_FILES = (
    "Sources/LumenCore/Core.swift",
    "Sources/LumenCapture/Input.swift",
    "Sources/LumenProject/AnalysisTypes.swift",
    "Sources/LumenAnalysis/TypingAnalyzer.swift",
    "Sources/LumenAnalysis/TypingTracer.swift",
    "Sources/LumenDirector/ZeroPhase.swift",
    "Sources/LumenDirector/Planner.swift",
    "Sources/LumenDirector/Camera.swift",
    "Sources/LumenDirector/Cursor.swift",
    "Sources/LumenDirector/Director.swift",
    "Sources/LumenDirector/LiveCamera.swift",
    "Sources/LumenRender/ZoomTransform.swift",
)


def fence_for(source: str) -> str:
    longest = 0
    current = 0
    for character in source:
        if character == "`":
            current += 1
            longest = max(longest, current)
        else:
            current = 0
    return "`" * max(3, longest + 1)


def main() -> None:
    sections = ["# Zoom and cursor motion core", ""]

    for relative_path in FEATURE_FILES:
        path = ROOT / relative_path
        if not path.is_file():
            raise FileNotFoundError(f"Core feature source file not found: {relative_path}")

        source = path.read_text(encoding="utf-8")
        fence = fence_for(source)
        sections.extend((
            f"## {relative_path}",
            "",
            f"{fence}swift",
            source.rstrip("\n"),
            fence,
            "",
        ))

    OUTPUT.write_text("\n".join(sections).rstrip() + "\n", encoding="utf-8")
    print(f"Wrote {len(FEATURE_FILES)} core feature files to {OUTPUT}")


if __name__ == "__main__":
    main()
