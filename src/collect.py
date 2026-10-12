#!/usr/bin/env python3
"""
collect.py — 采集 DeepSeek 余额 + DSH 本地 token 用量，输出 usage.json

数据源:
  1. 余额   GET https://api.deepseek.com/user/balance
            Key 运行时现读 ~/.dsh/.credentials.yaml（不写死进代码）
  2. 用量   ~/.dsh/sessions/<proj>/<session>/*.jsonl.zstd
            v4 日志:  data.usage          (type=assistant/message)
            旧版日志: data.chunk.usage    (type=assistant/chunk)
            去重: 每个 (turn, step) 只保留一条，优先 assistant/message
                  —— 旧版把同一次调用记两遍（chunk + message，total 相同、时间差几毫秒）
            同一会话目录若同时存在 v4 与旧版，只读 v4。

用法:
  python3 collect.py            # 采集并写 usage.json
  python3 collect.py --print    # 采集 + 打印人类可读摘要
  python3 collect.py --offline  # 跳过余额 API（调试用）
"""

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter  # noqa: F401  (保留给后续统计扩展)
from datetime import datetime, timedelta

# ---------------------------------------------------------------- 配置
DSH_HOME = os.path.expanduser(os.environ.get("DSH_HOME", "~/.dsh"))
SESSIONS_DIR = os.path.join(DSH_HOME, "sessions")
CREDENTIALS = os.environ.get("TOKENBAR_CREDENTIALS") or os.path.join(DSH_HOME, ".credentials.yaml")
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
# 运行时数据统一放项目根的 .data/（不进版本库），可用 TOKENBAR_DATA_DIR 覆盖
ROOT_DIR = os.path.dirname(OUT_DIR)
DATA_DIR = os.environ.get("TOKENBAR_DATA_DIR") or os.path.join(ROOT_DIR, ".data")
USAGE_JSON = os.path.join(DATA_DIR, "usage.json")
HISTORY_JSON = os.path.join(DATA_DIR, "history.json")
LOCK_FILE = os.path.join(DATA_DIR, ".collect.lock")

# 可覆盖，便于测试降级路径
BALANCE_URL = os.environ.get("TOKENBAR_BALANCE_URL") or "https://api.deepseek.com/user/balance"
HTTP_TIMEOUT = 12
HISTORY_KEEP_DAYS = 30
# 余额无变化时，最快多久记一个采样点，避免 history 膨胀
HISTORY_MIN_GAP_S = 600


def now_ms():
    return int(time.time() * 1000)


def log(msg):
    print(f"[collect] {msg}", file=sys.stderr)


# ---------------------------------------------------------------- 余额
def read_api_key():
    """从 DSH 凭据文件读取 DEEPSEEK_API_KEY，绝不硬编码。"""
    if not os.path.exists(CREDENTIALS):
        return None, f"凭据文件不存在: {CREDENTIALS}"
    try:
        with open(CREDENTIALS, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        return None, f"读取凭据失败: {exc}"
    match = re.search(r"DEEPSEEK_API_KEY:\s*[\"']?([A-Za-z0-9_\-]+)", text)
    if not match:
        return None, "凭据文件中未找到 DEEPSEEK_API_KEY"
    return match.group(1), None


def fetch_balance(key):
    req = urllib.request.Request(
        BALANCE_URL, headers={"Authorization": f"Bearer {key}", "Accept": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

    infos = payload.get("balance_infos") or []
    if not infos:
        return None, "余额接口未返回 balance_infos"
    # 优先人民币
    info = next((i for i in infos if i.get("currency") == "CNY"), infos[0])

    def num(x):
        try:
            return float(x)
        except (TypeError, ValueError):
            return None

    return {
        "total": num(info.get("total_balance")),
        "granted": num(info.get("granted_balance")),
        "toppedUp": num(info.get("topped_up_balance")),
        "currency": info.get("currency") or "CNY",
        "isAvailable": bool(payload.get("is_available")),
    }, None


# ---------------------------------------------------------------- 会话日志
def find_zstd():
    for cand in ("zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"):
        path = shutil.which(cand) if os.sep not in cand else (cand if os.path.exists(cand) else None)
        if path:
            return path
    return None


ZSTD = find_zstd()


def read_session_file(path):
    """返回文件的文本内容（自动处理 zstd 压缩）。"""
    if path.endswith(".zstd"):
        if not ZSTD:
            raise RuntimeError("找不到 zstd 可执行文件，请 brew install zstd")
        proc = subprocess.run([ZSTD, "-dc", path], capture_output=True)
        if proc.returncode != 0:
            raise RuntimeError(f"zstd 解压失败: {proc.stderr.decode('utf-8', 'ignore')[:200]}")
        return proc.stdout.decode("utf-8", "ignore")
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        return fh.read()


def pick_session_files(session_dir):
    """同一会话只选一份日志：有 v4 就只读 v4，否则读旧版。"""
    try:
        names = [
            os.path.join(session_dir, n)
            for n in os.listdir(session_dir)
            if n.endswith(".jsonl.zstd") or n.endswith(".jsonl")
        ]
    except OSError:
        return []
    if not names:
        return []
    v4 = [p for p in names if ".v4." in os.path.basename(p)]
    if v4:
        return sorted(v4)
    return sorted(names)


def parse_usage(path):
    """从单个日志文件解析 usage 记录。

    去重规则（已实测）: 每个 (turn, step) 只保留一条 usage，优先 assistant/message。
    旧版日志会把同一次调用记两遍——assistant/chunk（流式，时间 T）与
    assistant/message（最终，时间 T+4ms），两者 totalTokens 相同、时间不同，
    所以不能拿时间当去重键；v4 日志只记 assistant/message，天然无重复。
    """
    text = read_session_file(path)
    by_step = {}
    order = []
    for line in text.splitlines():
        if '"usage"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        data = obj.get("data") or {}
        usage = data.get("usage") or (data.get("chunk") or {}).get("usage")
        if not usage:
            continue

        total = usage.get("totalTokens")
        if total is None:
            total = (
                (usage.get("inputTokens") or 0)
                + (usage.get("outputTokens") or 0)
                + (usage.get("cacheReadTokens") or 0)
                + (usage.get("cacheWriteTokens") or 0)
            )
        rec = {
            "time": obj.get("time") or 0,
            "input": usage.get("inputTokens") or 0,
            "output": usage.get("outputTokens") or 0,
            "cacheRead": usage.get("cacheReadTokens") or 0,
            "cacheWrite": usage.get("cacheWriteTokens") or 0,
            "reasoning": usage.get("reasoningTokens") or 0,
            "total": total,
            "model": (data.get("message") or {}).get("model") or data.get("model"),
        }

        key = (data.get("turn"), data.get("step"))
        prev = by_step.get(key)
        if prev is None:
            by_step[key] = (obj.get("type"), rec)
            order.append(key)
        else:
            # 只保留最终的 assistant/message
            prev_type, prev_rec = prev
            if prev_type != "assistant/message" and obj.get("type") == "assistant/message":
                by_step[key] = (obj.get("type"), rec)
            elif rec["time"] > prev_rec["time"]:
                # 同类型重复时保留较新的一条
                if obj.get("type") == prev_type:
                    by_step[key] = (obj.get("type"), rec)

    return [by_step[k][1] for k in order]


def empty_agg():
    return {
        "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0,
        "reasoning": 0, "total": 0, "requests": 0, "lastTime": 0,
    }


def add(agg, rec):
    agg["input"] += rec["input"]
    agg["output"] += rec["output"]
    agg["cacheRead"] += rec["cacheRead"]
    agg["cacheWrite"] += rec["cacheWrite"]
    agg["reasoning"] += rec["reasoning"]
    agg["total"] += rec["total"]
    agg["requests"] += 1
    agg["lastTime"] = max(agg.get("lastTime", 0), rec["time"])


def finalize(agg):
    denom = agg["cacheRead"] + agg["input"]
    agg["cacheHitRate"] = round(agg["cacheRead"] / denom, 4) if denom else None
    return agg


def collect_sessions():
    """扫描全部会话，返回 (per_session, per_day, 最近写入时间)。"""
    per_session = {}
    per_day = {}
    latest = 0

    if not os.path.isdir(SESSIONS_DIR):
        return per_session, per_day, latest

    for proj in sorted(os.listdir(SESSIONS_DIR)):
        proj_dir = os.path.join(SESSIONS_DIR, proj)
        if not os.path.isdir(proj_dir):
            continue
        for sid in sorted(os.listdir(proj_dir)):
            sdir = os.path.join(proj_dir, sid)
            if not os.path.isdir(sdir):
                continue
            files = pick_session_files(sdir)
            if not files:
                continue
            agg = empty_agg()
            try:
                for path in files:
                    for rec in parse_usage(path):
                        add(agg, rec)
                        day = datetime.fromtimestamp(rec["time"] / 1000).strftime("%Y-%m-%d")
                        bucket = per_day.setdefault(day, empty_agg())
                        add(bucket, rec)
                        latest = max(latest, rec["time"])
            except Exception as exc:  # 单会话失败不影响整体
                log(f"跳过 {sid}: {exc}")
                continue
            if agg["requests"]:
                per_session[sid] = agg
    return per_session, per_day, latest


def current_session_id(per_session):
    """优先当前 DSH 会话；否则回退到日志最新写入的会话。"""
    sid = os.environ.get("DSH_SESSION_ID")
    if sid:
        return sid
    if not per_session:
        return None
    return max(per_session.items(), key=lambda kv: kv[1].get("lastTime", 0))[0]


# ---------------------------------------------------------------- 历史与花费
def load_history():
    try:
        with open(HISTORY_JSON, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        samples = [s for s in data.get("samples", []) if isinstance(s, dict)]
    except (OSError, ValueError):
        samples = []

    cutoff = now_ms() - HISTORY_KEEP_DAYS * 86400 * 1000
    samples = [s for s in samples if s.get("t", 0) >= cutoff]
    # 去重 + 时间升序
    dedup = {}
    for s in samples:
        dedup[s["t"]] = s
    return [dedup[k] for k in sorted(dedup)]


def save_history(samples):
    tmp = HISTORY_JSON + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"unit": "cny", "samples": samples}, fh, ensure_ascii=False)
    os.replace(tmp, HISTORY_JSON)


def update_history(samples, balance):
    if balance is None or balance.get("total") is None:
        return samples
    now = now_ms()
    entry = {"t": now, "balance": balance["total"]}
    if not samples:
        return [entry]
    last = samples[-1]
    changed = abs(last.get("balance", -1) - entry["balance"]) > 1e-9
    if changed or (now - last.get("t", 0)) >= HISTORY_MIN_GAP_S * 1000:
        samples = samples + [entry]
    return samples


def compute_spend(samples, balance):
    """用余额差值算花费，不需要价格表。"""
    out = {"today": None, "dailyRate": None, "daysLeft": None, "spanDays": None}
    if len(samples) < 2:
        return out

    today = datetime.now().strftime("%Y-%m-%d")
    today_spend = 0.0
    saw_today = False
    for prev, cur in zip(samples, samples[1:]):
        delta = prev.get("balance", 0) - cur.get("balance", 0)
        if delta <= 0:  # 充值或不变
            continue
        day = datetime.fromtimestamp(cur["t"] / 1000).strftime("%Y-%m-%d")
        if day == today:
            today_spend += delta
            saw_today = True
    if saw_today:
        out["today"] = round(today_spend, 4)

    # 近 7 天速率
    cutoff = now_ms() - 7 * 86400 * 1000
    recent = [s for s in samples if s.get("t", 0) >= cutoff]
    if len(recent) >= 2:
        span_days = (recent[-1]["t"] - recent[0]["t"]) / 86400000.0
        out["spanDays"] = round(span_days, 2)
        spent = sum(
            max(0.0, a.get("balance", 0) - b.get("balance", 0))
            for a, b in zip(recent, recent[1:])
        )
        if span_days >= 0.05 and spent > 0:
            rate = spent / span_days
            out["dailyRate"] = round(rate, 4)
            if balance and balance.get("total") and rate > 0:
                out["daysLeft"] = round(balance["total"] / rate, 1)
    return out


# ---------------------------------------------------------------- 主流程
def main(argv):
    offline = "--offline" in argv
    do_print = "--print" in argv

    os.makedirs(DATA_DIR, exist_ok=True)

    # 防止定时任务与手动刷新撞车（单次运行约 0.3s，正常不会冲突）
    lock_fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("已有采集进程在运行，跳过本次")
        lock_fh.close()
        return 0

    result = {
        "updatedAt": now_ms(),
        "updatedAtISO": datetime.now().astimezone().isoformat(timespec="seconds"),
        "ok": False,
        "error": None,
        "balance": None,
        "today": finalize(empty_agg()),
        "session": finalize(empty_agg()),
        "sessionId": None,
        "week": [],
        "spend": {"today": None, "dailyRate": None, "daysLeft": None, "spanDays": None},
        "sessionsScanned": 0,
        "refreshSeconds": 60,
    }

    errors = []

    # 1) 用量
    try:
        per_session, per_day, latest = collect_sessions()
        result["sessionsScanned"] = len(per_session)
        result["dataAgeMs"] = (now_ms() - latest) if latest else None

        today_key = datetime.now().strftime("%Y-%m-%d")
        result["today"] = finalize(per_day.get(today_key, empty_agg()))

        sid = current_session_id(per_session)
        result["sessionId"] = sid
        if sid and sid in per_session:
            result["session"] = finalize(per_session[sid])

        week = []
        for i in range(6, -1, -1):
            day = (datetime.now() - timedelta(days=i)).strftime("%Y-%m-%d")
            agg = finalize(per_day.get(day, empty_agg()))
            week.append({"date": day, "total": agg["total"], "requests": agg["requests"]})
        result["week"] = week

        alltime = empty_agg()
        for agg in per_session.values():
            for k in ("input", "output", "cacheRead", "cacheWrite", "reasoning", "total", "requests"):
                alltime[k] += agg.get(k, 0)
        alltime["lastTime"] = max((a.get("lastTime", 0) for a in per_session.values()), default=0)
        result["allTime"] = finalize(alltime)
        result["sessionCount"] = len(per_session)
    except Exception as exc:
        errors.append(f"用量采集失败: {exc}")

    # 2) 余额
    balance = None
    if offline:
        errors.append("已跳过余额查询 (--offline)")
    else:
        key, err = read_api_key()
        if err:
            errors.append(err)
        else:
            try:
                balance, berr = fetch_balance(key)
                if berr:
                    errors.append(berr)
            except urllib.error.HTTPError as exc:
                errors.append(f"余额接口 HTTP {exc.code}")
            except urllib.error.URLError as exc:
                errors.append(f"余额接口网络错误: {exc.reason}")
            except Exception as exc:
                errors.append(f"余额接口失败: {exc}")
    result["balance"] = balance

    # 3) 历史 / 花费
    try:
        samples = update_history(load_history(), balance)
        save_history(samples)
        result["spend"] = compute_spend(samples, balance)
        result["historySamples"] = len(samples)
    except Exception as exc:
        errors.append(f"历史写入失败: {exc}")

    # 4) 成败判定：有余额或有用量就算成功
    result["ok"] = bool(balance) or result["sessionsScanned"] > 0
    result["error"] = "; ".join(errors) if errors else None

    tmp = USAGE_JSON + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, USAGE_JSON)

    if do_print:
        print_summary(result)
    else:
        log(f"写入 {USAGE_JSON}" + (f" ({result['error']})" if result["error"] else ""))
    return 0


def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(n)


def print_summary(r):
    b = r.get("balance") or {}
    t = r["today"]
    s = r["session"]
    sp = r["spend"]
    cur = b.get("currency", "CNY")
    sym = "¥" if cur == "CNY" else "$"
    print("=" * 46)
    if b:
        print(f"  余额        {sym}{b['total']}   可用={b['isAvailable']}")
    else:
        print("  余额        (获取失败)")
    print(f"  今日用量    {fmt_tokens(t['total'])} tok   请求 {t['requests']}")
    print(f"    输入 {fmt_tokens(t['input'])} / 输出 {fmt_tokens(t['output'])}"
          f" / 缓存读 {fmt_tokens(t['cacheRead'])}")
    hit = t["cacheHitRate"]
    print(f"    缓存命中率 {'-' if hit is None else f'{hit * 100:.1f}%'}")
    print(f"  本次会话    {fmt_tokens(s['total'])} tok   请求 {s['requests']}")
    spend_today = "-" if sp["today"] is None else f"{sym}{sp['today']}"
    rate = "-" if sp["dailyRate"] is None else f"{sym}{sp['dailyRate']}"
    print(f"  今日已花    {spend_today}")
    print(f"  日均花费    {rate}")
    print(f"  预计可用    {'-' if sp['daysLeft'] is None else str(sp['daysLeft']) + ' 天'}")
    print("-" * 46)
    print("  近 7 天:")
    for d in r["week"]:
        bar = "█" * min(30, int(d["total"] / max(1, max(x["total"] for x in r["week"])) * 30))
        print(f"    {d['date']}  {fmt_tokens(d['total']):>8s}  {bar}")
    print("-" * 46)
    print(f"  会话数 {r['sessionsScanned']}   历史采样 {r.get('historySamples', 0)}")
    print(f"  更新于 {r['updatedAtISO']}")
    if r["error"]:
        print(f"  警告: {r['error']}")
    print("=" * 46)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
