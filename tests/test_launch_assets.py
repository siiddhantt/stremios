#!/usr/bin/env python3
"""Host-only launch-asset checks. Does not build, install, or launch an iOS app."""
import plistlib
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PLIST = ROOT / "Resources" / "Info.plist"


def png_size(path):
    with path.open("rb") as handle:
        header = handle.read(33)
    assert header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR"
    width, height = struct.unpack(">II", header[16:24])
    assert header[24] == 8 and header[25] == 2, "Launch images must be opaque RGB PNGs"
    return width, height


def main():
    original = SOURCE_PLIST.read_bytes()
    original_info = plistlib.loads(original)
    with tempfile.TemporaryDirectory(prefix="ministream-launch-") as temp:
        for mode in ("storyboard", "static-ipad12"):
            destination = Path(temp) / mode
            destination.mkdir()
            shutil.copyfile(SOURCE_PLIST, destination / "Info.plist")
            command = ["xcrun", "--sdk", "macosx", "swift", str(ROOT / "scripts" / "make_icons.swift"), str(destination)]
            if mode == "static-ipad12":
                command.append("--static-ipad12-launch")
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, result.stdout + result.stderr
            generated = plistlib.loads((destination / "Info.plist").read_bytes())
            for icon in ("Icon-76.png", "Icon-76@2x.png", "Icon-83.5@2x.png"):
                assert (destination / icon).is_file(), "Icon generation regressed"
            if mode == "storyboard":
                assert generated == original_info, "Default mode must preserve the source launch settings"
                assert not list(destination.glob("MiniStreamLaunch*"))
                continue
            assert "UILaunchStoryboardName" not in generated
            assert "UILaunchStoryboards" not in generated
            assert generated["UIRequiresFullScreen"] is True
            assert generated["UIDeviceFamily"] == [2]
            assert generated["MinimumOSVersion"] == "12.0"
            assert generated["UISupportedInterfaceOrientations~ipad"] == original_info["UISupportedInterfaceOrientations~ipad"]
            assert generated["UILaunchImages"] == generated["UILaunchImages~ipad"]
            entries = generated["UILaunchImages~ipad"]
            assert len(entries) == 4
            assert {e["UILaunchImageOrientation"] for e in entries} == {"Portrait", "PortraitUpsideDown", "LandscapeLeft", "LandscapeRight"}
            for entry in entries:
                assert entry["UILaunchImageSize"] == "{768, 1024}"
                assert entry["UILaunchImageMinimumOSVersion"] == "12.0"
                name = entry["UILaunchImageName"]
                assert Path(name).name == name and "@" not in name and "." not in name
                dimensions = png_size(destination / (name + "@2x.png"))
                expected = (1536, 2048) if entry["UILaunchImageOrientation"].startswith("Portrait") else (2048, 1536)
                assert dimensions == expected, (entry, dimensions)
            # Only the explicit launch configuration may change.
            launch_keys = {"UILaunchStoryboardName", "UILaunchStoryboards", "UILaunchImages", "UILaunchImages~ipad", "UIRequiresFullScreen"}
            assert {k: v for k, v in generated.items() if k not in launch_keys} == {k: v for k, v in original_info.items() if k not in launch_keys}
    assert SOURCE_PLIST.read_bytes() == original, "Asset generation must not modify source Info.plist"
    print("PASS host asset generation: default preserved; static Retina portrait/landscape dimensions, opaque PNGs, all four orientations and explicit full-screen metadata")
    print("NOT TESTED: iOS compilation, launch-image selection, full-canvas rendering, rotation or playback on the iPad")


if __name__ == "__main__":
    main()
