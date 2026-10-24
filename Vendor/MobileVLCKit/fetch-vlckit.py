#!/usr/bin/env python3
"""Fetch pinned VideoLAN binaries/sources; never runs downloaded code or installs an app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
PIN = json.loads((HERE / "provenance.json").read_text())


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def obtain(cache, item):
    target = cache / item["filename"]
    if target.exists():
        if target.is_symlink() or digest(target) != item["sha256"]:
            raise ValueError("Existing cache file differs from the pinned hash: " + target.name)
        return target
    descriptor, temporary = tempfile.mkstemp(prefix=".download-", dir=cache)
    try:
        request = urllib.request.Request(item["url"], headers={"User-Agent": "StremIOS-dependency-fetch/1"})
        with os.fdopen(descriptor, "wb") as out, urllib.request.urlopen(request, timeout=60) as response:
            if not response.geturl().startswith("https://"):
                raise ValueError("Dependency download did not retain HTTPS")
            count = 0
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > item["bytes"]:
                    raise ValueError("Dependency exceeds its recorded size")
                out.write(chunk)
        path = Path(temporary)
        if path.stat().st_size != item["bytes"] or digest(path) != item["sha256"]:
            raise ValueError("Dependency checksum or length mismatch")
        # A failed verification never replaces an existing cache artifact.
        path.replace(target)
        return target
    finally:
        Path(temporary).unlink(missing_ok=True)


def prepare_framework(cache, archive):
    target = cache / "arm64" / "MobileVLCKit.framework"
    expected = PIN["arm64BinarySHA256"]
    if target.exists():
        if target.is_symlink() or digest(target / "MobileVLCKit") != expected:
            raise ValueError("Existing framework differs from the pinned arm64 framework")
        verify_framework_files(target)
        return target
    prefix = "MobileVLCKit-binary/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework/"
    with tempfile.TemporaryDirectory(prefix=".extract-", dir=cache) as temporary:
        stage = Path(temporary) / "MobileVLCKit.framework"
        stage.mkdir()
        with tarfile.open(archive, "r:xz") as tar:
            for member in tar:
                if not member.name.startswith(prefix):
                    continue
                relative = Path(member.name[len(prefix):])
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("Unsafe archive member")
                destination = stage / relative
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as source, destination.open("wb") as out:
                        shutil.copyfileobj(source, out)
                else:
                    raise ValueError("Unexpected link or special archive member")
        binary = stage / "MobileVLCKit"
        thin = stage / "MobileVLCKit.arm64"
        subprocess.run(["xcrun", "lipo", str(binary), "-thin", "arm64", "-output", str(thin)], check=True)
        if digest(thin) != expected:
            raise ValueError("Extracted arm64 framework does not match the verified binary")
        thin.replace(binary)
        binary.chmod(0o755)
        verify_framework_files(stage)
        target.parent.mkdir(parents=True, exist_ok=True)
        stage.rename(target)
    return target


def verify_framework_files(framework):
    for name, expected in PIN["frameworkFilesSHA256"].items():
        path = framework / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError("Framework header/metadata differs from the pinned package: " + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    # Keep fetched dependencies private to this checkout, not its parent tree.
    default_cache = HERE.parents[1] / ".cache" / "vlckit"
    parser.add_argument("--cache", type=Path, default=default_cache,
                        help="Dependency cache (default: project/.cache/vlckit)")
    parser.add_argument("--sources", action="store_true", help="Also download the two immutable source archives")
    args = parser.parse_args()
    cache = args.cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    archive = obtain(cache, PIN["binaryArchive"])
    framework = prepare_framework(cache, archive)
    if args.sources:
        for item in PIN["sourceArchives"]:
            print("Verified source:", obtain(cache, item))
    print("Verified arm64 framework:", framework)
    print("Build override: MS_VLCKIT_FRAMEWORK=" + str(framework))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        raise SystemExit("Dependency preparation failed: " + str(error))
