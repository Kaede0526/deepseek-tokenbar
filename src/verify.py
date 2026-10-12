#!/usr/bin/env python3
"""
verify.py — 独立重算 token 用量，与 collect.py 的输出对拍。

刻意不复用 collect.py 的任何代码：自己走目录、自己解压、自己去重，
如果两边数字一致，才说明 collect.py 的去重与聚合逻辑是对的。

用法: python3 verify.py
退出码: 0 = 一致, 1 = 不一致, 2 = 无法校验
"""

import json
import os
import subprocess
import sys
from collections import OrderedDict

BASE = os.path.expanduser(os.environ.get("DSH_HOME", "~/.dsh"))
SESSIONS = os.path.join(BASE, "sessions")
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.environ.get("TOKENBAR_DATA_DIR") or os.path.join(ROOT_DIR, ".data")
USAGE = os.path.join(DATA_DIR, "usage.json")


def dumps(path):
    if path.endswith(".zstd"):
        out = subprocess.run(["zstd", "-dc", path], capture_output=True)
        if out.returncode != 0:
            raise RuntimeError("zstd failed")
        return out.stdout.decode("utf-8", "ignore")
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        return fh.read()


def per_session():
    """返回 {session_id: {"total":int,"requests":int}}，规则与 collect.py 一致但独立实现。"""
    result = OrderedDict()
    if not os.path.isdir(SESSIONS):
        return result
    for proj in sorted(os.listdir(SESSIONS)):
        pdir = os.path.join(SESSIONS, proj)
        if not os.path.isdir(pdir):
            continue
        for sid in sorted(os.listdir(pdir)):
            sdir = os.path.join(pdir, sid)
            if not os.path.isdir(sdir):
                continue
            files = [f for f in os.listdir(sdir) if f.endswith(".jsonl.zstd") or f.endswith(".jsonl")]
            if not files:
                continue
            # 有 v4 就只读 v4
            v4 = [f for f in files if ".v4." in f]
            chosen = v4 if v4 else files

            # step -> 选中的 usage；用 OrderedDict 保证稳定
            steps = OrderedDict()
            for fname in sorted(chosen):
                text = dumps(os.path.join(sdir, fname))
                for line in text.split("\n"):
                    if '"usage"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    data = obj.get("data") or {}
                    usage = None
                    if isinstance(data.get("usage"), dict):
                        usage = data["usage"]
                    elif isinstance(data.get("chunk"), dict):
                        usage = data["chunk"].get("usage")
                    if not isinstance(usage, dict):
                        continue
                    key = (data.get("turn"), data.get("step"))
                    kind = obj.get("type")
                    prev = steps.get(key)
                    if prev is None:
                        steps[key] = (kind, usage)
                    elif prev[0] != "assistant/message" and kind == "assistant/message":
                        steps[key] = (kind, usage)

            if steps:
                total = sum(u.get("totalTokens", 0) for _, u in steps.values())
                result[sid] = {"total": total, "requests": len(steps)}
    return result


def main():
    if not os.path.exists(USAGE):
        print("找不到 usage.json，先跑 collect.py")
        return 2

    with open(USAGE, "r", encoding="utf-8") as fh:
        got = json.load(fh)

    mine = per_session()

    theirs = got.get("allTime")
    if not theirs:
        print("usage.json 里没有 allTime 字段，无法对拍")
        return 2

    # 排除仍在写入的当前会话：它在两次运行之间持续增长，拿它比对必然对不上。
    # 其余会话的日志已经封存，必须逐字节一致——这才是有效的校验。
    live = got.get("sessionId")
    live_mine = mine.get(live) if live else None
    drop_live = bool(live_mine and live_mine["requests"])
    their_session = got.get("session") or {}

    def keep(sid):
        return not (drop_live and sid == live)

    my_total = sum(v["total"] for sid, v in mine.items() if keep(sid))
    my_reqs = sum(v["requests"] for sid, v in mine.items() if keep(sid))
    their_total = theirs["total"] - (their_session.get("total", 0) if drop_live else 0)
    their_reqs = theirs["requests"] - (their_session.get("requests", 0) if drop_live else 0)

    print(f"{'session':24s} {'total':>12s} {'reqs':>6s}")
    for sid, v in mine.items():
        if keep(sid):
            print(f"{sid[:22]:24s} {v['total']:12d} {v['requests']:6d}")
    print("-" * 46)
    print(f"{'独立重算':24s} {my_total:12d} {my_reqs:6d}")
    print(f"{'collect.py':24s} {their_total:12d} {their_reqs:6d}")

    ok = my_total == their_total and my_reqs == their_reqs
    print("-" * 46)
    print("结果: " + ("✅ 完全一致" if ok else "❌ 不一致"))

    if drop_live:
        print(f"ℹ️  已排除活跃会话 {live[:22]}：独立重算 {live_mine['requests']} 次 vs "
              f"快照 {their_session.get('requests')} 次（它在实时增长，属正常）")

    # 今日用量不应超过总量，否则聚合逻辑有问题
    today = got.get("today", {}).get("total", 0)
    if today > theirs["total"]:
        print(f"⚠️  今日用量 {today} 超过总量 {theirs['total']}")
        ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
