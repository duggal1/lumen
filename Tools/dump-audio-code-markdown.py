#!/usr/bin/env python3
"""Write audio subsystem source files to audio-code-all.md."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "audio-code-all.md"
SOURCE_DIRS = (
    ROOT / "Sources/LumenAudio",
    ROOT / "Sources/LumenSpeech",
)
SUPPORT_FILES = (
    "Sources/LumenCore/Core.swift",
    "Sources/LumenProject/AnalysisTypes.swift",
    "Sources/LumenProject/Models.swift",
    "Sources/LumenProject/Derived.swift",
    "Sources/LumenProject/Composition.swift",
    "Sources/LumenProject/Commands.swift",
    "Sources/LumenProject/Editing.swift",
    "Sources/LumenCapture/Capture.swift",
    "Sources/LumenCapture/Session.swift",
    "Sources/LumenCapture/ExtraMicrophoneRecorder.swift",
    "Sources/LumenAnalysis/Speech.swift",
    "Sources/LumenAnalysis/Service.swift",
    "Sources/LumenDirector/Director.swift",
    "Sources/LumenDirector/Planner.swift",
    "Sources/LumenExport/ProjectSession.swift",
    "Sources/LumenExport/Exporter.swift",
    "Sources/CMoonshine/shim.c",
    "Sources/CMoonshine/include/CMoonshine.h",
    "Sources/CMoonshine/include/moonshine-c-api.h",
)
LANGUAGE_BY_EXTENSION = {
    ".swift": "swift",
    ".c": "c",
    ".h": "c",
    ".cc": "cpp",
    ".cpp": "cpp",
    ".hpp": "cpp",
    ".metal": "metal",
}


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


def collect_files() -> list[Path]:
    files: set[Path] = set()
    for source_dir in SOURCE_DIRS:
        if not source_dir.is_dir():
            raise FileNotFoundError(f"Audio source directory not found: {source_dir}")
        files.update(
            path for path in source_dir.rglob("*")
            if path.is_file() and path.suffix.lower() in LANGUAGE_BY_EXTENSION
        )

    for relative_path in SUPPORT_FILES:
        path = ROOT / relative_path
        if not path.is_file():
            raise FileNotFoundError(f"Audio support source file not found: {relative_path}")
        files.add(path)

    return sorted(files, key=lambda path: path.relative_to(ROOT).as_posix())


def main() -> None:
    files = collect_files()
    sections = ["# Lumen audio and speech backend", ""]
    for path in files:
        relative_path = path.relative_to(ROOT).as_posix()
        source = path.read_text(encoding="utf-8")
        fence = fence_for(source)
        language = LANGUAGE_BY_EXTENSION[path.suffix.lower()]
        sections.extend((
            f"## {relative_path}",
            "",
            f"{fence}{language}",
            source.rstrip("\n"),
            fence,
            "",
        ))

    OUTPUT.write_text("\n".join(sections).rstrip() + "\n", encoding="utf-8")
    print(f"Wrote {len(files)} audio source files to {OUTPUT}")


if __name__ == "__main__":
    main()
