#!/usr/bin/env python3
"""자동 업데이트 목록(appcast.xml) 만들기 — 서버 없이 GitHub 릴리스에 DMG 와 함께 첨부한다.
사용: scripts/make-appcast.py <버전> <dmg 경로> <sign_update 출력(sparkle:edSignature=.. length=..)> <출력 경로>
릴리스 노트는 docs/FEATURES.md 의 "변경 이력" 에서 그 버전 부분을 HTML 로 넣는다."""
import html, re, sys
from datetime import datetime, timezone

version, dmg, sig, out = sys.argv[1:5]
repo = "zio0911/god_db"
url = f"https://github.com/{repo}/releases/download/v{version}/{dmg.split('/')[-1]}"

# 변경 이력에서 이 버전 줄들
lines, in_log, cur = [], False, None
for raw in open("docs/FEATURES.md", encoding="utf-8"):
    line = raw.strip()
    if line.startswith("## "):
        in_log = "변경 이력" in line
        continue
    if not in_log:
        continue
    if line.startswith("### "):
        cur = line[4:].replace("(개발 중)", "").strip()
        continue
    if cur == version and line:
        lines.append(line)

def inline(t):
    t = html.escape(t[2:] if t.startswith("- ") else t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"`(.+?)`", r"<code>\1</code>", t)
    return t

notes = f"<h3>GodDB {version}</h3><ul>" + "".join(f"<li>{inline(l)}</li>" for l in lines) + "</ul>"
pub = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>GodDB</title>
    <link>https://github.com/{repo}</link>
    <item>
      <title>GodDB {version}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/{repo}/releases/tag/v{version}</sparkle:releaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sig.strip()} />
    </item>
  </channel>
</rss>
"""
open(out, "w", encoding="utf-8").write(xml)
print(f"appcast: {out}")
