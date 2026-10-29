"""Fetch the iot-benchmark build that matches the database version.

The project publishes one prebuilt package per database line --
``iot-benchmark-iotdb-1.3-java17.zip`` and ``iot-benchmark-iotdb-2.0-java17.zip``
-- so "use the matching benchmark" is literally a matter of picking the right
asset.  A build that installs only the 2.0 asset looks complete (it has
``benchmark.sh``, a ``lib/`` full of jars) and then cannot talk to a 1.x
database at all.

Network access is confined to this module; the name/pick logic is pure so it can
be tested without one.
"""

from __future__ import annotations

import json
import shutil
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from .dbversion import BenchmarkProfile

RELEASES_API = "https://api.github.com/repos/thulab/iot-benchmark/releases"
DEFAULT_JAVA_TAG = "java17"


class FetchError(RuntimeError):
    """A benchmark package could not be located or installed."""


def asset_name(profile: BenchmarkProfile, *, java_tag: str = DEFAULT_JAVA_TAG) -> str:
    """The release asset that carries ``profile``'s module."""
    return f"iot-benchmark-{profile.module}-{java_tag}.zip"


def pick_asset(release: dict, profile: BenchmarkProfile, *, java_tag: str = DEFAULT_JAVA_TAG) -> dict | None:
    """Find this line's asset in a GitHub release payload.

    Returns the asset dict (with ``name`` and ``browser_download_url``), or None
    when the release does not carry it.
    """
    wanted = asset_name(profile, java_tag=java_tag)
    for asset in release.get("assets") or []:
        if asset.get("name") == wanted:
            return asset
    return None


def describe_release(release: dict) -> str:
    return f"{release.get('tag_name', '?')} ({release.get('name', '')})"


def fetch_releases(*, tag: str = "", timeout: int = 60) -> dict:
    """One release (the newest, or ``tag``) from the GitHub API."""
    url = f"{RELEASES_API}/tags/{tag}" if tag else f"{RELEASES_API}/latest"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "iotdb-remove-cn-dn-skill",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise FetchError(
            f"GitHub returned HTTP {exc.code} for {url}"
            + (" (is the tag spelled correctly?)" if tag else "")
        ) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FetchError(f"cannot reach {url}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise FetchError(f"unexpected response from {url}: {exc}") from exc


def download(
    url: str, dest: Path, *, expected_size: int = 0, timeout: int = 1800, attempts: int = 4
) -> Path:
    """Download ``url`` to ``dest``, reusing an existing file of the same size.

    Release assets come off a CDN that intermittently refuses or drops a
    connection, so a single attempt is not enough; each retry starts from scratch
    and the partial file is removed first.

    The cache is consulted *before* any connection is made, using the size from
    the release metadata rather than the response headers: a host with no route
    to the CDN must still be able to use a package it already has.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    if expected_size and dest.is_file() and dest.stat().st_size == expected_size:
        return dest
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return _download_once(url, dest, expected_size=expected_size, timeout=timeout)
        except FetchError as exc:
            last = exc
            if attempt < attempts:
                delay = min(5 * attempt, 20)
                print(
                    f"  download attempt {attempt}/{attempts} failed ({exc}); "
                    f"retrying in {delay}s",
                    flush=True,
                )
                time.sleep(delay)
    raise FetchError(f"cannot download {url} after {attempts} attempts: {last}")


def _download_once(url: str, dest: Path, *, expected_size: int = 0, timeout: int) -> Path:
    request = urllib.request.Request(url, headers={"User-Agent": "iotdb-remove-cn-dn-skill"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            expected = int(response.headers.get("Content-Length") or 0) or expected_size
            if dest.is_file() and expected and dest.stat().st_size == expected:
                return dest
            tmp = dest.with_suffix(dest.suffix + ".part")
            with tmp.open("wb") as handle:
                shutil.copyfileobj(response, handle)
            got = tmp.stat().st_size
            if expected and got != expected:
                tmp.unlink(missing_ok=True)
                raise FetchError(f"short download: got {got} bytes, expected {expected}")
            tmp.replace(dest)
    except urllib.error.HTTPError as exc:
        raise FetchError(f"HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FetchError(str(exc)) from exc
    return dest


def install_zip(zip_path: Path, bm_home: Path) -> Path:
    """Unpack a benchmark zip so that ``bm_home/benchmark.sh`` exists.

    The archives hold a single top-level directory; it is flattened into
    ``bm_home`` so callers get a stable path regardless of the archive's naming.
    """
    if bm_home.exists():
        shutil.rmtree(bm_home)
    staging = bm_home.with_name(bm_home.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(staging)
    except zipfile.BadZipFile as exc:
        raise FetchError(f"{zip_path} is not a readable zip: {exc}") from exc
    entries = [p for p in staging.iterdir()]
    if len(entries) != 1 or not entries[0].is_dir():
        raise FetchError(
            f"expected exactly one top-level directory in {zip_path}, found "
            f"{[p.name for p in entries]}"
        )
    # shutil.move, not Path.replace: the staging directory and the install
    # target are frequently on different filesystems (a /tmp cache unpacked into
    # /data), and a rename across devices fails with EXDEV.
    shutil.move(str(entries[0]), str(bm_home))
    staging.rmdir()
    if not (bm_home / "benchmark.sh").is_file():
        raise FetchError(f"{bm_home} has no benchmark.sh after unpacking {zip_path}")
    return bm_home


def default_home(root: Path, release: dict, *, java_tag: str = DEFAULT_JAVA_TAG) -> Path:
    """A conventional install path for a release, e.g. ``bm_2026-09-15_46fc572e_java17``."""
    tag = str(release.get("tag_name") or "unknown")
    return root / f"bm_{tag}_{java_tag}"
