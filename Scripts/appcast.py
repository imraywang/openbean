"""Sparkle 订阅源 appcast.xml 的小工具（bin/release、bin/publish 调用）。

加一个版本（bin/release）：
  python3 -I Scripts/appcast.py <现有 appcast.xml> <输出路径> --version 0.3.2 --build 4 \\
      --url <DMG 下载地址> --length <字节数> --signature <sign_update 给的 edSignature> \\
      [--notes en=<英文说明.md>] [--notes zh-Hans=<中文说明.md>]

  现有文件不存在就新建；新条目插在最前面，其余内容原样保留。写完重新解析一遍，确认是合法 XML。
  --notes 把 Markdown 发布说明内嵌进 <description sparkle:format="markdown" xml:lang="…">（Sparkle 2.9+，
  macOS 12+），更新窗口里显示。Sparkle 按用户的语言偏好在同名节点里挑（NSBundle.preferredLocalizations），
  挑不到就用第一个，所以英文排第一当默认。只给中文不给英文会被拒绝（别的语言的用户会看到中文）。

读出某个版本的下载信息（bin/publish）：
  python3 -I Scripts/appcast.py --enclosure <appcast.xml> <版本号>   # 打印：地址<TAB>字节数<TAB>签名

自检：
  python3 -I Scripts/appcast.py --self-test
"""
import argparse, sys, tempfile
import xml.etree.ElementTree as ET
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
XML_LANG = '{http://www.w3.org/XML/1998/namespace}lang'
# 发布说明的语言顺序：第一个是挑不到语言时的默认
NOTE_LANGS = ['en', 'zh-Hans']
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


def cdata(text):
    """包进 CDATA；内容里的 ]]> 拆开，免得提前结束"""
    return '<![CDATA[' + text.replace(']]>', ']]]]><![CDATA[>') + ']]>'


def description_xml(notes):
    """notes: {语言: Markdown 文本}。按 NOTE_LANGS 的顺序输出，英文在前当默认"""
    if notes and 'en' not in notes:
        raise ValueError('发布说明要有英文（en）：Sparkle 挑不到语言时用第一个，别的语言的用户会看到非英文说明')
    unknown = set(notes) - set(NOTE_LANGS)
    if unknown:
        raise ValueError(f'不认识的发布说明语言：{sorted(unknown)}（支持 {NOTE_LANGS}）')
    out = ''
    for lang in NOTE_LANGS:
        if lang in notes:
            body = notes[lang].strip()
            if not body:
                raise ValueError(f'{lang} 的发布说明是空的')
            out += (f'      <description sparkle:format="markdown" xml:lang="{lang}">'
                    f'{cdata(chr(10) + body + chr(10))}</description>\n')
    return out


def add_item(text, *, version, build, url, length, signature, min_system='26.0', date=None, notes=None):
    """在 appcast 文本里插入一个新版本，返回新文本"""
    root = ET.fromstring(text)
    # 同一构建号不能出现两次（bin/release 开头也查过，这里再兜底）
    for item in root.iter('item'):
        if item.findtext(f'{{{SPARKLE}}}version') == str(build):
            raise ValueError(f'appcast 里已有构建号 {build}')
    v = escape(version)
    item = f"""    <item>
      <title>OpenBean {v}</title>
      <link>https://github.com/imraywang/openbean/releases/tag/v{v}</link>
      <pubDate>{date or formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_system)}</sparkle:minimumSystemVersion>
{description_xml(notes or {})}      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
"""
    # 插到第一个 <item> 前；还没有条目就插到 </channel> 前
    at = text.find('    <item>')
    if at < 0:
        at = text.find('  </channel>')
    if at < 0:
        raise ValueError('appcast 格式不认识：找不到 <channel>')
    text = text[:at] + item + text[at:]
    ET.fromstring(text)  # 不合法就抛异常
    return text


def enclosure(text, version):
    """某个版本的 (下载地址, 字节数, 签名)；没有这个版本返回 None"""
    for item in ET.fromstring(text).iter('item'):
        if item.findtext(f'{{{SPARKLE}}}shortVersionString') == version:
            e = item.find('enclosure')
            if e is None:
                return None
            return e.get('url'), int(e.get('length')), e.get(f'{{{SPARKLE}}}edSignature')
    return None


def read_notes(specs):
    """--notes 语言=文件 → {语言: 文本}"""
    notes = {}
    for s in specs or []:
        lang, sep, path = s.partition('=')
        if not sep or not path:
            raise ValueError(f'--notes 的格式是 语言=文件，例如 en=notes.md：{s}')
        notes[lang] = Path(path).read_text()
    return notes


def self_test():
    item_args = dict(version='9.9.9', build=99, url='https://example.com/a.dmg', length=123, signature='sig==',
                     date='Fri, 13 Nov 2026 00:00:00 GMT')
    # 不带说明：和以前一样，没有 <description>
    t = add_item(EMPTY, **item_args)
    item = ET.fromstring(t).find('channel/item')
    assert item.find('description') is None
    assert enclosure(t, '9.9.9') == ('https://example.com/a.dmg', 123, 'sig==')
    assert enclosure(t, '1.0') is None
    # 带中英说明：英文在前，xml:lang 和 sparkle:format 都在，Markdown 原样保留（含 <、& 和 ]]>）
    en = '## Fixes\n\n- Voice typing no longer stops a recording <it did not start> & more ]]> done'
    zh = '## 修复\n\n- 语音输入不再结束不是它开始的录音'
    t = add_item(EMPTY, **item_args, notes={'zh-Hans': zh, 'en': en})
    ds = ET.fromstring(t).find('channel/item').findall('description')
    assert [d.get(XML_LANG) for d in ds] == ['en', 'zh-Hans'], [d.get(XML_LANG) for d in ds]
    assert all(d.get(f'{{{SPARKLE}}}format') == 'markdown' for d in ds)
    assert ds[0].text.strip() == en and ds[1].text.strip() == zh
    # 新条目插在最前面，旧条目保留
    t2 = add_item(t, **{**item_args, 'version': '9.9.10', 'build': 100})
    assert [i.findtext(f'{{{SPARKLE}}}version') for i in ET.fromstring(t2).iter('item')] == ['100', '99']
    # 拒绝：重复构建号、只有中文、不认识的语言、空说明
    for bad in [dict(**item_args), dict(**{**item_args, 'build': 100}, notes={'zh-Hans': zh}),
                dict(**{**item_args, 'build': 100}, notes={'en': en, 'fr': 'x'}),
                dict(**{**item_args, 'build': 100}, notes={'en': '  '})]:
        try:
            add_item(t, **bad)
        except ValueError:
            continue
        raise AssertionError(f'应当拒绝：{bad}')
    # 读文件
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'en.md'
        p.write_text(en)
        assert read_notes([f'en={p}']) == {'en': en}
    # 仓库里现有的 appcast 能解析
    real = Path(__file__).resolve().parent.parent / 'appcast.xml'
    if real.exists():
        ET.fromstring(real.read_text())
    print('appcast.py 自检通过')


def main():
    if sys.argv[1:2] == ['--self-test']:
        return self_test()
    if sys.argv[1:2] == ['--enclosure']:
        if len(sys.argv) != 4:
            sys.exit('用法：appcast.py --enclosure <appcast.xml> <版本号>')
        r = enclosure(Path(sys.argv[2]).read_text(), sys.argv[3])
        if r is None:
            sys.exit(f'appcast 里没有版本 {sys.argv[3]}')
        print('\t'.join(map(str, r)))
        return
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
    a.add_argument('--notes', action='append', metavar='语言=文件',
                   help=f'Markdown 发布说明，可给多次；语言 {NOTE_LANGS}，要有 en')
    args = a.parse_args()
    src = Path(args.src)
    try:
        text = add_item(src.read_text() if src.exists() else EMPTY, version=args.version, build=args.build,
                        url=args.url, length=args.length, signature=args.signature, min_system=args.min_system,
                        date=args.date, notes=read_notes(args.notes))
    except ValueError as e:
        sys.exit(str(e))
    Path(args.out).write_text(text)
    langs = '、'.join(l for l in NOTE_LANGS if l in (read_notes(args.notes)))
    print(f'appcast：{args.version} ({args.build}) → {args.out}' + (f'，发布说明：{langs}' if langs else '，没有发布说明'))


if __name__ == '__main__':
    main()
