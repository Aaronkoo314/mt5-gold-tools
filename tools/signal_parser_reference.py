"""Python reference of the TradeBot signal parser (ParseSignal in MQL5/Experts/TradeBot.mq5).

Use it to test parser changes on past signals before porting them to MQL5: it reads the message export
D:/Trading/Orient/prestige_messages_raw.json and the price at each message time from MT5 (read-only).
The MQL5 version (v1.31) adds: input normalisation, "tp14150", and a whole-message shift only for a
forward at most 10 minutes old. Run: python -X utf8 tools/signal_parser_reference.py
"""
import datetime as dt
import json
import re
import sys

import MetaTrader5 as mt5

NUM = r"(\d+(?:\.\d+)?)"
FAR = 60.0
KEYS = ("a", "b", "sl", "tp1", "tp2", "tp3")
WIN = {"sl": (2, 10), "tp1": (2, 7), "tp2": (6, 12), "tp3": (10, 20)}


def candidates(x):
    s = f"{x:g}"
    ip, _, fp = s.partition(".")
    out = set()
    for i in range(len(ip)):
        for d in "0123456789":
            out.add(ip[:i] + d + ip[i + 1:])
        if i + 1 < len(ip):
            out.add(ip[:i] + ip[i + 1] + ip[i] + ip[i + 2:])
        out.add(ip[:i] + ip[i + 1:])
    for i in range(len(ip) + 1):
        for d in "0123456789":
            out.add(ip[:i] + d + ip[i:])
    res = {float(c + ("." + fp if fp else "")) for c in out if c and c[0] != "0"}
    res.discard(x)
    return res


def in_window(k, v, side, lo, hi):
    if k not in WIN:
        return True
    w0, w1 = WIN[k]
    if k == "sl":
        d = (lo - v) if side == "buy" else (v - hi)
    else:
        d = (v - hi) if side == "buy" else (lo - v)
    return w0 <= d <= w1


def check(v, word, strict=()):
    """'' if the levels are a valid signal, else the reason. strict: keys that must sit in Orient's window."""
    lo, hi, sl = min(v["a"], v["b"]), max(v["a"], v["b"]), v["sl"]
    if not 0 < hi - lo <= 15:
        return f"zone {v['a']:g}-{v['b']:g} is {hi - lo:g} wide (max 15)"
    geo = "buy" if sl < lo else ("sell" if sl > hi else None)
    if geo is None:
        return f"SL {sl:g} is inside the zone"
    if word and word != geo:
        return f"says {word}, but SL {sl:g} is on the {geo} side"
    side = geo
    if (lo - sl if side == "buy" else sl - hi) > 20:
        return f"SL {sl:g} is more than 20 from the zone"
    tp = [v["tp1"], v["tp2"], v["tp3"]]
    for i, x in enumerate(tp):
        if not ((hi - 5 < x < hi + 40) if side == "buy" else (lo - 40 < x < lo + 5)):
            return f"TP{i + 1} {x:g} is not on the {side} side of the zone"
    if not ((tp[0] < tp[1] < tp[2]) if side == "buy" else (tp[0] > tp[1] > tp[2])):
        return "TP1, TP2, TP3 are not in order"
    for k in strict:
        if not in_window(k, v[k], side, lo, hi):
            return f"{k} {v[k]:g} outside the usual place"
    return ""


def side_of(v, word):
    lo, hi = min(v["a"], v["b"]), max(v["a"], v["b"])
    if word:
        return word
    return "buy" if v["sl"] < lo else ("sell" if v["sl"] > hi else None)


def parse(text, price):
    """(levels dict, fixes) or (None, reason). reason '' = not a signal at all."""
    t = text.lower().replace("\u2013", "-").replace("\u2014", "-").replace(",", " ")
    m_sl = re.search(r"\b(?:sl|stop ?loss)\s*[:@=]?\s*" + NUM + r"(?!\s*pips)", t)
    tps = re.findall(r"\btp\s*([1-3])?\s*[:@=]?\s*" + NUM + r"(?!\s*pips)", t)
    PRICE = r"(\d{3,5}(?:\.\d+)?)"
    z = re.search(PRICE + r"\s*-\s*" + PRICE, t[:m_sl.start()] if m_sl else t)
    if not z or (not m_sl and len(tps) < 3):
        return None, ""                      # no price zone, or no SL and no TPs: not a signal
    if not m_sl:
        return None, "no SL"
    if len(tps) < 3:
        return None, "needs TP1, TP2 and TP3"
    digits = [d for d, _ in tps[:3]]
    if sorted(digits) == ["1", "2", "3"]:
        tpv = {d: float(x) for d, x in tps[:3]}
        tp = [tpv["1"], tpv["2"], tpv["3"]]
    else:
        tp = [float(x) for _, x in tps[:3]]
    w = re.search(r"\b(buy|sell)\b", t)
    word = w.group(1) if w else None
    v = dict(zip(KEYS, [float(z.group(1)), float(z.group(2)), float(m_sl.group(1))] + tp))
    fixes = []
    far = [k for k in KEYS if abs(v[k] - price) > FAR]
    if far:
        done = False
        for s in (100, -100, 200, -200, 1000, -1000):
            trial = dict(v)
            for k in far:
                trial[k] = v[k] + s
            if all(abs(trial[k] - price) <= FAR for k in KEYS) and not check(trial, word, [k for k in far if k in WIN]):
                fixes = [f"{k.upper()} {v[k]:g} -> {trial[k]:g}" for k in far]
                v, done = trial, True
                break
        if not done:
            for k in sorted(far, key=lambda k: KEYS.index(k)):     # zone ends first, then SL, then TPs
                c = [y for y in candidates(v[k]) if abs(y - price) <= FAR]
                if k in ("a", "b"):
                    other = v["b" if k == "a" else "a"]
                    if abs(other - price) <= FAR:
                        c = [y for y in c if 0 < abs(y - other) <= 15]
                else:
                    side = side_of(v, word)
                    lo, hi = min(v["a"], v["b"]), max(v["a"], v["b"])
                    if side is None:
                        c = [y for y in c if in_window(k, y, "buy", lo, hi) or in_window(k, y, "sell", lo, hi)]
                    else:
                        c = [y for y in c if in_window(k, y, side, lo, hi)]
                if len(c) != 1:
                    return None, f"{k.upper()} {v[k]:g} looks mistyped (far from the price {price:.1f}) and could not be repaired"
                fixes.append(f"{k.upper()} {v[k]:g} -> {c[0]:g}")
                v[k] = c[0]
    why = check(v, word)
    if why and why.startswith("TP"):
        # one TP on the wrong side / out of order although near the price: one-edit repair in its window
        side = side_of(v, word)
        lo, hi = min(v["a"], v["b"]), max(v["a"], v["b"])
        bad = [k for k in ("tp1", "tp2", "tp3") if not in_window(k, v[k], side, lo, hi)]
        if len(bad) == 1:
            k = bad[0]
            c = [y for y in candidates(v[k]) if in_window(k, y, side, lo, hi)]
            if len(c) == 1:
                trial = dict(v)
                trial[k] = c[0]
                if not check(trial, word):
                    fixes.append(f"{k.upper()} {v[k]:g} -> {c[0]:g}")
                    v, why = trial, ""
    if why:
        return None, why
    lo, hi = min(v["a"], v["b"]), max(v["a"], v["b"])
    return {"side": side_of(v, word), "lo": lo, "hi": hi, "sl": v["sl"], "tp": [v["tp1"], v["tp2"], v["tp3"]],
            "word": bool(word)}, fixes


MONTHS = {m: i for i, m in enumerate(["January", "February", "March", "April", "May", "June", "July", "August",
                                      "September", "October", "November", "December"], 1)}
REL = {"Sunday": 4, "Monday": 5, "Tuesday": 6, "Wednesday": 7, "Thursday": 8, "Yesterday": 9, "Today": 10}  # export on 2026-10-10


def live_price(m):
    parts = m["d"].split()
    mo, day = (MONTHS[parts[0]], int(parts[1])) if len(parts) == 2 else (10, REL[parts[0]])
    hh, mm = map(int, m["time"].split()[-1].split(":"))
    srv = dt.datetime(2026, mo, day, hh, mm, tzinfo=dt.timezone.utc) - dt.timedelta(hours=5)
    r = mt5.copy_rates_from("XAUUSD", mt5.TIMEFRAME_M5, srv, 1)
    return float(r[0]["close"]) if r is not None and len(r) else None


if __name__ == "__main__":
    verbose = "-v" in sys.argv
    mt5.initialize(path=r"D:\Trading\Meta5\terminal64.exe")
    msgs = json.load(open(r"D:/Trading/Orient/prestige_messages_raw.json", encoding="utf-8"))
    n = {"parsed": 0, "repaired": 0, "refused": 0, "not a signal": 0}
    for m in msgs:
        text = m.get("t") or ""
        p = live_price(m)
        r, info = parse(text, p)
        if r and info:
            n["repaired"] += 1
            print(f"REPAIRED {m['d']} {m['time']} price {p:.1f} | {'; '.join(info)} | -> {r['side']} {r['lo']:g}-{r['hi']:g} SL {r['sl']:g} TP {r['tp']}")
        elif r:
            n["parsed"] += 1
            if verbose:
                print(f"OK {m['d']} | {r['side']} {r['lo']:g}-{r['hi']:g} SL {r['sl']:g} TP {r['tp']}")
        elif info:
            n["refused"] += 1
            print(f"REFUSED  {m['d']} {m['time']} price {p:.1f} | {info} | {text.replace(chr(10), ' / ')[:100]}")
        else:
            n["not a signal"] += 1
    print(n)
    gp = [m for m in msgs if "gameplan" in (m.get("t") or "").lower()]
    print("GP posts parsed as a signal (must be 0):", sum(1 for m in gp if parse(m["t"], 4300)[0]))
    mt5.shutdown()
