"""从编译产物（*.stringsdata）读出 App 的全部字符串，合并 Scripts/zh.json 的中文翻译，
写成 OpenBean/Resources/Localizable.xcstrings。xcodebuild 不会自动更新字符串目录，改了界面文案后：
  xcodebuild … build && python3 -I Scripts/update-strings.py
"""
import glob, json, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
keys = set()
for f in glob.glob(str(root / 'build/Build/Intermediates.noindex/OpenBean.build/*/OpenBean.build/Objects-normal/*/*.stringsdata')):
    for entries in json.load(open(f)).get('tables', {}).values():
        keys.update(e['key'] for e in entries)
zh = json.load(open(root / 'Scripts/zh.json'))
missing = sorted(k for k in keys if k not in zh)
cat = {"sourceLanguage": "en", "version": "1.0", "strings": {}}
for k in sorted(keys):
    entry = {}
    if k in zh:
        entry["localizations"] = {"zh-Hans": {"stringUnit": {"state": "translated", "value": zh[k]}}}
    cat["strings"][k] = entry
out = root / 'OpenBean/Resources/Localizable.xcstrings'
out.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print(f"{len(keys)} 条，缺中文 {len(missing)} 条")
for k in missing: print("  缺：", repr(k))
sys.exit(1 if missing else 0)
