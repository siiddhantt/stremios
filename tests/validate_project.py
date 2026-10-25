#!/usr/bin/env python3
"""Offline checks, not an iOS build or runtime test. Python standard library only."""

import argparse
import hashlib
import json
import math
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit


DEMO_URL = "https://media.w3.org/2010/05/bunny/movie.mp4"
DEMO_DURATION = 596.48
LICENSE_URL = "https://peach.blender.org/about/"
PROVENANCE_URL = "https://www.w3.org/2010/05/video/mediaevents.html"
TARGET_VERSION = (12, 0)
DEVICE_VERSION = (12, 5, 8)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    require(path.is_file(), "Missing " + str(path))
    require(path.stat().st_size <= 32768, "Oversized JSON fixture/resource: " + str(path))
    return json.loads(path.read_text(encoding="utf-8"))


def public_https(value):
    require(isinstance(value, str), "Expected a URL string")
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and bool(parsed.hostname), "Expected HTTPS URL: " + value)
    require(not parsed.username and not parsed.password, "URL must not contain credentials")
    sensitive = {"token", "apikey", "api_key", "password", "auth", "authkey", "key"}
    require(not any(k.lower() in sensitive for k, _ in parse_qsl(parsed.query)),
            "Public demo/fixture must not contain token-like URL parameters")


def validate_fixtures(root):
    directory = root / "tests" / "fixtures"
    index = read_json(directory / "index.json")
    require(index.get("schema_version") == 1, "Unknown fixture index version")
    require(index.get("not_runtime_test_evidence") is True, "Fixtures need an explicit runtime disclaimer")
    entries = index.get("fixtures", [])
    require(len(entries) == 8, "Expected eight deliberately bounded protocol examples")
    filenames = [entry["file"] for entry in entries]
    require(len(set(filenames)) == len(filenames), "Duplicate fixture names")
    require(set(filenames) | {"index.json"} == {p.name for p in directory.glob("*.json")},
            "Unindexed or missing fixture JSON")
    require(sum(p.stat().st_size for p in directory.glob("*.json")) <= 65536,
            "Fixture bundle must remain small")
    loaded = {}
    for entry in entries:
        name = entry["file"]
        require(Path(name).name == name, "Fixture paths must be basenames")
        path = directory / name
        data = read_json(path)
        require(hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"],
                "Fixture changed without provenance update: " + name)
        public_https(entry["source_url"])
        require(bool(entry.get("notes")), "Missing fixture provenance notes")
        if entry["kind"].startswith("recorded_"):
            require(bool(entry.get("recorded_at")), "Recorded fixture needs a capture timestamp")
        else:
            require(bool(entry.get("constructed_at")), "Synthetic fixture needs a construction date")
        loaded[entry["kind"]] = data
    manifest = loaded["recorded_manifest"]
    require(manifest["id"] == "com.linvo.cinemeta", "Unexpected recorded manifest")
    require({"catalog", "meta"}.issubset(manifest["resources"]), "Missing catalog/meta declaration")
    require("stream" not in manifest["resources"], "Cinemeta is metadata, not a playable movie source")
    require(len(manifest["catalogs"]) == 2, "Manifest must remain a reduced example")
    require("search" in manifest["catalogs"][0]["extraSupported"], "Missing recorded search declaration")
    catalog = loaded["recorded_catalog"]["metas"]
    require(len(catalog) == 2, "Catalog fixture must remain bounded")
    for meta in catalog:
        require(all(meta.get(k) for k in ("id", "type", "name")), "Incomplete catalog metadata")
        public_https(meta["poster"])
    movie = loaded["recorded_movie_meta"]["meta"]
    require(movie["id"] == "tt1254207" and movie["videos"] == [], "Unexpected recorded Bunny metadata")
    episodes = loaded["recorded_series_meta"]["meta"]["videos"]
    require(len(episodes) == 2, "Series fixture must remain bounded")
    for episode in episodes:
        require(all(k in episode for k in ("id", "name", "season", "episode", "released")),
                "Episode fixture must demonstrate actual name/season/episode fields")
    stream = loaded["synthetic_verified_media"]["streams"]
    require(len(stream) == 1 and stream[0]["url"] == DEMO_URL, "Unexpected demo stream")
    public_https(stream[0]["url"])
    torrent = loaded["synthetic_unsupported_torrent"]["streams"][0]
    require(torrent["infoHash"] == "0" * 40 and "url" not in torrent, "Torrent case must remain non-resolvable test data")
    external = loaded["synthetic_unsupported_external"]["streams"][0]
    require(urlsplit(external["externalUrl"]).hostname == "example.invalid" and "url" not in external,
            "External case must remain a synthetic non-playable URL")
    headers = loaded["synthetic_unsupported_proxy_headers"]["streams"][0]
    require(urlsplit(headers["url"]).hostname == "example.invalid", "Header case must use a reserved domain")
    require(bool(headers["behaviorHints"]["proxyHeaders"]["request"]), "Missing custom-header example")
    demo = index["licensed_demo"]
    require(demo["stream_url"] == DEMO_URL and demo["license_url"] == LICENSE_URL,
            "Demo provenance mismatch")
    require(demo["provenance_url"] == PROVENANCE_URL and demo["license"] == "CC BY 3.0",
            "Missing verified provenance or license")
    require(demo["container"] == "MP4" and demo["resolution"] == [853, 480],
            "Demo must identify the checked 480p MP4 sample")
    require(demo["codec_families"] == ["H.264", "AAC"] and
            abs(demo["duration_seconds"] - DEMO_DURATION) < 0.01,
            "Demo codec and duration metadata must match the checked MP4")
    require(demo["range_requests_supported"] is True and demo["content_length_bytes"] == 249224577,
            "Missing verified MP4 range and size metadata")
    require(not any(key in demo for key in ("playlist_type", "variant_count", "client_preferred_max_resolution")),
            "Fixed MP4 metadata must not retain adaptive-playlist claims")
    print("PASS eight bounded reference fixtures, provenance hashes, and unsupported protocol examples (no live services)")


def version_tuple(value):
    return tuple(int(part) for part in str(value).split("."))


def validate_plist(path):
    require(path.is_file(), "Missing application Info.plist: " + str(path))
    with path.open("rb") as handle:
        data = plistlib.load(handle)
    require(version_tuple(data.get("MinimumOSVersion", "0")) == TARGET_VERSION,
            "MinimumOSVersion must be 12.0")
    require(data.get("UIDeviceFamily") == [2], "Application must target iPad")
    caps = data.get("UIRequiredDeviceCapabilities", [])
    required_caps = {k for k, v in caps.items() if v} if isinstance(caps, dict) else set(caps)
    require("arm64" in required_caps and required_caps <= {"arm64"},
            "Device requirements must retain A7-compatible arm64 without newer hardware requirements")
    require(bool(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", data.get("CFBundleIdentifier", ""))),
            "Invalid or unresolved bundle identifier")
    require(data.get("CFBundlePackageType") == "APPL", "Expected app bundle")
    ats = data.get("NSAppTransportSecurity", {})
    require(not any(ats.get(k) for k in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia",
                                       "NSAllowsArbitraryLoadsInWebContent", "NSAllowsLocalNetworking")),
            "Application must not relax ATS")
    require(not ats.get("NSExceptionDomains"), "Application needs no ATS domain exceptions")
    require(not data.get("UIBackgroundModes"), "Application does not request background execution")
    require(not any(k.endswith("UsageDescription") for k in data),
            "Application should not request camera, microphone, photo, location or other private-data permissions")
    print("PASS iOS 12 / iPad / arm64 metadata, ATS defaults, and minimal permissions")
    return data


def validate_demo(root, bundled=False):
    data = read_json((root if bundled else root / "Resources") / "DemoCatalog.json")
    require(isinstance(data.get("items"), list) and len(data["items"]) == 1,
            "Bundled demo resource must contain only the licensed Bunny sample")
    item = data["items"][0]
    require(item["id"] == "demo:big-buck-bunny", "Unexpected demo identity")
    require(item["streamURL"] == DEMO_URL, "Unexpected playback endpoint")
    require(item["format"] == "480p · H.264 / AAC · MP4",
            "Sample metadata must describe the verified fixed 480p MP4")
    public_https(item["streamURL"])
    require(item["license"] == "CC BY 3.0" and item["licenseURL"] == LICENSE_URL, "Missing Bunny license")
    require(item["sourceURL"] in {PROVENANCE_URL, LICENSE_URL}, "Unrecognized sample provenance")
    require("Blender Foundation" in item["attribution"] and "2008" in item["attribution"],
            "Missing creator/year attribution")
    require(item["year"] == 2008 and isinstance(item["duration"], (int, float)), "Incorrect demo metadata")
    require(math.isfinite(item["duration"]) and abs(item["duration"] - DEMO_DURATION) < 0.01,
            "Demo duration must match the checked MP4")
    print("PASS one public HTTPS demo with explicit license, provenance and attribution")


def run_policy_tests(root):
    compiler = shutil.which("clang")
    require(compiler is not None, "clang missing; cannot execute the production playback-policy tests")
    source = root / "Sources" / "MSPlaybackPolicy.c"
    require(source.is_file(), "Missing production playback policy: " + str(source))
    require((source.parent / "MSPlaybackPolicy.h").is_file(), "Missing playback-policy header")
    with tempfile.TemporaryDirectory(prefix="ministream-policy-") as temp:
        binary = Path(temp) / "test-playback-policy"
        command = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
                   "-I", str(source.parent), str(root / "tests" / "test_playback_policy.c"),
                   str(source), "-lm", "-o", str(binary)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        require(result.returncode == 0, "Playback-policy compilation failed:\n" + result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        require(result.returncode == 0, "Playback-policy cases failed:\n" + result.stdout + result.stderr)
        print(result.stdout.strip())


def run_library_store_tests(root):
    compiler = shutil.which("clang")
    require(compiler is not None, "clang missing; cannot execute Foundation library-store tests")
    sources = root / "Sources"
    require((sources / "MSLibraryStore.m").is_file(), "Missing production library store")
    with tempfile.TemporaryDirectory(prefix="ministream-library-") as temp:
        policy_object = Path(temp) / "policy.o"
        binary = Path(temp) / "test-library-store"
        commands = [
            [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-I", str(sources),
             "-c", str(sources / "MSPlaybackPolicy.c"), "-o", str(policy_object)],
            [compiler, "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-I", str(sources),
             str(root / "tests" / "test_library_store.m"), str(sources / "MSLibraryStore.m"),
             str(policy_object), "-framework", "Foundation", "-o", str(binary)]
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            require(result.returncode == 0, "Foundation library-store compilation failed:\n" + result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        require(result.returncode == 0, "Foundation library-store cases failed:\n" + result.stdout + result.stderr)
        print(result.stdout.strip())


def run_foundation_tests(root, suite, production_sources, frameworks=("Foundation",), compiler_flags=()):
    """Build isolated host tests; fixtures/mocks prevent live service access."""
    compiler = shutil.which("clang")
    require(compiler is not None, "clang missing; cannot execute Foundation " + suite + " tests")
    sources = root / "Sources"
    files = [root / "tests" / ("test_" + suite + ".m")]
    files += [sources / name for name in production_sources]
    for path in files:
        require(path.is_file(), "Missing Foundation test source: " + str(path))
    with tempfile.TemporaryDirectory(prefix="ministream-" + suite + "-") as temp:
        binary = Path(temp) / ("test-" + suite)
        objects = []
        for path in files:
            if path.suffix == ".c":
                obj = Path(temp) / (path.name + ".o")
                result = subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-c", str(path), "-o", str(obj)], capture_output=True, text=True, timeout=30)
                require(result.returncode == 0, "C helper compilation failed: " + result.stderr)
                objects.append(str(obj))
        command = [compiler, "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                   "-I", str(sources)] + list(compiler_flags) + [str(path) for path in files if path.suffix != ".c"] + objects
        for framework in frameworks:
            command += ["-framework", framework]
        command += ["-o", str(binary)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        require(result.returncode == 0, "Foundation " + suite + " compilation failed:\n" + result.stderr)
        result = subprocess.run([str(binary)], cwd=root, capture_output=True, text=True, timeout=30)
        require(result.returncode == 0, "Foundation " + suite + " cases failed:\n" + result.stdout + result.stderr)
        print(result.stdout.strip())


def validate_binary(app):
    info = validate_plist(app / "Info.plist")
    name = info.get("CFBundleExecutable", "")
    require(name and Path(name).name == name, "Invalid executable filename")
    with (app / name).open("rb") as handle:
        header = handle.read(32)
        require(len(header) == 32, "Truncated Mach-O header")
        magic, cpu, subtype, filetype, count, commands_size, _, _ = struct.unpack("<8I", header)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C and (subtype & 0xFFFFFF) == 0,
                "Expected a thin A7-compatible arm64 Mach-O, not simulator or arm64e")
        require(filetype == 2 and count < 4096 and commands_size < 1048576, "Invalid executable header")
        commands = handle.read(commands_size)
    offset = 0
    minimums = []
    for _ in range(count):
        require(offset + 8 <= len(commands), "Truncated Mach-O load command")
        command, size = struct.unpack_from("<2I", commands, offset)
        require(size >= 8 and offset + size <= len(commands), "Invalid load command size")
        if command == 0x32:
            require(size >= 24, "Truncated LC_BUILD_VERSION")
            platform, minimum = struct.unpack_from("<2I", commands, offset + 8)
            require(platform == 2, "Binary is not built for iOS devices")
            minimums.append(minimum)
        elif command == 0x25:
            require(size >= 16, "Truncated LC_VERSION_MIN_IPHONEOS")
            minimums.append(struct.unpack_from("<I", commands, offset + 8)[0])
        offset += size
    require(offset == commands_size and bool(minimums), "Missing or malformed minimum iOS load command")
    for packed in minimums:
        require((packed >> 16, (packed >> 8) & 255, packed & 255) <= DEVICE_VERSION,
                "Binary minimum OS is too new for iOS 12.5.8")
    require(not (app / "DemoCatalog.json").exists(), "Production payload must not include the retired demo catalog")
    print("PASS built payload architecture and minimum OS (signature/install/playback still unverified)")


def check_sdk(required):
    xcrun = shutil.which("xcrun")
    result = subprocess.run([xcrun, "--sdk", "iphoneos", "--show-sdk-path"],
                            capture_output=True, text=True, timeout=15) if xcrun else None
    available = bool(result and result.returncode == 0 and Path(result.stdout.strip()).is_dir())
    if not available:
        require(not required, "iPhoneOS SDK unavailable; install/select full Xcode before building")
        print("SKIP iOS compilation: iPhoneOS SDK unavailable; no app build or device validation claimed")
    else:
        print("INFO iPhoneOS SDK found; this validator has not compiled or signed the iOS app")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--fixtures-only", action="store_true", help="Validate only the offline reference data")
    parser.add_argument("--require-sdk", action="store_true", help="Fail if the iPhoneOS SDK is unavailable")
    parser.add_argument("--app", type=Path, help="Also inspect a built .app payload, without launching or installing it")
    args = parser.parse_args()
    root = args.project_root.resolve()
    checks = [("fixtures", lambda: validate_fixtures(root))]
    if not args.fixtures_only:
        checks += [("Info.plist", lambda: validate_plist(root / "Resources" / "Info.plist")),
                   ("demo resource", lambda: validate_demo(root)),
                   ("playback policy", lambda: run_policy_tests(root)),
                   ("library store", lambda: run_library_store_tests(root)),
                   ("catalog and stream", lambda: run_foundation_tests(root, "catalog_stream",
                       ["MSCatalogClient.m", "MSHTTPClient.m", "MSStream.m", "MSProviderURLRepair.m", "MSLibraryStore.m", "MSPlaybackPolicy.c", "MSAddons.m"], compiler_flags=("-DMS_ADDON_STORE_TESTING",))),
                   ("provider URL repair", lambda: run_foundation_tests(root, "provider_url_repair", ["MSProviderURLRepair.m"])),
                   ("HTTP transport", lambda: run_foundation_tests(root, "http_client", ["MSHTTPClient.m"])),
                   ("selected playback source", lambda: run_foundation_tests(root, "playback_source_resolver",
                       ["MSPlaybackSourceResolver.m", "MSHTTPClient.m"])),
                   ("subtitle parser", lambda: run_foundation_tests(root, "subtitles", ["MSSubtitles.m"])),
                   ("add-on protocol and storage", lambda: run_foundation_tests(root, "addons",
                       ["MSAddons.m"], compiler_flags=("-DMS_ADDON_STORE_TESTING",))),
                   ("TorBox setup", lambda: run_foundation_tests(root, "torbox_client", ["MSTorBoxClient.m"])),
                   ("playback preferences", lambda: run_foundation_tests(root, "playback_preferences", ["MSPlaybackPreferences.m", "MSColorPolicy.m", "MSVLCSubtitleStyle.m"])),
                   ("artwork cache", lambda: run_foundation_tests(root, "artwork_cache", ["MSArtworkCache.m"])),
                   ("SDK preflight", lambda: check_sdk(args.require_sdk))]
    if args.app:
        checks.append(("built payload", lambda: validate_binary(args.app.resolve())))
    failures = []
    for name, check in checks:
        try:
            check()
        except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, struct.error) as error:
            failures.append(name)
            print("FAIL " + name + ": " + str(error), file=sys.stderr)
    if failures:
        print("Validation failed: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("Offline validation passed. Live services, iPad UI, AVPlayer, iOS storage protection and lifecycle require separate device checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
