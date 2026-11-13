#!/usr/bin/env python3
"""Download a curated orchestral selection with attribution metadata."""
import csv
import os
import tempfile
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1] / "App/public/assets/music"
TRACKS = (
    ("tension", "Black Vortex", "USUAN1300037"),
    ("calm", "Majestic Hills", "USUAN1100423"),
    ("calm", "Juniper", "USUAN1100186"),
    ("epic", "Noble Race", "USUAN1100888"),
)
FIELDS = ("mood", "title", "uploader", "license", "url")


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    credits = ROOT / "credits.csv"
    with credits.open(encoding="utf-8", newline="") if credits.exists() else open(os.devnull) as source:
        rows = list(csv.DictReader(source)) if credits.exists() else []
    for mood, title, isrc in TRACKS:
        directory = ROOT / mood
        directory.mkdir(parents=True, exist_ok=True)
        destination = directory / f"{title} - Kevin MacLeod [{isrc}].mp3"
        source_url = f"https://incompetech.com/music/royalty-free/mp3-royaltyfree/{quote(title)}.mp3"
        page = f"https://incompetech.com/music/royalty-free/index.html?isrc={isrc}"
        if not destination.exists():
            temporary = None
            try:
                with urlopen(source_url, timeout=60) as response, tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
                    temporary = Path(output.name)
                    while chunk := response.read(1024 * 1024):
                        output.write(chunk)
                temporary.replace(destination)
            finally:
                if temporary and temporary.exists():
                    temporary.unlink()
        destination.chmod(0o644)
        if not any(row.get("url") == page for row in rows):
            rows.append(dict(zip(FIELDS, (mood, title, "Kevin MacLeod", "CC BY 4.0", page))))
        print(destination)
    with credits.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
