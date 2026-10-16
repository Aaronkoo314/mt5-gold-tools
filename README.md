# MT5 黄金交易工具

XAUUSD（黄金）用的 MT5 工具。可以用手机 Telegram 管理持仓，也可以：
- 自动加止损、自动保本；
- 按喊单设置 SL / TP；
- 一键保本、一键全平；
- 在图上画 GP 区。

**所有工具都不开新仓。**

## 工具一览

| 工具 | 类型 | 做什么 | 建议快捷键 |
|---|---|---|---|
| `TradeBot` | EA | Telegram 按钮：保本、平 25% / 50% / 75%、减仓、全平、套用 levels、状态 | — |
| `NewsGuard` | EA | 没有止损的单自动加止损；浮盈 40 pips 或价格到喊单 TP1 时自动保本；层数超过上限时报警 | — |
| `ApplyLevels` | 脚本 | 按 `levels.csv` 给喊单方向的持仓设一个 SL 和 TP1–TP3。先显示预览，点 OK 才改 | Alt+L |
| `BreakEven` | 脚本 | 把所有持仓的止损移到开仓价。不放松止损，保留 TP | Alt+E |
| `CloseAll` | 脚本 | 平掉本品种的所有持仓。挂单不动 | Alt+X |
| `GamePlanZones` | 脚本 | 按 `gameplan.csv` 在图上画区。每次先删掉上次画的 | — |

## 安装

1. 在 MT5 里点「文件 → 打开数据文件夹」。把本仓库 `MQL5/` 里的文件复制到同名的子文件夹。
2. 在 MetaEditor 里打开每个 `.mq5`，按 F7 编译。结果要是 0 errors。
3. 在导航器里右键刷新。脚本可以在右键菜单的「设置快捷键」里设快捷键。
4. 工具栏的 **Algo Trading** 要是绿色，不然改不了单。

一个图表只能挂一个 EA。TradeBot 和 NewsGuard 各用一张 XAUUSD 图。

想让 NewsGuard 和 TradeBot 一直运行（电脑关了也不影响手机下单），就把它们挂在一台常开的电脑上，步骤见 [SETUP.md](SETUP.md)。同一个 EA 只能挂在一台电脑上。

## TradeBot 设置

1. 在 Telegram 找 @BotFather，发 `/newbot` 建一个机器人，拿到 token。再发 `/setjoingroups`，选这个机器人，选 Disable。
2. 在 MT5 里点「工具 → 选项 → 智能交易系统」，勾选「允许 WebRequest」，加入 `https://api.telegram.org`。
3. 把 TradeBot 拖到一张 XAUUSD 图上：
   - 勾选「允许算法交易」；
   - `InpBotToken` 填 token；
   - `InpChatId` 先填 0。
4. 在手机上给机器人发 `/start`，它会回复你的 chat id。把 chat id 填进 `InpChatId`。手机收到「TradeBot 已启动」和按钮，就设好了。
5. 先用 0.01 手测试：状态 → 保本 → 平 50% → 全平。

电脑和 MT5 必须一直开着（不能睡眠）。

### 按钮规则

- **保本**：和 BreakEven 一样。还没浮盈到开仓价外的单跳过。
- **平 25% / 50% / 75%**：
  - 每个方向分开算；手数按 0.01 取整，至少留一个最小手数；
  - 最差的进场先平（卖单从价格最低的开始，买单从价格最高的开始）；
  - 先同时平整张单，最后最多部分平一张。
- **减仓**：平掉 `InpDeriskPct`%（默认 50%），剩下的移到保本。
- **全平**：和 CloseAll 一样。挂单不动，「状态」会显示挂单数量。
- **套用 levels**：和 ApplyLevels 一样，先显示计划。预览之后如果 `levels.csv`、持仓或 TP 分配变了，就不执行。
- **转发喊单**：把喊单（例如 `Gold sell zone 4154-4159 SL 4164 TP1 4150 TP2 4145 TP3 4140`）转发或粘贴给机器人，它会：
  - 识别区间、SL 和 TP1–TP3。消息里没写买或卖时，按 SL 在区间的哪一边判断；
  - 按现价改正一位数字打错的价格（例如 4434-4439 → 4334-4339），改了什么都写在回复里；
  - 写好 `levels.csv`，显示「套用 levels」的计划和确认按钮；还没有进场时，提示进场后再点「套用 levels」；
  - 他发出超过 120 分钟的喊单不写；写好后 30 分钟内要点「套用 levels」，过了时间再转发一次同一条喊单。
  - 转发的消息只用来识别喊单，不会执行任何别的命令。
- **减仓、全平、套用 levels** 要在 `InpConfirmS` 秒（默认 30）内再点一次「确认」。
- 只有最新一条消息上的按钮有效。旧按钮、或同一个按钮点两次，都不执行。
- 只接受 `InpChatId` 发来的命令。这些也不执行：
  - EA 启动前发的命令；
  - 超过 `InpMaxCmdAgeS` 秒（默认 60）的文字命令；
  - 转发的消息里的命令（转发只用来识别喊单）；
  - 断线期间点的按钮。
- 一个 bot token 只能给一个 TradeBot 用。另一个程序也在读这个机器人时，MT5 会报警。

## levels.csv 和 gameplan.csv

示例在 `MQL5/Files/levels.example.csv` 和 `MQL5/Files/gameplan.example.csv`。用的时候复制成 `levels.csv` / `gameplan.csv`，放在 MT5 的 `MQL5/Files/` 里。这两个文件是当天的实时数据，已经在 `.gitignore` 里，不会被提交。

- `levels.csv`：`created` 要写电脑本地时间。超过 `max_age_min` 分钟的文件会被拒绝。
- `gameplan.csv`：每行 `kind;low;high;label;tooltip`。`high=0` 时画一条线。

## 更新这个仓库

工具在 MT5 的数据文件夹里修改和编译。改完后运行：

```
python tools/sync_from_mt5.py D:/Trading/Meta5
```

然后看 `git diff`，确认后提交并推送。

## 安全

- **不要把 bot token 提交进仓库。** MT5 会把 EA 的输入（包括 token）明文存在图表配置里。token 泄露了，就在 @BotFather 里撤销，换一个新的。
- TradeBot 只用于对冲（hedging）账户。
- 部分平仓和全平不能撤销。新设置一定先用 0.01 手测试。
