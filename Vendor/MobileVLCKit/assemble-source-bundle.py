#!/usr/bin/env python3
"""Assemble verified VideoLAN sources and notices. Does not compile or publish."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]

def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def source_map(archive):
    result = {}
    for member in archive.getmembers():
        if member.isfile():
            result[member.name.split("/", 1)[-1]] = member
    return result

def license_comments(data):
    text = data.decode("utf-8", errors="replace")
    # Copyright preambles may follow a short description or an include guard.
    found = []
    for match in re.finditer(r"/\*.*?\*/", text[:24000], re.S):
        value = match.group(0)
        if any(word in value.lower() for word in ("copyright", "redistribution and use", "permission is hereby granted")):
            found.append(value)
    return "\n\n".join(found)

def application_notices():
    value = (PROJECT / "Resources/ThirdPartyNotices.txt").read_text()
    # A release build installs this script's complete output in Resources.
    # Recover its base section on later runs instead of nesting old bundles.
    def heading(title):
        return "=" * 72 + "\n" + title + "\n" + "=" * 72 + "\n\n"
    first = heading("Existing application/library/icon notices")
    last = heading("Additional VideoLAN dependency notices")
    if first in value:
        if value.count(first) != 1 or value.count(last) != 1:
            raise SystemExit("Ambiguous previously generated application notices")
        return value.split(first, 1)[1].split(last, 1)[0].rstrip()
    return value.rstrip()

def repack_mysofa(source, target):
    omitted, retained = [], []
    with tarfile.open(source) as original, tarfile.open(target, "w:gz", format=tarfile.PAX_FORMAT) as packed:
        for member in original:
            relative = member.name.split("/", 1)[-1]
            # BUILD_TESTS=OFF in the exact upstream iOS recipe. Keep source,
            # build files, installed share data and license files; omit only
            # unrelated acoustic test fixtures and Windows prebuilt material.
            omit = relative.startswith("windows/") or (relative.startswith("tests/") and not (
                relative.split("/")[-1].startswith(("LICENSE", "README")) or relative.endswith(".sh")))
            if omit:
                omitted.append({"path": relative, "bytes": member.size})
                continue
            data = original.extractfile(member) if member.isfile() else None
            packed.addfile(member, data)
            if member.isfile():
                retained.append({"path": relative, "sha256": hashlib.sha256(original.extractfile(member).read()).hexdigest()})
    return {"originalSHA512": digest(source, "sha512"), "repackedSHA512": digest(target, "sha512"),
            "repackedSHA256": digest(target), "omitted": omitted, "retainedFiles": retained,
            "reason": "No library code changed. The pinned iOS recipe sets BUILD_TESTS=OFF; uncompiled test datasets and Windows prebuilt files are omitted."}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contrib-cache", required=True, type=Path)
    parser.add_argument("--upstream-cache", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    bundle = output / "StremIOS-0.8.3-beta.1-playback-sources"
    if bundle.exists():
        raise SystemExit("Bundle directory already exists; choose a fresh output directory")
    (bundle / "archives/contrib").mkdir(parents=True)
    (bundle / "notices").mkdir()
    (bundle / "manifests").mkdir()
    pin = json.loads((HERE / "provenance.json").read_text())
    manifest = json.loads((HERE / "contrib-sources.json").read_text())
    selections = json.loads((HERE / "runtime-notice-files.json").read_text())
    parts = [("StremIOS application", (PROJECT / "LICENSE").read_text()),
             ("Existing application/library/icon notices", application_notices()),
             ("Additional VideoLAN dependency notices", "These notices cover the pinned arm64 iOS contrib build closure. Some build-only or stripped components are included conservatively. Per-component licenses remain separate; this does not relicense the MIT application. Source-only tools, tests and examples in the source archives can have other licenses.\n\nThis software is based in part on the work of the Independent JPEG Group. StremIOS makes no changes to FFmpeg's IJG-derived files; upstream changes remain identified in the supplied source.\nPortions of this software are copyright The FreeType Project (https://freetype.org/). All rights reserved. FreeType is used under the FreeType License.\nLAME is used under its library license: https://lame.sourceforge.io/.\n\nCorresponding source, notices and replacement instructions: https://github.com/siiddhantt/stremios/releases/tag/v0.8.3-beta.1\n")]
    inventory = []
    for item in pin["sourceArchives"]:
        source = args.upstream_cache / item["filename"]
        if not source.is_file() or digest(source) != item["sha256"]:
            raise SystemExit("Upstream source missing or checksum differs: " + item["filename"])
        shutil.copyfile(source, bundle / "archives" / item["filename"])
        # The library itself also contains permissively licensed helpers,
        # such as VLC's Opus header parser. Preserve their full preambles.
        # Conservative inclusion is preferable to guessing linker retention.
        if item["repository"] == "videolan/vlc":
            entries = []
            seen = set()
            with tarfile.open(source) as archive:
                for name, member in source_map(archive).items():
                    if not name.startswith(("src/", "modules/", "compat/", "include/")) or not name.endswith((".c", ".h", ".cpp", ".hpp", ".m")):
                        continue
                    value = license_comments(archive.extractfile(member).read())
                    if any(phrase in value.lower() for phrase in ("redistribution and use", "permission is hereby granted")) and value not in seen:
                        entries.append("--- " + name + " ---\n" + value)
                        seen.add(value)
            core_text = "Conservatively retained permissive source notices; inclusion does not assert every platform-specific file is linked.\n\n" + "\n\n".join(entries)
            (bundle / "notices/vlc-permissive-helpers.txt").write_text(core_text + "\n")
            parts.append(("VLC permissive helpers", core_text))
    for row in manifest["contribSources"]:
        source = args.contrib_cache / row["filename"]
        if not source.is_file() or digest(source, "sha512") != row["sha512"]:
            raise SystemExit("Contrib source missing or checksum differs: " + row["filename"])
        package = row["package"]
        destination = bundle / "archives/contrib" / row["filename"]
        if package == "mysofa":
            repack = repack_mysofa(source, destination)
            (bundle / "manifests/mysofa-source-repack.json").write_text(json.dumps(repack, indent=2) + "\n")
        else:
            shutil.copyfile(source, destination)
        notice_entries = []
        with tarfile.open(source) as archive:
            files = source_map(archive)
            selected = list(selections["fullTexts"][package])
            # Include bundled permissive dependencies, even where linker
            # stripping makes their exact retention impossible to prove.
            if package in ("aom", "vpx", "openjpeg"):
                selected += [name for name in files if name.startswith(("third_party/", "thirdparty/")) and
                             any(word in name.rsplit("/", 1)[-1].lower() for word in ("license", "copying", "patents"))]
            for name in sorted(set(selected)):
                if name not in files:
                    raise SystemExit("Missing selected notice: " + package + "/" + name)
                text = archive.extractfile(files[name]).read().decode("utf-8", errors="replace")
                notice_entries.append((name, text))
            header_names = list(selections["sourceHeaders"].get(package, []))
            if package in selections.get("scanLibraryHeaders", []):
                header_names += [name for name in files if name.startswith("libarchive/") and name.count("/") == 1 and name.endswith((".c", ".h"))]
            seen = set()
            for name in sorted(set(header_names)):
                if name not in files:
                    raise SystemExit("Missing selected source header: " + package + "/" + name)
                text = license_comments(archive.extractfile(files[name]).read())
                if text and text not in seen:
                    notice_entries.append((name + " (copyright/license preamble)", text))
                    seen.add(text)
            # Mbed TLS' license file identifies the license; its source
            # preambles identify the authors. Preserve that attribution too.
            if package == "librist":
                notice_entries.append(("Mbed TLS attribution", "Copyright The Mbed TLS Contributors. Bundled by upstream librist; Apache License 2.0 follows in the retained LICENSE text."))
        package_text = "\n\n".join("--- " + name + " ---\n" + text for name, text in notice_entries)
        (bundle / "notices" / (package + ".txt")).write_text(package_text + "\n")
        parts.append((package + " — " + row["filename"], package_text))
        inventory.append({"package": package, "filename": row["filename"], "originalSHA512": row["sha512"],
                          "distributedSHA256": digest(destination), "distributedBytes": destination.stat().st_size,
                          "repacked": package == "mysofa", "notices": [name for name, _ in notice_entries]})
    combined = "\n\n".join("=" * 72 + "\n" + title + "\n" + "=" * 72 + "\n\n" + text for title, text in parts) + "\n"
    (output / "THIRD-PARTY-NOTICES.txt").write_text(combined)
    (bundle / "THIRD-PARTY-NOTICES.txt").write_text(combined)
    (bundle / "manifests/source-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    for name in ("provenance.json", "contrib-sources.json", "binary-component-evidence.json", "runtime-notice-files.json"):
        shutil.copyfile(HERE / name, bundle / "manifests" / name)
    for name in ("prepare-bundled-sources.py", "SOURCE-AND-RELINKING.txt"):
        shutil.copyfile(HERE / name, bundle / name)
    shutil.copyfile(HERE / "SOURCE-AND-RELINKING.txt", output / "SOURCE-AND-RELINKING.txt")
    print("Notices and source instructions are ready:", output, flush=True)
    sums = {str(path.relative_to(bundle)): digest(path) for path in sorted(bundle.rglob("*")) if path.is_file()}
    (bundle / "SHA256SUMS.json").write_text(json.dumps(sums, indent=2) + "\n")
    archive_path = output / (bundle.name + ".tar.xz")
    with tarfile.open(archive_path, "w:xz", preset=0) as archive:
        archive.add(bundle, arcname=bundle.name)
    with tarfile.open(archive_path) as archive:
        for member in archive:
            if member.isfile():
                relative = str(Path(member.name).relative_to(bundle.name))
                expected = digest(bundle / relative)
                if hashlib.sha256(archive.extractfile(member).read()).hexdigest() != expected:
                    raise SystemExit("Final source archive integrity check failed: " + relative)
    report = {"archive": archive_path.name, "sha256": digest(archive_path), "bytes": archive_path.stat().st_size,
              "contribCount": len(inventory), "noticesSHA256": digest(output / "THIRD-PARTY-NOTICES.txt"),
              "noticesBytes": (output / "THIRD-PARTY-NOTICES.txt").stat().st_size,
              "sourceInstructionsSHA256": digest(output / "SOURCE-AND-RELINKING.txt")}
    (output / "videolan-source-bundle-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
