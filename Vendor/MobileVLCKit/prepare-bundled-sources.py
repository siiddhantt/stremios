#!/usr/bin/env python3
"""Verify and prepare release sources locally. No downloads or compilation."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def extract(source, destination):
    with tarfile.open(source) as archive:
        # Python 3.12+ data filter rejects device nodes and escaping links.
        archive.extractall(destination, filter="data")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    destination = args.destination.expanduser().resolve()
    if destination.exists():
        raise SystemExit("Destination must not already exist")
    sums = json.loads((HERE / "SHA256SUMS.json").read_text())
    for name, expected in sums.items():
        path = (HERE / name).resolve()
        if not path.is_relative_to(HERE) or not path.is_file() or digest(path) != expected:
            raise SystemExit("Bundle checksum mismatch: " + name)
    pin = json.loads((HERE / "manifests/provenance.json").read_text())
    destination.mkdir(parents=True)
    for row in pin["sourceArchives"]:
        extract(HERE / "archives" / row["filename"], destination)
    kit = destination / ("vlckit-" + pin["sourceCorrespondence"]["vlckitCommit"])
    base = destination / ("vlc-" + pin["sourceCorrespondence"]["vlcBaseCommit"])
    vlc = kit / "libvlc/vlc"
    base.rename(vlc)
    patches = sorted((kit / "libvlc/patches").glob("*.patch"))
    if len(patches) != pin["sourceCorrespondence"]["patchCount"]:
        raise SystemExit("Patch set differs from the source pin")
    for patch in patches:
        subprocess.run(["git", "apply", "--whitespace=nowarn", str(patch)], cwd=vlc, check=True)
    tarballs = vlc / "contrib/tarballs"
    tarballs.mkdir(exist_ok=True)
    archives = list((HERE / "archives/contrib").iterdir())
    for archive in archives:
        shutil.copyfile(archive, tarballs / archive.name)
    # The library/build sources are unchanged. Only uncompiled test datasets
    # and Windows prebuilt material were removed from this one source archive.
    repack = json.loads((HERE / "manifests/mysofa-source-repack.json").read_text())
    sumfile = vlc / "contrib/src/mysofa/SHA512SUMS"
    text = sumfile.read_text()
    if text.count(repack["originalSHA512"]) != 1:
        raise SystemExit("Unexpected upstream mysofa checksum file")
    sumfile.write_text(text.replace(repack["originalSHA512"], repack["repackedSHA512"]))
    (kit / "SOURCE-BUNDLE-PACKAGING.txt").write_text(repack["reason"] + "\nOnly contrib/src/mysofa/SHA512SUMS is adjusted for that archive.\n")
    print("Prepared", len(patches), "upstream patches and", len(archives), "contrib source archives.")
    print("Source tree:", kit)
    print("Read SOURCE-AND-RELINKING.txt before invoking the upstream build.")

if __name__ == "__main__":
    main()
