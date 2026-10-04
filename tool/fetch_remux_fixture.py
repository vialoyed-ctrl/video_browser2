"""Fetch a few public HLS packets for technical validation; never publish media."""
import json
import os
import re
import urllib.request
from pathlib import Path
from urllib.parse import urljoin

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": "https://cn.pornhub.com/"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()

page = fetch(os.environ["REMUX_TEST_PAGE"]).decode("utf8", "replace")
match = re.search(r'"mediaDefinitions"\s*:', page)
if not match:
    raise RuntimeError("Source metadata unavailable")
start = page.index("[", match.end())
media, _ = json.JSONDecoder().raw_decode(page[start:])
entry = next(m for m in media if m.get("format") == "hls" and str(m.get("quality")) == "720")
url = entry["videoUrl"]
for _ in range(4):
    playlist = fetch(url).decode("utf8")
    lines = [s.strip() for s in playlist.splitlines() if s.strip()]
    links = [s for s in lines if not s.startswith("#")]
    if "#EXT-X-STREAM-INF" in playlist:
        url = urljoin(url, links[0])
        continue
    if "#EXT-X-KEY" in playlist or "#EXT-X-MAP" in playlist:
        raise RuntimeError("Fixture is not clear MPEG-TS")
    target = Path("build/remux-native-test/source.ts")
    with target.open("wb") as output:
        for link in links[:3]:
            output.write(fetch(urljoin(url, link)))
    print("Source sample fetched:", target.stat().st_size, "bytes; first", min(3, len(links)), "segments")
    break
else:
    raise RuntimeError("Media playlist not found")
