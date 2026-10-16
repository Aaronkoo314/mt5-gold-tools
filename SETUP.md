# 常开电脑安装说明

这台电脑一直开着 MT5，挂 **NewsGuard** 和 **TradeBot**。你在手机上下的单，由它自动加止损、移保本；Telegram 按钮也由它执行。

**规则：同一个 EA 只挂在一台电脑上。** NewsGuard 和 TradeBot 只挂在这台，原来那台电脑上要移除。脚本（ApplyLevels、BreakEven、CloseAll、GamePlanZones）两台都可以用。

## 1. 安装 MT5 并登录

1. 从 Axi 下载 MT5，登录你的账户，勾选「保存密码」。
2. 同一个账户可以同时在手机、原来那台电脑和这台电脑上登录。

## 2. 复制工具

1. 在 MT5 里点「文件 → 打开数据文件夹」。
2. 把压缩包里的 `MQL5` 文件夹拖进这个数据文件夹，合并并覆盖同名文件。
3. 在导航器里右键 → 刷新。应该能看到：
   - 「智能交易系统」下的 NewsGuard、TradeBot；
   - 「脚本」下的 ApplyLevels、BreakEven、CloseAll、GamePlanZones。
4. 压缩包里有编译好的 `.ex5`，可以直接用。如果加载不了（MT5 版本不同），就在 MetaEditor 里打开对应的 `.mq5`，按 F7 编译，结果要是 0 errors。

## 3. 图表配色和快捷键（和原来那台一样）

1. 压缩包里的 `MQL5/Profiles/Templates` 有 3 个模板，第 2 步已经一起复制过去了：
   - `default.tpl`：新开的图表自动用这套深色配色（背景 #0E1117，阳线蓝色，阴线接近白色，有网格）；
   - `Gold Dark.tpl`：同一套配色；
   - `Gold Dark EMA.tpl`：同一套配色，加 EMA。
2. 已经开着的图：右键 → 模板 → `Gold Dark`。
3. MT5 窗口本身的暗色主题是终端设置，要在菜单里手动选一次暗色主题。
4. 快捷键（Alt+L ApplyLevels、Alt+E BreakEven、Alt+X CloseAll）：**先关掉 MT5**，再把压缩包里的 `config/hotkeys.ini` 复制到数据文件夹的 `config` 文件夹，然后打开 MT5。MT5 开着的时候复制会被覆盖。也可以在导航器里对脚本右键 →「设置快捷键」，自己设。

## 4. 打开算法交易和 WebRequest

1. 点「工具 → 选项 → 智能交易系统」：
   - 勾选「允许算法交易」；
   - 勾选「允许 WebRequest 访问下列 URL」，加入 `https://api.telegram.org`。
2. 工具栏的 **Algo Trading** 按钮要是绿色。

## 5. 图 1：NewsGuard

1. 点「文件 → 新图表 → XAUUSD」。
2. 把 NewsGuard 拖到图上，在「输入参数」页点「载入」，选一个预设：
   - `NewsGuard_SL80_BE40.set`：止损 $8，浮盈 $4 保本；
   - `NewsGuard_NFP.set`：止损 $10，浮盈 $4 保本。
3. 在「常规」页勾选「允许算法交易」，点确定。
4. 图左上角的状态行应该显示 `stop 80 pips (8.00) | breakeven at +40 pips (4.00)`。

## 6. 图 2：TradeBot（一定要另开一张 XAUUSD 图）

1. **先在原来那台电脑上移除 TradeBot。** 同一个机器人只能有一个 TradeBot 在读，否则会冲突。
2. 再开一张 XAUUSD 图，把 TradeBot 拖上去。
3. `InpBotToken`：在 Telegram 找 @BotFather，发 `/mybots`，选 Trade4Me → API Token，复制完整的 token（样子是 `1234567890:AAH…`）。
4. `InpChatId` 先填 0，点确定。
5. 在手机上给机器人发 `/start`，它会回复你的 chat id。把 chat id 填进 `InpChatId`，再点确定。
6. 手机收到「TradeBot 已启动」和按钮，就设好了。

## 7. 保存，让它重启后自动恢复

1. 点「文件 → 配置文件 → 另存为」，起名例如「常开」。MT5 重新打开时会恢复这两张图和 EA。
2. 开机自动打开 MT5：按 Win+R，输入 `shell:startup`，把 MT5（`terminal64.exe`）的快捷方式放进去。
3. Windows 设置：
   - 「系统 → 电源」：屏幕和睡眠都设「从不」；
   - 「Windows 更新 → 高级选项 → 活跃时间」：设成你交易的时间（例如 08:00–02:00），避免这段时间自动重启。
4. 重启电脑测试一次：开机后 MT5 自动打开，两张图都在，图右上角的 EA 图标是激活状态。

## 8. 用 0.01 手测试

1. 在手机上下 1 张 0.01 手。几秒内 NewsGuard 应该加上止损（「工具箱 → 智能交易系统」日志里有 `stop loss ->`）。
2. 在 Telegram 点「状态」，应该有回复。再试「保本」「平 50%」「全平」（要点确认）。
3. 转发一条他的喊单给机器人，应该回复「已记下喊单」和套用计划。

## 平时怎么用

- **喊单**：把他的喊单转发给机器人。进场后在 30 分钟内点「套用 levels」，再点确认。过了 30 分钟，再转发一次同一条喊单就行（他发出后 120 分钟内都可以）。
- **levels.csv 每台电脑各有一份。** 机器人写在这台电脑上，所以要用这台的 TradeBot 套用。原来那台电脑上的 Alt+L 只读原来那台的文件。
- **NewsGuard「价格到 TP1 就保本」**只对在这台电脑上套用的 levels 有效。
- **不要往 NewsGuard 那张图上拖别的 EA 或模板**，会把它换掉。10/14 和 10/15 两次，NewsGuard 都在 CloseAll 运行前几秒被移除，原因待查。

## 安全

- token 只填在 MT5 里，不要发给别人，也不要提交进仓库。泄露了就在 @BotFather 用 `/revoke` 换一个新的。
- 部分平仓和全平不能撤销。新设置一定先用 0.01 手测试。
