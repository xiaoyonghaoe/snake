#!/usr/bin/env python3
"""Collect pinned normal/build dependency notices; exclude dev/other platforms."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess


def collect(destination: Path, target: str):
    root = Path(__file__).resolve().parent.parent
    metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--offline", "--format-version", "1",
        "--filter-platform", target,
        "--manifest-path", str(root / "Rust/snake_core/Cargo.toml"),
    ]))
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    selected = set()
    pending = [metadata["resolve"]["root"]]
    while pending:
        item = pending.pop()
        if item in selected:
            continue
        selected.add(item)
        pending.extend(d["pkg"] for d in nodes[item]["deps"]
                       if any(k["kind"] != "dev" for k in d["dep_kinds"]))

    destination.mkdir(parents=True, exist_ok=True)
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, destination / name)
    for name in ("Bonsplit", "SwiftTerm", "TokyoNight"):
        out = destination / name
        out.mkdir()
        shutil.copy2(root / "Vendor" / name / "LICENSE", out / "LICENSE")
    for name in ("README.md", "tokyonight_day.conf", "tokyonight_night.conf"):
        path = root / "Vendor/TokyoNight" / name
        if path.exists():
            shutil.copy2(path, destination / "TokyoNight" / name)
    # Preserve original generated palette notices regardless of filename.
    for path in (root / "Vendor/TokyoNight").glob("*.conf"):
        shutil.copy2(path, destination / "TokyoNight" / path.name)
    shutil.copy2(root / "Vendor/SwiftTerm/LOCAL_CHANGES.md", destination / "SwiftTerm")
    shutil.copy2(root / "Vendor/Bonsplit/CHANGES-SNAKE.md", destination / "Bonsplit")

    rows = ["# Resolved Cargo dependency notices", "",
            f"Target: `{target}`. Includes normal and build dependencies; excludes dev dependencies.",
            "Build dependencies are included conservatively, not all are embedded in the executable.",
            "Sources are unmodified registry packages pinned by Cargo.lock.", "",
            "| Package | License | Source |", "| --- | --- | --- |"]
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
        if package["id"] not in selected or package["id"] == metadata["resolve"]["root"]:
            continue
        name, version = package["name"], package["version"]
        source = Path(package["manifest_path"]).parent
        out = destination / "Cargo" / f"{name}-{version}"
        out.mkdir(parents=True)
        files = {p for p in source.iterdir() if p.is_file() and
                 p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "UNLICENSE"))}
        if package.get("license_file"):
            files.add(source / package["license_file"])
        native = {"libssh2-sys": "libssh2/COPYING", "openssl-src": "openssl/LICENSE.txt"}
        if name in native:
            files.add(source / native[name])
        for path in files:
            shutil.copy2(path, out / str(path.relative_to(source)).replace("/", "__"))
        if name == "libsqlite3-sys":
            amalgamation = (source / "sqlite3/sqlite3.c").read_text()
            notice = next((block for block in re.findall(r"/\*.*?\*/", amalgamation, re.S)
                           if "The author disclaims copyright" in block), None)
            if not notice:
                raise RuntimeError("SQLite public-domain dedication missing")
            (out / "SQLITE-PUBLIC-DOMAIN.txt").write_text(notice + "\n")
        if not files and name.startswith("uniffi") and version == "0.29.5":
            shutil.copy2(root / "Resources/Licenses/UniFFI/LICENSE", out / "LICENSE")
            shutil.copy2(root / "Resources/Licenses/UniFFI/README.md", out / "PROVENANCE.md")
        elif not files:
            raise RuntimeError(f"Missing license text: {name} {version}")
        rows.append(f"| {name} {version} | {package['license']} | "
                    f"[source](https://crates.io/api/v1/crates/{name}/{version}/download) |")
    (destination / "CARGO_LICENSES.md").write_text("\n".join(rows) + "\n")
    shutil.copy2(root / "Rust/snake_core/Cargo.lock", destination / "Cargo.lock")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    collect(args.destination, args.target)
