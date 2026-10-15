"""Copy the tool sources from an MT5 data folder into this repo.

The MT5 folder stays the place where the tools are edited and compiled; run this, check `git diff`,
then commit. Only the files listed below are copied (never logs, levels.csv or gameplan.csv).

    python tools/sync_from_mt5.py [MT5 data folder]   (default: D:/Trading/Meta5)
"""
import shutil
import sys
from pathlib import Path

FILES = [
    "MQL5/Experts/TradeBot.mq5",
    "MQL5/Experts/NewsGuard.mq5",
    "MQL5/Scripts/ApplyLevels.mq5",
    "MQL5/Scripts/BreakEven.mq5",
    "MQL5/Scripts/CloseAll.mq5",
    "MQL5/Scripts/GamePlanZones.mq5",
    "MQL5/Presets/NewsGuard_NFP.set",
]


def main() -> None:
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "D:/Trading/Meta5")
    repo = Path(__file__).resolve().parent.parent
    for rel in FILES:
        a, b = src / rel, repo / rel
        if not a.exists():
            print(f"missing: {a}")
            continue
        same = b.exists() and a.read_bytes() == b.read_bytes()
        if not same:
            b.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(a, b)
        print(f"{'same   ' if same else 'updated'} {rel}")


if __name__ == "__main__":
    main()
