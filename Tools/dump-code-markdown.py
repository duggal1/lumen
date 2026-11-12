#!/usr/bin/env python3
"""Write Lumen source code to allcode.md."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "Sources"
OUTPUT = ROOT / "allcode.md"
CODE_EXTENSIONS = {".swift", ".metal", ".c", ".h"}
LANGUAGE_BY_EXTENSION = {
    ".swift": "swift",
    ".metal": "metal",
    ".c": "c",
    ".h": "c",
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
    folders = sorted(
        path for path in SOURCE_ROOT.iterdir()
        if path.is_dir() and path.name.startswith("Lumen")
    )
    sections = ["# Lumen source code", ""]
    count = 0

    for folder in folders:
        folder_name = folder.name
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
