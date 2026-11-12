"""往 Sparkle 订阅源 appcast.xml 里加一个版本（bin/release 调用）。

  python3 -I Scripts/appcast.py <现有 appcast.xml> <输出路径> --version 0.2.1 --build 2 \\
      --url <DMG 下载地址> --length <字节数> --signature <sign_update 给的 edSignature>

现有文件不存在就新建；新条目插在最前面，其余内容原样保留。写完重新解析一遍，确认是合法 XML。
"""
import argparse, sys
import xml.etree.ElementTree as ET
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
EMPTY = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}">
  <channel>
    <title>OpenBean</title>
    <link>https://github.com/imraywang/openbean</link>
    <description>OpenBean updates</description>
    <language>en</language>
  </channel>
</rss>
"""

a = argparse.ArgumentParser()
a.add_argument('src')
a.add_argument('out')
a.add_argument('--version', required=True)
a.add_argument('--build', required=True, type=int)
a.add_argument('--url', required=True)
a.add_argument('--length', required=True, type=int)
a.add_argument('--signature', required=True)
a.add_argument('--min-system', default='26.0')
a.add_argument('--date', help='RFC 822 时间，默认现在')
args = a.parse_args()

src = Path(args.src)
text = src.read_text() if src.exists() else EMPTY

# 同一构建号不能出现两次（bin/release 开头也查过，这里再兜底）
for item in ET.fromstring(text).iter('item'):
    if item.findtext(f'{{{SPARKLE}}}version') == str(args.build):
        sys.exit(f'appcast 里已有构建号 {args.build}')

v = escape(args.version)
item = f"""    <item>
      <title>OpenBean {v}</title>
      <link>https://github.com/imraywang/openbean/releases/tag/v{v}</link>
      <pubDate>{args.date or formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.min_system)}</sparkle:minimumSystemVersion>
      <enclosure url={quoteattr(args.url)} length="{args.length}" type="application/octet-stream" sparkle:edSignature={quoteattr(args.signature)}/>
    </item>
"""
# 插到第一个 <item> 前；还没有条目就插到 </channel> 前
at = text.find('    <item>')
if at < 0:
    at = text.find('  </channel>')
if at < 0:
    sys.exit('appcast 格式不认识：找不到 <channel>')
text = text[:at] + item + text[at:]

ET.fromstring(text)  # 不合法就抛异常
Path(args.out).write_text(text)
print(f'appcast：{args.version} ({args.build}) → {args.out}')
