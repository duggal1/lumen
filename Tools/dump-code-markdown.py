#!/usr/bin/env python3
"""Write all source code in the selected Lumen modules to allcode.md."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "allcode.md"
FOLDERS = (
    "LumenDirector",
    "LumenCapture",
    "LumenAnalysis",
    "LumenProject",
    "LumenRender",
    "LumenAudio",
)
CODE_EXTENSIONS = {".swift", ".c", ".h", ".m", ".mm", ".metal", ".cpp", ".hpp"}
LANGUAGE_BY_EXTENSION = {
    ".swift": "swift",
    ".c": "c",
    ".h": "c",
    ".m": "objective-c",
    ".mm": "objective-c++",
    ".metal": "metal",
    ".cpp": "cpp",
    ".hpp": "cpp",
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


def main() -> None:
    sections = ["Hey, this is the folder, and this is the code file,", ""]
    count = 0

    for folder_name in FOLDERS:
        folder = ROOT / "Sources" / folder_name
        sections.extend((f"## {folder_name}/", ""))
        files = sorted(
            path for path in folder.rglob("*")
            if path.is_file() and path.suffix.lower() in CODE_EXTENSIONS
        )
        for path in files:
            source = path.read_text(encoding="utf-8")
            relative_path = path.relative_to(ROOT).as_posix()
            language = LANGUAGE_BY_EXTENSION.get(path.suffix.lower(), "")
            fence = fence_for(source)
            sections.extend((
                f"### {relative_path}",
                "",
                f"{fence}{language}",
                source.rstrip("\n"),
                fence,
                "",
            ))
            count += 1

    OUTPUT.write_text("\n".join(sections).rstrip() + "\n", encoding="utf-8")
    print(f"Wrote {count} code files to {OUTPUT}")


if __name__ == "__main__":
    main()
