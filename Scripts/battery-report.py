#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""录音豆续航统计：读 OpenBean 日志里的 `battery event=...` 行，算待机耗电、语音输入耗电和预计续航。

用法：
    python3 -I Scripts/battery-report.py                      # 默认读 ~/Library/Application Support/OpenBean/openbean.log
    python3 -I Scripts/battery-report.py path/to/openbean.log --since 2026-11-13 --until "2026-11-13 22:00"
    python3 -I Scripts/battery-report.py --self-test          # 用合成日志校验算法

日志行（时间是 UTC ISO 8601，取值未知时写 ?）：
    battery event=connect recorder=80 case=60 charging=0 caseCharging=0
    battery event=level recorder=70 case=60
    battery event=charging charging=1 caseCharging=0 recorder=70
    battery event=tick recorder=70 case=60 charging=0 caseCharging=0     （连着时每 10 分钟一行）
    battery event=dictation seconds=42 recorder=70 file=1794477465
    battery event=record seconds=600 recorder=70 file=1794477466
    battery event=disconnect recorder=70
    battery event=quit

口径：
- 只统计「看得到」的时间：连着、且相邻两行电量日志间隔不超过 --max-gap（默认 15 分钟）。
  App 退出、断开、Mac 睡眠（心跳中断）都算空档，不计时间，也不计空档里掉的电。
- charging=1（录音豆在充电盒里）的时间不算「离开充电盒」。
- 电量只有 10% 一档。耗电率用「相邻两次掉档之间的时长」来算（每段正好用掉约 10%），
  每段之前、之后不满一档的零头不计；只有一两次掉档时结果很粗。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

DEFAULT_LOG = os.path.expanduser("~/Library/Application Support/OpenBean/openbean.log")
LINE = re.compile(r"^(\S+)\s+battery\s+(event=\S+.*)$")
KV = re.compile(r"(\w+)=(\S+)")


@dataclass
class Event:
    t: datetime
    kind: str
    f: dict

    def num(self, key):
        v = self.f.get(key)
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    def flag(self, key):
        v = self.f.get(key)
        return {"1": True, "0": False}.get(v)


def parse_time(s: str) -> datetime:
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    t = datetime.fromisoformat(s)
    if t.tzinfo is None:  # 命令行给的时间按本地时间理解
        t = t.astimezone()
    return t.astimezone(timezone.utc)


def parse(lines) -> list[Event]:
    out = []
    for line in lines:
        m = LINE.match(line.strip())
        if not m:
            continue
        try:
            t = parse_time(m.group(1))
        except ValueError:
            continue
        f = dict(KV.findall(m.group(2)))
        out.append(Event(t, f.get("event", ""), f))
    out.sort(key=lambda e: e.t)
    return out


@dataclass
class Stretch:
    """一段连续、看得到、离开充电盒的时间"""
    start: datetime
    start_level: int | None
    end: datetime
    end_level: int | None
    # 掉档时刻：(时间, 掉档后的电量)；电量回升（不在充电却变高）时整条链作废重来
    chain: list = field(default_factory=list)
    steps: list = field(default_factory=list)  # (开始, 结束, 掉了几个百分点)


@dataclass
class Report:
    connected: float = 0.0  # 秒
    off: float = 0.0
    gaps: int = 0
    gap_seconds: float = 0.0
    quits: int = 0
    disconnects: int = 0
    dictations: list = field(default_factory=list)  # (开始, 结束)
    records: list = field(default_factory=list)
    off_intervals: list = field(default_factory=list)
    stretches: list = field(default_factory=list)
    first: datetime | None = None
    last: datetime | None = None


def analyse(events: list[Event], max_gap: float = 15 * 60) -> Report:
    r = Report()
    conn = False
    chg = None  # True=在充电盒里，None=不知道
    level = None
    last = None  # 上一行电量日志的时间（连着时）
    st: Stretch | None = None

    def close(at):
        nonlocal st
        if st is not None:
            st.end, st.end_level = at, level
            if st.end > st.start:
                r.stretches.append(st)
        st = None

    def open_if_off(at):
        nonlocal st
        if conn and chg is False and st is None:
            st = Stretch(at, level, at, level)

    def set_level(at, v):
        nonlocal level
        if v is None or v == level:
            return
        if st is not None and level is not None:
            if v < level:
                if st.chain:
                    t0, _ = st.chain[-1]
                    st.steps.append((t0, at, level - v))
                st.chain.append((at, v))
            else:
                st.chain = []  # 没充电却回升：档位抖动，之前的计时不可靠
        level = v

    for e in events:
        r.first = r.first or e.t
        r.last = e.t
        observed = conn and last is not None and (e.t - last).total_seconds() <= max_gap
        if conn and last is not None:
            dt = (e.t - last).total_seconds()
            if observed:
                r.connected += dt
                if chg is False:
                    r.off += dt
                    r.off_intervals.append((last, e.t))
                if st is not None:
                    st.end = e.t
            else:
                r.gaps += 1
                r.gap_seconds += dt
                close(last)

        if e.kind in ("disconnect", "quit"):
            if e.kind == "quit":
                r.quits += 1
            else:
                r.disconnects += 1
            set_level(e.t, e.num("recorder"))
            close(e.t if observed else last or e.t)
            conn, last = False, None
            continue

        if e.kind == "connect":
            close(e.t if observed else last or e.t)
            conn, last = True, e.t
            chg = e.flag("charging")
            level = e.num("recorder")
            open_if_off(e.t)
            continue

        # 其余各行都说明 App 开着、连着；之前没看到 connect（比如被 --since 截掉）就从这里开始算
        if not conn:
            conn = True
            chg = e.flag("charging")
            level = None
        last = e.t
        if e.kind in ("dictation", "record"):
            secs = e.num("seconds") or 0
            (r.dictations if e.kind == "dictation" else r.records).append((e.t - timedelta(seconds=secs), e.t))
        if e.kind in ("charging", "tick"):
            c = e.flag("charging")
            if c is not None and c != chg:
                if c:
                    close(e.t)
                chg = c
        set_level(e.t, e.num("recorder"))
        open_if_off(e.t)

    close(last or (r.last or datetime.now(timezone.utc)))
    return r


def overlap(a, b, intervals) -> float:
    s = 0.0
    for x, y in intervals:
        lo, hi = max(a, x), min(b, y)
        if hi > lo:
            s += (hi - lo).total_seconds()
    return s


def fit(steps, dictations, records):
    """每个掉档段：掉的百分点 = 待机小时 × a + 语音输入分钟 × b。最小二乘，系数不许为负。

    返回 (a %/h, b %/min, 段数)；数据不够时 a 或 b 为 None。
    """
    rows = []
    for t0, t1, drop in steps:
        dur = (t1 - t0).total_seconds()
        d = overlap(t0, t1, dictations)
        rec = overlap(t0, t1, records)
        rows.append(((dur - d - rec) / 3600, d / 60, drop))
    if not rows:
        return None, None, 0
    sxx = sum(x * x for x, _, _ in rows)
    syy = sum(y * y for _, y, _ in rows)
    sxy = sum(x * y for x, y, _ in rows)
    sxz = sum(x * z for x, _, z in rows)
    syz = sum(y * z for _, y, z in rows)
    det = sxx * syy - sxy * sxy
    # 两列几乎成比例（每段说话占比都差不多）时分不开，det 相对 sxx·syy 太小就放弃拆分
    if len(rows) >= 2 and syy > 0 and sxx > 0 and det > 0.01 * sxx * syy:
        a = (sxz * syy - syz * sxy) / det
        b = (syz * sxx - sxz * sxy) / det
        if a >= 0 and b >= 0:
            return a, b, len(rows)
    # 只能拟合一个系数：全算到待机上
    if sxx > 0:
        return sxz / sxx, None, len(rows)
    return None, None, len(rows)


def hm(seconds: float) -> str:
    m = int(round(seconds / 60))
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def local(t: datetime) -> str:
    return t.astimezone().strftime("%Y-%m-%d %H:%M")


def render(r: Report, path: str) -> str:
    out = []
    p = out.append
    p("OpenBean battery report")
    p(f"Log: {path}")
    p(f"Window: {local(r.first)} – {local(r.last)} (local time)")
    p("")
    dict_total = sum((b - a).total_seconds() for a, b in r.dictations)
    dict_off = sum(overlap(a, b, r.off_intervals) for a, b in r.dictations)
    rec_total = sum((b - a).total_seconds() for a, b in r.records)
    drops = sum(max(0, (s.start_level or 0) - (s.end_level or 0)) for s in r.stretches
                if s.start_level is not None and s.end_level is not None)
    p(f"Time connected:            {hm(r.connected)}"
      f"  (excluded: {r.gaps} gap(s) totalling {hm(r.gap_seconds)}, {r.disconnects} disconnect(s), {r.quits} app quit(s))")
    p(f"Time off the charger:      {hm(r.off)}  in {len(r.stretches)} stretch(es)")
    p(f"Voice typing:              {len(r.dictations)} session(s), {hm(dict_total)} total"
      f" ({hm(dict_off)} of it off the charger)")
    if r.records:
        p(f"Record-only:               {len(r.records)} session(s), {hm(rec_total)} total")
    p(f"Buckets dropped off charger: {drops // 10} ({drops}%)")
    p("")

    steps = [x for s in r.stretches for x in s.steps]
    step_secs = sum((b - a).total_seconds() for a, b, _ in steps)
    step_drop = sum(d for _, _, d in steps)
    p("Drain estimates — the recorder reports battery in 10% buckets, so short spans are rough.")
    blended = None
    if steps and step_secs > 0:
        blended = step_drop / (step_secs / 3600)
        p(f"  Bucket-to-bucket timing: {len(steps)} full step(s), {step_drop}% in {hm(step_secs)}"
          f" = {blended:.1f} %/h at the observed mix")
        a, b, n = fit(steps, r.dictations, r.records)
        if a is not None and b is not None:
            p(f"  Split (least squares over {n} steps): standby ≈ {a:.2f} %/h,"
              f" voice typing ≈ {b:.3f} %/min ({b * 60:.1f} %/h while talking)")
        elif a is not None:
            p("  Split: not enough variation yet to separate standby from voice typing"
              " (needs several steps, some with and some without voice typing)")
        if len(steps) < 3:
            p("  Fewer than 3 full steps: treat these numbers as ±50% at best.")
    else:
        a = b = None
        p("  No two consecutive bucket drops in one off-charger stretch yet; only the crude figure below is available.")
    if r.off > 0 and drops > 0:
        crude = drops / (r.off / 3600)
        p(f"  Crude: {drops}% over {hm(r.off)} off the charger = {crude:.1f} %/h"
          f" (each stretch can be off by up to 10%)")
        blended = blended or crude
    if rec_total > 0:
        p("  Record-only time is counted as standby in the split; it inflates the standby figure.")
    p("")
    if blended:
        per_hour = dict_off / 60 / (r.off / 3600) if r.off > 0 else 0
        p(f"Projected battery life at this usage (≈ {per_hour:.1f} min voice typing per hour off the charger):")
        p(f"  ≈ {100 / blended:.0f} h from full")
        if a and b is not None:
            model = a + b * per_hour
            if model > 0:
                p(f"  From the split model: ≈ {100 / model:.0f} h; standby only ≈ {100 / a:.0f} h;"
                  f" every 10 min of voice typing costs ≈ {b * 10:.1f}%")
    else:
        p("Projected battery life: not enough data yet (no bucket dropped while off the charger).")
    return "\n".join(out)


# MARK: 自测

def synthetic_log(standby=2.0, per_min=0.5) -> tuple[str, dict]:
    """生成一份合成日志：真实电量待机时按 standby %/h、语音输入时按 per_min %/分钟连续下降，日志只记 10% 档。

    时间线（UTC）：
      08:00 连上，在充电盒里（charging=1）；08:30 取出
      08:30–14:30 戴着：每小时第 20 分钟起语音输入 3 分钟
      14:30–16:30 Mac 睡眠（没有任何日志）；16:30 起继续
      16:30–20:30 再戴 4 小时，说得多：每小时第 20 分钟起语音输入 15 分钟；20:30 放回充电盒；20:40 退出
    两段说话占比不同，才分得开待机和语音输入各耗多少。
    """
    lines = []
    T0 = datetime(2026, 11, 13, 8, 0, tzinfo=timezone.utc)

    def w(t, s):
        lines.append(f"{t.strftime('%Y-%m-%dT%H:%M:%SZ')} {s}")

    def bucket(c):
        return max(10, min(100, 10 * -(-int(c * 1000) // 10000)))  # 向上取整到 10%

    def talking(t):
        m = (t - T0).total_seconds() / 60 % 60
        heavy = t >= T0 + timedelta(hours=8)
        return (40 <= m < 55) if heavy else (20 <= m < 23)

    charge = 100.0
    w(T0, "已连接录音豆")
    w(T0, "battery event=connect recorder=100 case=80 charging=1 caseCharging=0")
    t = T0 + timedelta(minutes=10)
    while t < T0 + timedelta(minutes=30):
        w(t, "battery event=tick recorder=100 case=80 charging=1 caseCharging=0")
        t += timedelta(minutes=10)
    out_at = T0 + timedelta(minutes=30)
    w(out_at, "battery event=charging charging=0 caseCharging=0 recorder=100")

    shown = 100
    expect = {"connected": 0.0, "off": 0.0, "dict_count": 0, "dict_secs": 0}

    def wear(start, end):
        nonlocal charge, shown
        t = start
        talk_start = None
        step = timedelta(seconds=1)
        since_tick = 0
        while t < end:
            on = talking(t)
            if on and talk_start is None:
                talk_start = t
            if not on and talk_start is not None:
                secs = int((t - talk_start).total_seconds())
                w(t, f"结束听写：……")
                w(t, f"battery event=dictation seconds={secs} recorder={shown} file=1")
                expect["dict_count"] += 1
                expect["dict_secs"] += secs
                talk_start = None
            # 说话的那一秒按语音输入耗电算，否则按待机算（和 fit() 的模型一致）
            charge -= per_min / 60 if on else standby / 3600
            t += step
            since_tick += 1
            b = bucket(charge)
            if b != shown:
                shown = b
                w(t, f"battery event=level recorder={b} case=80")
            if since_tick % 600 == 0:
                w(t, f"battery event=tick recorder={shown} case=80 charging=0 caseCharging=0")

    wear(out_at, T0 + timedelta(hours=6, minutes=30))
    # Mac 睡了两小时：录音豆照样耗电，但日志里什么也没有
    charge -= 2 * standby  # 睡眠期间不说话
    wake = T0 + timedelta(hours=8, minutes=30)
    shown = bucket(charge)
    w(wake, f"battery event=tick recorder={shown} case=80 charging=0 caseCharging=0")
    wear(wake, T0 + timedelta(hours=12, minutes=30))
    back = T0 + timedelta(hours=12, minutes=30)
    w(back, f"battery event=charging charging=1 caseCharging=0 recorder={shown}")
    w(back + timedelta(minutes=10), f"battery event=tick recorder={shown} case=80 charging=1 caseCharging=0")
    w(back + timedelta(minutes=10), "battery event=quit")

    # 看得到的时间：08:00–14:30 和 16:30–20:40（14:30 前最后一行心跳到 16:30 的空档不算）
    expect["connected"] = (6.5 + 4 + 1 / 6) * 3600
    expect["off"] = (6 + 4) * 3600
    return "\n".join(lines) + "\n", expect


def self_test() -> int:
    text, ex = synthetic_log(standby=2.0, per_min=0.5)
    r = analyse(parse(text.splitlines()))
    ok = True

    def check(name, got, want, tol):
        nonlocal ok
        good = abs(got - want) <= tol
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {name}: got {got:.3f}, want {want:.3f} ± {tol}")

    check("connected hours", r.connected / 3600, ex["connected"] / 3600, 0.05)
    check("off-charger hours", r.off / 3600, ex["off"] / 3600, 0.05)
    check("voice-typing sessions", len(r.dictations), ex["dict_count"], 0)
    check("voice-typing minutes", sum((b - a).total_seconds() for a, b in r.dictations) / 60, ex["dict_secs"] / 60, 0.01)
    check("voice-typing minutes (by hand: 6 × 3 + 4 × 15)", ex["dict_secs"] / 60, 78, 0)
    check("gaps", r.gaps, 1, 0)
    steps = [x for s in r.stretches for x in s.steps]
    a, b, n = fit(steps, r.dictations, r.records)
    check("standby %/h", a or 0, 2.0, 0.02)
    check("voice typing %/min", b or 0, 0.5, 0.005)
    # 混合耗电：按真实速率算这些掉档段该用多少电，应和观察到的掉档一致
    hours = sum((y - x).total_seconds() for x, y, _ in steps) / 3600
    talk = sum(overlap(x, y, r.dictations) for x, y, _ in steps) / 60
    blended = sum(d for _, _, d in steps) / hours
    check("blended %/h", blended, ((hours - talk / 60) * 2.0 + talk * 0.5) / hours, 0.05)
    check("full 10% steps", len(steps), 4, 0)
    # 渲染不能出错
    render(r, "<synthetic>")
    # 只有旧日志（没有 battery 行）时
    ok &= parse(["2026-11-12T09:57:43Z 已连接录音豆"]) == []
    print("self-test passed" if ok else "self-test FAILED")
    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Recorder battery and usage report from the OpenBean log.")
    ap.add_argument("log", nargs="?", default=DEFAULT_LOG, help=f"log file (default: {DEFAULT_LOG})")
    ap.add_argument("--since", help="start time, local unless it has a zone, e.g. 2026-11-13 or '2026-11-13 08:00'")
    ap.add_argument("--until", help="end time, same format")
    ap.add_argument("--max-gap", type=float, default=15, help="minutes between log lines treated as a gap (default 15)")
    ap.add_argument("--self-test", action="store_true", help="check the maths on a synthetic log and exit")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    try:
        with open(args.log, encoding="utf-8", errors="replace") as f:
            events = parse(f)
    except OSError as e:
        print(f"Cannot read the log: {e}", file=sys.stderr)
        return 1
    try:
        since = parse_time(args.since) if args.since else None
        until = parse_time(args.until) if args.until else None
    except ValueError as e:
        print(f"Bad --since/--until: {e}", file=sys.stderr)
        return 1
    events = [e for e in events if (since is None or e.t >= since) and (until is None or e.t <= until)]
    if not events:
        print(f"No battery lines ('battery event=...') in {args.log}"
              + (" for that time range." if since or until else "."))
        print("They are written by OpenBean builds with battery logging. Run such a build with the recorder"
              " connected for a while (a full day of wear is best), then run this again.")
        return 0
    print(render(analyse(events, max_gap=args.max_gap * 60), args.log))
    return 0


if __name__ == "__main__":
    sys.exit(main())
