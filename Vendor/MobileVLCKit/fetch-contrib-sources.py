#!/usr/bin/env python3
"""Fetch checksum-pinned source archives only; never build or execute their code."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
MAX_ARCHIVE_BYTES = 200 * 1024 * 1024

def digest(path, algorithm="sha512"):
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def fetch(row, cache):
    name = row["filename"]
    if Path(name).name != name:
        raise ValueError("Unsafe archive filename")
    target = cache / name
    if target.exists():
        if digest(target) != row["sha512"]:
            raise ValueError("Existing archive checksum differs: " + name)
        return {"package": row["package"], "filename": name, "sha512": row["sha512"],
                "sha256": digest(target, "sha256"), "bytes": target.stat().st_size}
    failures = []
    for url in row["urls"]:
        if not url.startswith("https://"):
            raise ValueError("Only HTTPS source downloads are permitted")
        descriptor, temporary = tempfile.mkstemp(prefix=".source-", dir=cache)
        try:
            with os.fdopen(descriptor, "wb") as output:
                request = urllib.request.Request(url, headers={"User-Agent": "StremIOS-source-bundle/1"})
                with urllib.request.urlopen(request, timeout=45) as response:
                    if not response.url.startswith("https://"):
                        raise ValueError("Source redirect did not retain HTTPS")
                    size = 0
                    while True:
                        data = response.read(1024 * 1024)
                        if not data:
                            break
                        size += len(data)
                        if size > MAX_ARCHIVE_BYTES:
                            raise ValueError("Source archive exceeds download bound")
                        output.write(data)
            temporary = Path(temporary)
            if digest(temporary) != row["sha512"]:
                raise ValueError("Downloaded source checksum differs")
            temporary.replace(target)
            return {"package": row["package"], "filename": name, "sha512": row["sha512"],
                    "sha256": digest(target, "sha256"), "bytes": target.stat().st_size,
                    "downloadURL": url}
        except Exception as error:
            failures.append(type(error).__name__)
        finally:
            Path(temporary).unlink(missing_ok=True)
    raise RuntimeError(name + ": source download failed (" + ", ".join(failures) + ")")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=HERE.parents[1] / ".cache/vlckit/contrib-sources")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    cache = args.cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    rows = json.loads((HERE / "contrib-sources.json").read_text())["contribSources"]
    results, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(6, args.jobs))) as pool:
        futures = {pool.submit(fetch, row, cache): row for row in rows}
        for future in concurrent.futures.as_completed(futures):
            row = futures[future]
            try:
                result = future.result()
                results.append(result)
                print("Verified", row["package"], result["bytes"], flush=True)
            except Exception as error:
                failures.append({"package": row["package"], "error": str(error)})
                print("FAILED", row["package"], str(error), flush=True)
    report = {"sources": sorted(results, key=lambda x: x["package"]), "failures": failures}
    (cache / "source-fetch-report.json").write_text(json.dumps(report, indent=2) + "\n")
    if failures:
        raise SystemExit(1)

if __name__ == "__main__":
    main()
