//+------------------------------------------------------------------+
//| TradeBot.mq5  (v1.21)                                            |
//| Telegram trade-management bot for the open positions of one      |
//| symbol (default: this chart's) on a hedging account. Buttons in  |
//| your private Telegram chat: breakeven, close 25/50/75 %, derisk, |
//| close all, apply levels.csv, status. Works on positions opened   |
//| anywhere (phone, desktop). It never opens positions.             |
//|                                                                  |
//| Setup: create a bot with @BotFather (one bot per TradeBot; turn  |
//| off "Allow Groups"), put its token in InpBotToken, add           |
//| https://api.telegram.org under Tools > Options > Expert Advisors |
//| > Allow WebRequest, attach to a chart of the symbol (not the     |
//| chart that runs NewsGuard: one EA per chart), send /start to the |
//| bot: it answers with your chat id; put that in InpChatId. Only   |
//| that chat can give commands. The token is saved in plain text in |
//| the chart profile: if it leaks, revoke it in @BotFather.         |
//|                                                                  |
//| Rules:                                                           |
//|  - breakeven: like the BreakEven script v2 (never loosens, keeps |
//|    the TP, skips positions not yet far enough in profit)         |
//|  - close N %: per direction, N % of the open volume rounded to   |
//|    the volume step, at least one minimum lot stays open; worst   |
//|    entries first (sell: lowest entry, buy: highest); whole       |
//|    positions are closed all at once (async), then at most one    |
//|    position per direction is closed partly                       |
//|  - derisk: close InpDeriskPct % that way, then breakeven the rest|
//|  - close all: every position of the symbol, like CloseAll v2     |
//|    (pending orders are not touched; status shows them)           |
//|  - levels: same checks and TP split as the ApplyLevels script;   |
//|    shows the plan first; the confirm applies only if levels.csv, |
//|    the positions and the TP split did not change since           |
//|  - close all / derisk / levels need a second tap (confirm)       |
//|  - only the buttons of the newest bot message act; older buttons |
//|    and a second tap on the same message do nothing               |
//|  - skipped: commands sent before the EA started, typed commands  |
//|    older than InpMaxCmdAgeS, forwarded messages, button taps     |
//|    read after a gap in the connection longer than InpMaxCmdAgeS  |
//|    or that Telegram says are too old                             |
//+------------------------------------------------------------------+
#property version     "1.21"
#property description "Telegram buttons: breakeven, close 25/50/75%, derisk, close all, levels.csv, status"

#include <Trade\Trade.mqh>

input string InpBotToken   = "";    // Telegram bot token from @BotFather (one bot per TradeBot)
input long   InpChatId     = 0;     // Your Telegram chat id (0 = pairing: the bot only tells you your id)
input string InpSymbol     = "";    // Symbol to manage ("" = this chart's symbol)
input double InpDeriskPct  = 50;    // Derisk: % of the volume to close (worst entries first), then breakeven
input int    InpPollMs     = 500;   // Pause between two requests to Telegram (ms)
input int    InpMaxCmdAgeS = 60;    // Ignore typed commands older than this; also the longest connection gap (seconds)
input int    InpConfirmS   = 30;    // Close all / derisk / levels: confirm within this many seconds

#define TG_URL  "https://api.telegram.org/bot"
#define MAGIC   261009
#define LONGPOLL 10                 // seconds Telegram may hold a getUpdates request open

string   g_sym = "";
string   g_token = "";             // InpBotToken without spaces, quotes or a leading "bot"
string   g_lock = "";              // terminal global variable: one TradeBot per token
long     g_lockKey = 0;
long     g_offset = 0;
bool     g_primed = false;         // first getUpdates done (older commands skipped)
string   g_pending = "";           // command waiting for its confirm tap
datetime g_pendingT = 0;
string   g_pendingFp = "";         // what the preview showed
string   g_status = "";
int      g_seq = 0;                // id of the newest keyboard: only its buttons act
long     g_kbMsg = 0;              // message_id of the newest message with buttons (kept in g_kbVar)
string   g_kbVar = "";             // terminal global variable that keeps g_kbMsg across restarts
bool     g_kbOk = true;            // the newest keyboard reached Telegram
bool     g_pollKb = false;         // a keyboard was delivered while handling this poll
uint     g_lastOk = 0;             // end of the last good getUpdates (GetTickCount)
bool     g_conflict = false;       // another reader of this bot was reported
string   g_unsent = "";            // results that did not reach Telegram
int      g_unsentTries = 0;
CTrade   trade;

//+------------------------------------------------------------------+
//| small helpers                                                    |
//+------------------------------------------------------------------+
string Px(const double p) { return DoubleToString(p, (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS)); }

string Acct()
  {
   return(StringFormat("%I64d %s", AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER)));
  }

void Status(const string s)
  {
   if(s != g_status)
      Print("TradeBot: ", s);
   g_status = s;
   Comment("TradeBot  |  " + g_sym + "  |  " + Acct() + "  |  " + s);
  }

bool TradingAllowed()
  {
   return(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED));
  }

string LastErr() { return(StringFormat("%u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription())); }

// The token as Telegram expects it ("123456789:AAx..."): spaces, line breaks, quotes and a leading
// "bot" that come with a copy and paste are removed. Returns "" and the reason (never the token) if the
// format is wrong.
string CleanToken(const string raw, string &why)
  {
   string t = "";
   for(int i = 0; i < StringLen(raw); i++)
     {
      ushort c = StringGetCharacter(raw, i);
      if(c > ' ' && c != '"' && c != '\'' && c != '<' && c != '>' && c != 0x200B && c != 0xFEFF && c != 0xA0)
         t += ShortToString(c);
     }
   if(t == "")
     { why = "put your bot token in InpBotToken (from @BotFather)"; return(""); }
   string low = t;
   StringToLower(low);
   if(StringFind(low, "bot") == 0 && StringLen(t) > 3 && StringGetCharacter(t, 3) >= '0' && StringGetCharacter(t, 3) <= '9')
      t = StringSubstr(t, 3);
   int colon = StringFind(t, ":");
   if(colon <= 0)
     { why = StringFormat("bot token format is wrong: no ':' (%d characters). It looks like 123456789:AAH... - copy it again from @BotFather", StringLen(t)); return(""); }
   for(int i = 0; i < colon; i++)
     {
      ushort c = StringGetCharacter(t, i);
      if(c < '0' || c > '9')
        { why = "bot token format is wrong: the part before ':' must be digits only - copy it again from @BotFather"; return(""); }
     }
   int tail = StringLen(t) - colon - 1;
   for(int i = colon + 1; i < StringLen(t); i++)
     {
      ushort c = StringGetCharacter(t, i);
      if(!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '-'))
        { why = "bot token format is wrong: a character after ':' is not a letter, digit, '_' or '-' - copy it again from @BotFather"; return(""); }
     }
   if(tail < 30)
     { why = StringFormat("bot token looks cut off: %d characters after ':' (normally 35) - copy all of it from @BotFather", tail); return(""); }
   if(t != InpBotToken)
      Print("TradeBot: removed spaces, quotes or a leading 'bot' from the token you pasted");
   why = "";
   return(t);
  }

// the server refused the request, so nothing was executed and one more try is safe
bool Refused(const uint rc)
  {
   return(rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_REJECT || rc == TRADE_RETCODE_PRICE_CHANGED ||
          rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TOO_MANY_REQUESTS || rc == TRADE_RETCODE_CONNECTION);
  }

int StepDigits()
  {
   double step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   return((int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9)));
  }

double VolFloor(const double v)
  {
   double step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   return(NormalizeDouble(MathFloor(v / step + 1e-9) * step, StepDigits()));
  }

double VolRound(const double v)
  {
   double step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   return(NormalizeDouble(MathRound(v / step + 1e-9) * step, StepDigits()));
  }

int PendingOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t != 0 && OrderGetString(ORDER_SYMBOL) == g_sym)
         n++;
     }
   return(n);
  }

string JsonEsc(const string s)
  {
   string r = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '\\')      r += "\\\\";
      else if(c == '"')  r += "\\\"";
      else if(c == '\n') r += "\\n";
      else if(c < 0x20)  r += StringFormat("\\u%04x", c);
      else               r += ShortToString(c);
     }
   return(r);
  }

// index of "key": directly inside the object that starts at the first '{' at or after 'from'
// (keys of nested objects are not matched); -1 if missing
int TopKey(const string js, const string key, const int from)
  {
   if(from < 0)
      return(-1);
   int i = StringFind(js, "{", from);
   if(i < 0)
      return(-1);
   int n = StringLen(js);
   string pat = "\"" + key + "\":";
   int plen = StringLen(pat);
   int depth = 0;
   bool inStr = false;
   for(; i < n; i++)
     {
      ushort c = StringGetCharacter(js, i);
      if(inStr)
        {
         if(c == '\\') { i++; continue; }
         if(c == '"') inStr = false;
         continue;
        }
      if(c == '"')
        {
         if(depth == 1 && StringSubstr(js, i, plen) == pat)
            return(i);
         inStr = true;
         continue;
        }
      if(c == '{' || c == '[')
         depth++;
      else if(c == '}' || c == ']')
        {
         depth--;
         if(depth == 0)
            return(-1);
        }
     }
   return(-1);
  }

// value of the first "key": at or after 'from' (string or number); "" if missing
string JVal(const string js, const string key, const int from)
  {
   if(from < 0)
      return("");
   int k = StringFind(js, "\"" + key + "\":", from);
   if(k < 0)
      return("");
   int i = k + StringLen(key) + 3;
   int n = StringLen(js);
   while(i < n && StringGetCharacter(js, i) == ' ')
      i++;
   if(i >= n)
      return("");
   if(StringGetCharacter(js, i) == '"')
     {
      string out = "";
      i++;
      while(i < n)
        {
         ushort c = StringGetCharacter(js, i);
         if(c == '"')
            break;
         if(c == '\\' && i + 1 < n)
           {
            ushort e = StringGetCharacter(js, i + 1);
            if(e == 'n') out += "\n";
            else if(e == 'u' && i + 5 < n)
              {
               ushort u = (ushort)StringToInteger("0x" + StringSubstr(js, i + 2, 4));
               out += ShortToString(u);
               i += 4;
              }
            else out += ShortToString(e);
            i += 2;
            continue;
           }
         out += ShortToString(c);
         i++;
        }
      return(out);
     }
   int j = i;
   while(j < n)
     {
      ushort c = StringGetCharacter(js, j);
      if(c == ',' || c == '}' || c == ']')
         break;
      j++;
     }
   string v = StringSubstr(js, i, j - i);
   StringTrimLeft(v);
   StringTrimRight(v);
   return(v);
  }

// id of the object under top-level "key" (e.g. "from":{"id":..}) of the object at 'from'
long ObjId(const string js, const string key, const int from)
  {
   int k = TopKey(js, key, from);
   return(k < 0 ? 0 : StringToInteger(JVal(js, "id", k)));
  }

//+------------------------------------------------------------------+
//| one TradeBot per bot token in this terminal                      |
//+------------------------------------------------------------------+
string TokenHash()
  {
   uint h = 5381;
   for(int i = 0; i < StringLen(g_token); i++)
      h = h * 33 + StringGetCharacter(g_token, i);
   return(IntegerToString(h));
  }

long ChartKey(const long id) { return(id % 1000000000 + 1); }   // fits a double exactly, never 0

bool ChartOpen(const long key)
  {
   for(long id = ChartFirst(); id >= 0; id = ChartNext(id))
      if(ChartKey(id) == key)
         return(true);
   return(false);
  }

// atomic: two charts that start at the same moment cannot both get the lock
bool TakeLock()
  {
   g_lock = "TradeBot_lock_" + TokenHash();
   g_lockKey = ChartKey(ChartID());
   GlobalVariableTemp(g_lock);                          // creates it with 0 if it is missing
   if(GlobalVariableSetOnCondition(g_lock, (double)g_lockKey, 0))
      return(true);
   long other = (long)GlobalVariableGet(g_lock);
   if(other == g_lockKey)
      return(true);                                     // this chart had it already (reinit)
   if(ChartOpen(other))
      return(false);
   return(GlobalVariableSetOnCondition(g_lock, (double)g_lockKey, (double)other));   // owner's chart is gone
  }

void FreeLock()
  {
   if(g_lock != "" && GlobalVariableCheck(g_lock) && (long)GlobalVariableGet(g_lock) == g_lockKey)
      GlobalVariableDel(g_lock);
  }

//+------------------------------------------------------------------+
//| Telegram                                                         |
//+------------------------------------------------------------------+
int TgCall(const string method, const string body, string &resp, const int timeoutMs)
  {
   char data[], result[];
   string rh;
   if(body != "")
     {
      StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(data, ArraySize(data) - 1);          // drop the trailing 0
     }
   ResetLastError();
   int code = WebRequest(body != "" ? "POST" : "GET", TG_URL + g_token + "/" + method,
                         "Content-Type: application/json\r\n", timeoutMs, data, result, rh);
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code == -1)
     {
      int e = GetLastError();
      Status(e == 4014 ? "WebRequest not allowed: add https://api.telegram.org in Tools > Options > Expert Advisors"
                       : StringFormat("no connection to Telegram (error %d)", e));
     }
   else if(code == 401 || code == 404)
      Status(StringFormat("Telegram rejected the bot token (HTTP %d) - copy it again: @BotFather > /mybots > your bot > API Token", code));
   else if(code == 409)
      Status("another program is reading this bot (webhook or a second TradeBot) - commands are not read");
   return(code);
  }

string MenuKb()
  {
   string s = ":" + IntegerToString(g_seq);
   return("{\"inline_keyboard\":["
          "[{\"text\":\"保本 BE\",\"callback_data\":\"be" + s + "\"},{\"text\":\"状态\",\"callback_data\":\"status" + s + "\"}],"
          "[{\"text\":\"平 25%\",\"callback_data\":\"p25" + s + "\"},{\"text\":\"平 50%\",\"callback_data\":\"p50" + s + "\"},{\"text\":\"平 75%\",\"callback_data\":\"p75" + s + "\"}],"
          "[{\"text\":\"减仓\",\"callback_data\":\"derisk" + s + "\"},{\"text\":\"全平\",\"callback_data\":\"closeall" + s + "\"}],"
          "[{\"text\":\"套用 levels\",\"callback_data\":\"levels" + s + "\"}]]}");
  }

string ConfirmKb(const string cmd)
  {
   string s = ":" + IntegerToString(g_seq);
   return("{\"inline_keyboard\":[[{\"text\":\"确认\",\"callback_data\":\"ok_" + cmd + s + "\"},"
          "{\"text\":\"取消\",\"callback_data\":\"cancel" + s + "\"}]]}");
  }

// kb: "" = no buttons, "menu", or "confirm:<cmd>". A message with buttons makes all older buttons stale.
bool TgSend(const long chat, const string text, const string kb)
  {
   string t = text;
   if(StringLen(t) > 3900)
      t = StringSubstr(t, 0, 3900) + "\n…（太长，已截断）";
   string body = "{\"chat_id\":" + IntegerToString(chat) + ",\"text\":\"" + JsonEsc(t) + "\"";
   if(kb != "")
     {
      g_seq++;
      body += ",\"reply_markup\":" + (kb == "menu" ? MenuKb() : ConfirmKb(StringSubstr(kb, 8)));
     }
   body += "}";
   string resp;
   int code = TgCall("sendMessage", body, resp, 10000);
   if(code == 429)
     {
      int wait = (int)StringToInteger(JVal(resp, "retry_after", 0));
      if(wait >= 0 && wait <= 5)
        {
         Sleep(wait * 1000 + 200);
         code = TgCall("sendMessage", body, resp, 10000);
        }
     }
   if(kb != "")
      g_kbOk = (code == 200);
   if(code != 200)
     {
      PrintFormat("TradeBot: message not delivered (%d) %s", code, StringSubstr(resp, 0, 200));
      return(false);
     }
   if(kb != "")
     {
      g_pollKb = true;
      long id = StringToInteger(JVal(resp, "message_id", 0));
      if(g_kbMsg > 0 && id != g_kbMsg)                 // remove the buttons of the previous message
         TgCall("editMessageReplyMarkup", StringFormat("{\"chat_id\":%I64d,\"message_id\":%I64d}", chat, g_kbMsg), resp, 5000);
      g_kbMsg = id;
      if(g_kbVar != "")
         GlobalVariableSet(g_kbVar, (double)id);
     }
   return(true);
  }

// HTTP code of answerCallbackQuery (400 = Telegram refuses, e.g. the tap is too old)
int TgAnswer(const string cbId, const string text)
  {
   string resp;
   int code = TgCall("answerCallbackQuery", "{\"callback_query_id\":\"" + JsonEsc(cbId) + "\",\"text\":\"" + JsonEsc(text) + "\"}", resp, 5000);
   if(code != 200)
      PrintFormat("TradeBot: button answer refused (%d) %s", code, StringSubstr(resp, 0, 200));
   return(code);
  }

//+------------------------------------------------------------------+
//| positions                                                        |
//+------------------------------------------------------------------+
struct Pos
  {
   ulong  tk;
   double vol;
   double op;
   bool   buy;
   double sl;
   double tp;
   double pnl;
  };

int Collect(Pos &ps[])
  {
   ArrayResize(ps, 0);
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      ArrayResize(ps, n + 1);
      ps[n].tk  = t;
      ps[n].vol = PositionGetDouble(POSITION_VOLUME);
      ps[n].op  = PositionGetDouble(POSITION_PRICE_OPEN);
      ps[n].buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      ps[n].sl  = PositionGetDouble(POSITION_SL);
      ps[n].tp  = PositionGetDouble(POSITION_TP);
      ps[n].pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      n++;
     }
   return(n);
  }

// worst entry first: sell = lowest entry, buy = highest entry; equal entries: lower ticket first
bool WorseEntry(const Pos &a, const Pos &b)
  {
   if(a.op != b.op)
      return(a.buy ? a.op > b.op : a.op < b.op);
   return(a.tk < b.tk);
  }

void SortWorstFirst(Pos &ps[])
  {
   int n = ArraySize(ps);
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
         if(WorseEntry(ps[j], ps[i]))
           {
            Pos x = ps[i]; ps[i] = ps[j]; ps[j] = x;
           }
  }

double LossAt(const bool isBuy, const double vol, const double entry, const double stop)
  {
   double p = 0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_sym, vol, entry, stop, p))
      p = (isBuy ? stop - entry : entry - stop) * vol * SymbolInfoDouble(g_sym, SYMBOL_TRADE_CONTRACT_SIZE);
   return(MathMax(0.0, -p));
  }

//+------------------------------------------------------------------+
//| status                                                           |
//+------------------------------------------------------------------+
string DoStatus()
  {
   Pos ps[];
   int n = Collect(ps);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string s = StringFormat("%s  账户 %s\n余额 $%.2f  净值 $%.2f", g_sym, Acct(), bal, eq);
   int po = PendingOrders();
   if(po > 0)
      s += StringFormat("\n挂单 %d 个（TradeBot 不动挂单）", po);
   if(n == 0)
      return(s + "\n没有持仓。");
   for(int d = 0; d < 2; d++)
     {
      bool isBuy = (d == 0);
      int cnt = 0, noSl = 0, withTp = 0;
      double lots = 0, wsum = 0, pnl = 0, risk = 0, slMin = 0, slMax = 0;
      for(int i = 0; i < n; i++)
        {
         if(ps[i].buy != isBuy)
            continue;
         cnt++; lots += ps[i].vol; wsum += ps[i].op * ps[i].vol; pnl += ps[i].pnl;
         if(ps[i].tp > 0) withTp++;
         if(ps[i].sl <= 0) { noSl++; continue; }
         risk += LossAt(isBuy, ps[i].vol, ps[i].op, ps[i].sl);
         slMin = (slMin == 0) ? ps[i].sl : MathMin(slMin, ps[i].sl);
         slMax = MathMax(slMax, ps[i].sl);
        }
      if(cnt == 0)
         continue;
      string slTxt = (cnt == noSl) ? "都没有止损" :
                     (slMin == slMax ? "止损 " + Px(slMin) : "止损 " + Px(slMin) + "–" + Px(slMax));
      s += StringFormat("\n%s %d 张 %.2f 手，均价 %s，浮盈亏 $%.2f\n  %s%s；带止盈 %d 张\n  全部打到止损约 −$%.0f（余额的 %.1f%%）",
                        isBuy ? "买" : "卖", cnt, lots, Px(wsum / lots), pnl, slTxt,
                        (noSl > 0 && noSl < cnt) ? StringFormat("（%d 张没有止损）", noSl) : "",
                        withTp, risk, bal > 0 ? risk / bal * 100 : 0);
      if(noSl > 0)
         s += "\n  注意：没有止损的单不算在上面的亏损里。";
     }
   return(s);
  }

//+------------------------------------------------------------------+
//| breakeven (same rules as the BreakEven script v2)                |
//+------------------------------------------------------------------+
string BeTarget(double &newSL)
  {
   long   type    = PositionGetInteger(POSITION_TYPE);
   double open    = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl      = PositionGetDouble(POSITION_SL);
   int    digits  = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   long   lvl     = MathMax(SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(g_sym, SYMBOL_TRADE_FREEZE_LEVEL));
   double minDist = MathMax((double)lvl * point, point);
   double bid     = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double ask     = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   newSL = NormalizeDouble(open, digits);
   if(type == POSITION_TYPE_BUY)
     {
      if(sl != 0.0 && newSL <= sl + point / 2) return("already");
      if(bid - newSL < minDist) return("not in profit");
     }
   else
     {
      if(sl != 0.0 && newSL >= sl - point / 2) return("already");
      if(newSL - ask < minDist) return("not in profit");
     }
   return("");
  }

bool BeDone(const ulong t, const double target, bool &hit)
  {
   if(!PositionSelectByTicket(t))
      return(true);
   bool ok = MathAbs(PositionGetDouble(POSITION_SL) - target) < SymbolInfoDouble(g_sym, SYMBOL_POINT) / 2;
   if(ok)
      hit = true;
   return(ok);
  }

string DoBE()
  {
   ulong tk[]; double target[];
   int n = 0, notYet = 0, already = 0, total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != g_sym)
         continue;
      total++;
      double ns;
      string why = BeTarget(ns);
      if(why == "not in profit") { notYet++; continue; }
      if(why == "already")       { already++; continue; }
      ArrayResize(tk, n + 1); ArrayResize(target, n + 1);
      tk[n] = t; target[n] = ns; n++;
     }
   if(total == 0)
      return("保本：没有持仓。");
   if(n == 0)
      return(StringFormat("保本：没有要移的单（%d 张已在保本或更好，%d 张还没浮盈到开仓价外）。", already, notYet));
   uint start = GetTickCount();
   trade.SetAsyncMode(true);
   for(int i = 0; i < n; i++)
      if(PositionSelectByTicket(tk[i]))
         trade.PositionModify(tk[i], target[i], PositionGetDouble(POSITION_TP));
   trade.SetAsyncMode(false);
   bool hit[], late[];
   ArrayResize(hit, n); ArrayResize(late, n);
   ArrayInitialize(hit, false); ArrayInitialize(late, false);
   int left = n;
   while(GetTickCount() - start < 5000 && !IsStopped())
     {
      Sleep(50);
      left = 0;
      for(int i = 0; i < n; i++)
         if(!BeDone(tk[i], target[i], hit[i]))
            left++;
      if(left == 0)
         break;
     }
   string lastErr = "";
   for(int round = 0; round < 2 && left > 0 && !IsStopped(); round++)
     {
      for(int i = 0; i < n; i++)
        {
         if(late[i] || BeDone(tk[i], target[i], hit[i]))
            continue;
         double ns;
         if(BeTarget(ns) != "")
           { late[i] = true; continue; }
         target[i] = ns;
         if(!trade.PositionModify(tk[i], ns, PositionGetDouble(POSITION_TP)))
            lastErr = LastErr();
        }
      Sleep(200);
      left = 0;
      for(int i = 0; i < n; i++)
         if(!late[i] && !BeDone(tk[i], target[i], hit[i]))
            left++;
     }
   int moved = 0, lateSkip = 0, gone = 0, failed = 0;
   for(int i = 0; i < n; i++)
     {
      if(hit[i]) moved++;
      else if(late[i]) lateSkip++;
      else if(!PositionSelectByTicket(tk[i])) gone++;
      else failed++;
     }
   string s = StringFormat("保本：移好 %d 张（%.1f 秒）；%d 张已在保本或更好，%d 张还没浮盈到开仓价外。",
                           moved, (GetTickCount() - start) / 1000.0, already, notYet);
   if(lateSkip > 0) s += StringFormat("\n%d 张在发送后被跳过（价格回到开仓价内，或止损已被别的工具移好）。", lateSkip);
   if(gone > 0)     s += StringFormat("\n注意：%d 张在止损移好前就平掉了。", gone);
   if(failed > 0)   s += StringFormat("\n注意：%d 张没移成功（%s）。", failed, lastErr);
   PrintFormat("TradeBot BE: moved %d, already %d, not yet %d, skipped %d, gone %d, failed %d %s", moved, already, notYet, lateSkip, gone, failed, lastErr);
   return(s);
  }

//+------------------------------------------------------------------+
//| close a % of the volume, worst entries first                     |
//+------------------------------------------------------------------+
int OpenWhole(const Pos &pl[], const bool &whole[], const bool &onlySent, const bool &sent[])
  {
   int left = 0;
   for(int i = 0; i < ArraySize(pl); i++)
      if(whole[i] && (!onlySent || sent[i]) && PositionSelectByTicket(pl[i].tk))
         left++;
   return(left);
  }

string DoClosePct(const double pct)
  {
   Pos all[];
   int n = Collect(all);
   if(n == 0)
      return(StringFormat("平 %.0f%%：没有持仓。", pct));
   double minv = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN), step = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);

   // 1. plan: per direction, the target rounded to the volume step and leaving at least one minimum lot;
   //    worst entries first; whole positions, then at most one part
   Pos    pl[];
   double plV[];
   bool   plWhole[];
   int    np = 0;
   double total[2] = {0, 0}, target[2] = {0, 0};
   bool   has[2] = {false, false};
   for(int d = 0; d < 2; d++)
     {
      bool isBuy = (d == 0);
      Pos ps[];
      int m = 0;
      for(int i = 0; i < n; i++)
         if(all[i].buy == isBuy)
           { ArrayResize(ps, m + 1); ps[m] = all[i]; total[d] += all[i].vol; m++; }
      if(m == 0)
         continue;
      has[d] = true;
      SortWorstFirst(ps);
      double tg = VolRound(total[d] * pct / 100.0);
      if(tg > total[d] - minv + 1e-9)
         tg = VolFloor(total[d] - minv);
      if(tg < minv - 1e-9)
         tg = 0;
      target[d] = tg;
      double remaining = tg;
      for(int i = 0; i < m && remaining >= minv - 1e-9; i++)
        {
         bool whole = ps[i].vol <= remaining + 1e-9;
         double v = whole ? ps[i].vol : VolFloor(remaining);
         if(!whole && (v < minv - 1e-9 || ps[i].vol - v < minv - 1e-9))
            break;
         ArrayResize(pl, np + 1); ArrayResize(plV, np + 1); ArrayResize(plWhole, np + 1);
         pl[np] = ps[i]; plV[np] = v; plWhole[np] = whole; np++;
         remaining -= v;
         if(!whole)
            break;
        }
     }

   // 2. whole positions: all requests at once (async); then the parts, one by one
   uint start = GetTickCount();
   bool sent[], retryPart[];
   ArrayResize(sent, np); ArrayResize(retryPart, np);
   ArrayInitialize(sent, false); ArrayInitialize(retryPart, false);
   trade.SetAsyncMode(true);
   for(int i = 0; i < np; i++)
      if(plWhole[i] && PositionSelectByTicket(pl[i].tk))
         sent[i] = trade.PositionClose(pl[i].tk);
   trade.SetAsyncMode(false);
   string lastErr = "";
   for(int i = 0; i < np; i++)
      if(!plWhole[i] && PositionSelectByTicket(pl[i].tk) && !trade.PositionClosePartial(pl[i].tk, plV[i]))
        {
         lastErr = LastErr();
         retryPart[i] = Refused(trade.ResultRetcode());
        }

   // 3. wait up to 5 s for the whole closes that were sent, then retry what is still open (2 rounds)
   uint w0 = GetTickCount();
   while(OpenWhole(pl, plWhole, true, sent) > 0 && GetTickCount() - w0 < 5000 && !IsStopped())
      Sleep(50);
   int left = OpenWhole(pl, plWhole, false, sent);
   for(int round = 0; round < 2 && left > 0 && !IsStopped(); round++)
     {
      for(int i = 0; i < np; i++)
         if(plWhole[i] && PositionSelectByTicket(pl[i].tk) && !trade.PositionClose(pl[i].tk))
            lastErr = LastErr();
      Sleep(200);
      left = OpenWhole(pl, plWhole, false, sent);
     }
   // a part: one more try only when the server refused it and the volume did not change
   for(int i = 0; i < np; i++)
      if(retryPart[i] && PositionSelectByTicket(pl[i].tk) && MathAbs(PositionGetDouble(POSITION_VOLUME) - pl[i].vol) < step / 2)
         if(!trade.PositionClosePartial(pl[i].tk, plV[i]))
            lastErr = LastErr();

   // 4. results: a whole position is done when it is gone; a part when the volume went down
   int st[];                     // 1 done, 0 failed, 2 gone (closed some other way before the part was closed)
   ArrayResize(st, np);
   for(int i = 0; i < np; i++)
     {
      if(plWhole[i])
         st[i] = PositionSelectByTicket(pl[i].tk) ? 0 : 1;
      else if(!PositionSelectByTicket(pl[i].tk))
         st[i] = 2;
      else
         st[i] = (PositionGetDouble(POSITION_VOLUME) <= pl[i].vol - plV[i] + step / 2) ? 1 : 0;
     }
   string s = "";
   for(int d = 0; d < 2; d++)
     {
      if(!has[d])
         continue;
      bool isBuy = (d == 0);
      string side = isBuy ? "买" : "卖";
      if(target[d] <= 0)
        {
         s += StringFormat("%s平 %.0f%%（%s）：只有 %.2f 手，按比例不够一个最小手数，没有平。", s == "" ? "" : "\n", pct, side, total[d]);
         continue;
        }
      double closedVol = 0, pnl = 0;
      int whole = 0, part = 0, failed = 0, gone = 0;
      for(int i = 0; i < np; i++)
        {
         if(pl[i].buy != isBuy)
            continue;
         if(st[i] == 2) { gone++; continue; }
         if(st[i] == 0) { failed++; continue; }
         closedVol += plV[i];
         pnl += pl[i].pnl * plV[i] / pl[i].vol;
         if(plWhole[i]) whole++; else part++;
        }
      s += StringFormat("%s平 %.0f%%（%s）：平掉 %.2f / %.2f 手（%.0f%%），整张 %d、部分 %d，约 $%.2f。",
                        s == "" ? "" : "\n", pct, side, closedVol, total[d],
                        closedVol / total[d] * 100, whole, part, pnl);
      if(gone > 0)
         s += StringFormat("\n注意：%d 张要部分平仓的单已不在（可能是止损、止盈或手动平掉）。", gone);
      if(failed > 0)
         s += StringFormat("\n注意：%d 张没平掉（%s）。", failed, lastErr);
      PrintFormat("TradeBot close %.0f%% %s: %.2f of %.2f lots (target %.2f), whole %d, part %d, gone %d, failed %d %s",
                  pct, isBuy ? "buy" : "sell", closedVol, total[d], target[d], whole, part, gone, failed, lastErr);
     }
   return(s + StringFormat("（%.1f 秒）", (GetTickCount() - start) / 1000.0));
  }

//+------------------------------------------------------------------+
//| close all (like CloseAll v2)                                     |
//+------------------------------------------------------------------+
string DoCloseAll(const int previewCount)
  {
   Pos ps[], ps0[];
   int n0 = Collect(ps);
   if(n0 == 0)
      return("全平：没有持仓。");
   ArrayCopy(ps0, ps);
   uint start = GetTickCount();
   int sentOk = 0;
   trade.SetAsyncMode(true);
   for(int i = 0; i < n0; i++)
      if(PositionSelectByTicket(ps[i].tk) && trade.PositionClose(ps[i].tk))
         sentOk++;
   trade.SetAsyncMode(false);
   int left = n0;
   while(sentOk > 0 && GetTickCount() - start < 5000 && !IsStopped())
     {
      Sleep(50);
      left = Collect(ps);
      if(left == 0 || left <= n0 - sentOk)
         break;
     }
   left = Collect(ps);
   string lastErr = "";
   for(int round = 0; round < 2 && left > 0 && !IsStopped(); round++)
     {
      for(int i = 0; i < left; i++)
         if(PositionSelectByTicket(ps[i].tk) && !trade.PositionClose(ps[i].tk))
            lastErr = LastErr();
      Sleep(200);
      left = Collect(ps);
     }
   int closed = 0;
   double lots = 0, pnl = 0;
   for(int i = 0; i < n0; i++)
      if(!PositionSelectByTicket(ps0[i].tk))
        { closed++; lots += ps0[i].vol; pnl += ps0[i].pnl; }
   string s = StringFormat("全平：平掉 %d / %d 张（%.2f 手，约 $%.2f），%.1f 秒。", closed, n0, lots, pnl,
                           (GetTickCount() - start) / 1000.0);
   if(previewCount >= 0 && previewCount != n0)
      s += StringFormat("\n（预览时是 %d 张，执行时是 %d 张。）", previewCount, n0);
   if(left > 0)
      s += StringFormat("\n注意：还有 %d 张没平掉（%s）。", left, lastErr);
   PrintFormat("TradeBot close all: %d of %d, left %d %s", closed, n0, left, lastErr);
   return(s);
  }

//+------------------------------------------------------------------+
//| levels.csv (same checks and TP split as the ApplyLevels script)  |
//+------------------------------------------------------------------+
struct LvConfig
  {
   int      side;
   double   sl;
   double   tp[3];
   double   share1, share2, maxRiskPct;
   int      maxAgeMin;
   datetime created;
   double   zoneLo, zoneHi, zoneTol, minSlGap, maxSlDist;
  };

bool LvLoad(LvConfig &c, string &err)
  {
   c.side = 0; c.sl = 0; c.tp[0] = 0; c.tp[1] = 0; c.tp[2] = 0;
   c.share1 = 0.25; c.share2 = 0.45; c.maxRiskPct = 0; c.maxAgeMin = 30; c.created = 0;
   c.zoneLo = 0; c.zoneHi = 0; c.zoneTol = 3.0; c.minSlGap = 2.0; c.maxSlDist = 20.0;
   ResetLastError();
   int h = FileOpen("levels.csv", FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     { err = StringFormat("打不开 MQL5/Files/levels.csv（错误 %d）", GetLastError()); return(false); }
   int seen = 0;
   while(!FileIsEnding(h))
     {
      string chunk = FileReadString(h);
      string lines[];
      int cnt = StringSplit(chunk, '\n', lines);
      for(int i = 0; i < cnt; i++)
        {
         string line = lines[i];
         int hash = StringFind(line, "#");
         if(hash >= 0) line = StringSubstr(line, 0, hash);
         StringTrimLeft(line); StringTrimRight(line);
         if(line == "") continue;
         string kv[];
         if(StringSplit(line, '=', kv) != 2) { FileClose(h); err = "levels.csv 有一行格式不对：" + line; return(false); }
         string k = kv[0], v = kv[1];
         StringTrimLeft(k); StringTrimRight(k); StringToLower(k);
         StringTrimLeft(v); StringTrimRight(v);
         string vl = v; StringToLower(vl);
         if(k == "side")
           {
            if(vl == "buy") c.side = 1; else if(vl == "sell") c.side = -1;
            else { FileClose(h); err = "side 只能是 buy 或 sell"; return(false); }
            seen |= 1;
           }
         else if(k == "created")
           {
            c.created = StringToTime(v);
            if(c.created <= 0) { FileClose(h); err = "created 的格式不对"; return(false); }
            seen |= 2;
           }
         else
           {
            double x = StringToDouble(v);
            if(x == 0.0 && v != "0" && v != "0.0") { FileClose(h); err = "不是数字：" + line; return(false); }
            if(k == "sl") { c.sl = x; seen |= 4; }
            else if(k == "tp1") { c.tp[0] = x; seen |= 8; }
            else if(k == "tp2") { c.tp[1] = x; seen |= 16; }
            else if(k == "tp3") { c.tp[2] = x; seen |= 32; }
            else if(k == "tp1_share") c.share1 = x;
            else if(k == "tp2_share") c.share2 = x;
            else if(k == "max_risk_pct") c.maxRiskPct = x;
            else if(k == "max_age_min") c.maxAgeMin = (int)x;
            else if(k == "zone_lo") c.zoneLo = x;
            else if(k == "zone_hi") c.zoneHi = x;
            else if(k == "zone_tol") c.zoneTol = x;
            else if(k == "min_sl_gap") c.minSlGap = x;
            else if(k == "max_sl_dist") c.maxSlDist = x;
            else if(k == "confirm") { }
            else { FileClose(h); err = "未知设置：" + k; return(false); }
           }
        }
     }
   FileClose(h);
   if(seen != 63) { err = "levels.csv 要有 side、created、sl、tp1、tp2、tp3"; return(false); }
   if(c.sl <= 0 || c.tp[0] <= 0 || c.tp[1] <= 0 || c.tp[2] <= 0) { err = "sl 和 tp1–tp3 必须大于 0"; return(false); }
   bool geo = (c.side < 0) ? (c.sl > c.tp[0] && c.tp[0] > c.tp[1] && c.tp[1] > c.tp[2])
                           : (c.sl < c.tp[0] && c.tp[0] < c.tp[1] && c.tp[1] < c.tp[2]);
   if(!geo) { err = (c.side < 0) ? "卖单要 sl > tp1 > tp2 > tp3" : "买单要 sl < tp1 < tp2 < tp3"; return(false); }
   if(c.share1 < 0 || c.share2 < 0 || c.share1 + c.share2 > 1.0 + 1e-9) { err = "tp1_share + tp2_share 不能超过 1"; return(false); }
   if((c.zoneLo > 0) != (c.zoneHi > 0) || (c.zoneLo > 0 && c.zoneLo >= c.zoneHi)) { err = "zone_lo / zone_hi 设置不对"; return(false); }
   return(true);
  }

// Builds the plan from levels.csv, the positions and the price; fp describes it (file, levels, tickets
// and their TPs). apply = false: preview text only. apply = true: changes the stops / TPs, but only if
// fp is still expectFp (what the preview showed). Returns false when refused or something failed.
bool DoLevels(const bool apply, const string expectFp, string &txt, string &fp)
  {
   fp = "";
   if(StringFind(g_sym, "XAU") != 0 && StringFind(g_sym, "GOLD") < 0)
     { txt = "levels 只用于黄金，现在管理的是 " + g_sym; return(false); }
   LvConfig c;
   string err = "";
   if(!LvLoad(c, err)) { txt = "levels：" + err + "，没有改动。"; return(false); }
   long ageMin = (long)(TimeLocal() - c.created) / 60;
   if(c.maxAgeMin > 0 && (ageMin > c.maxAgeMin || ageMin < -5))
     { txt = StringFormat("levels.csv 是 %d 分钟前写的（上限 %d），请重新发区间。没有改动。", (int)ageMin, c.maxAgeMin); return(false); }
   MqlTick t;
   if(!SymbolInfoTick(g_sym, t) || t.ask <= 0 || t.bid <= 0) { txt = "没有报价，没有改动。"; return(false); }
   int    dg    = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double pt    = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double minD  = MathMax((double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * pt, pt);
   bool   isBuy = c.side > 0;
   double sl    = NormalizeDouble(c.sl, dg);
   double tps[3];
   for(int k = 0; k < 3; k++) tps[k] = NormalizeDouble(c.tp[k], dg);
   double gap = isBuy ? t.bid - sl : sl - t.ask;
   if(gap < MathMax(minD, c.minSlGap))
     { txt = StringFormat("止损 %s 离现价 %s 只有 %.2f，请检查。没有改动。", Px(sl), Px(isBuy ? t.bid : t.ask), gap); return(false); }
   bool tpPassed[3];
   for(int k = 0; k < 3; k++) tpPassed[k] = isBuy ? (tps[k] - t.bid < minD) : (t.ask - tps[k] < minD);

   Pos ps[];
   int all = Collect(ps), n = 0, outside = 0;
   Pos sel[];
   string outsideTxt = "";
   for(int i = 0; i < all; i++)
     {
      if(ps[i].buy != isBuy) continue;
      if(c.zoneLo > 0 && (ps[i].op < c.zoneLo - c.zoneTol || ps[i].op > c.zoneHi + c.zoneTol))
        { outside++; outsideTxt += " " + Px(ps[i].op); continue; }
      ArrayResize(sel, n + 1); sel[n] = ps[i]; n++;
     }
   if(n == 0)
     { txt = StringFormat("没有%s单%s。没有改动。", isBuy ? "买" : "卖", outside > 0 ? "在区间里" : ""); return(false); }
   double avgEntry = 0, totVol = 0;
   for(int i = 0; i < n; i++) { avgEntry += sel[i].op * sel[i].vol; totVol += sel[i].vol; }
   avgEntry /= totVol;
   if(MathAbs(avgEntry - sl) > c.maxSlDist)
     { txt = StringFormat("止损 %s 离均价 %s 有 $%.2f（上限 %.0f），请检查。没有改动。", Px(sl), Px(avgEntry), MathAbs(avgEntry - sl), c.maxSlDist); return(false); }
   SortWorstFirst(sel);
   int n1 = (int)MathRound(c.share1 * n);
   int n2 = (int)MathRound((c.share1 + c.share2) * n) - n1;
   if(n1 + n2 > n) n2 = n - n1;
   int tpIdx[];
   ArrayResize(tpIdx, n);
   int cnt[4] = {0, 0, 0, 0};
   double planRisk = 0, tpRoom = MathMax(minD, 0.30);
   fp = StringFormat("%s|%d|%s|%s|%s|%s", TimeToString(c.created), c.side, Px(sl), Px(tps[0]), Px(tps[1]), Px(tps[2]));
   for(int i = 0; i < n; i++)
     {
      int k = (i < n1) ? 0 : (i < n1 + n2 ? 1 : 2);
      while(k < 3 && (tpPassed[k] || (isBuy ? tps[k] < sel[i].op + tpRoom : tps[k] > sel[i].op - tpRoom)))
         k++;
      tpIdx[i] = k; cnt[k]++;
      planRisk += LossAt(isBuy, sel[i].vol, sel[i].op, sl);
      fp += StringFormat("|%I64u:%d", sel[i].tk, k);
     }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = bal > 0 ? planRisk / bal * 100.0 : 0;
   string overTxt = (c.maxRiskPct > 0 && pct > c.maxRiskPct) ? StringFormat("，超过你的 %.1f%% 上限", c.maxRiskPct) : "";
   if(!apply)
     {
      txt = StringFormat("套用 levels（%s）：%d 张，均价 %s\n止损 %s（离现价 %.2f）\nTP1 %s × %d，TP2 %s × %d，TP3 %s × %d，保留原止盈 × %d\n全部打到止损约 −$%.0f = 余额的 %.1f%%%s%s\n\n%d 秒内点确认。",
                         isBuy ? "买" : "卖", n, Px(avgEntry), Px(sl), gap,
                         Px(tps[0]), cnt[0], Px(tps[1]), cnt[1], Px(tps[2]), cnt[2], cnt[3], planRisk, pct, overTxt,
                         outside > 0 ? StringFormat("\n区间外的 %d 张不动：%s", outside, outsideTxt) : "", InpConfirmS);
      return(true);
     }
   if(fp != expectFp)
     {
      txt = "预览之后 levels.csv、持仓或止盈分配变了，没有改动。请重新按「套用 levels」看新的计划。";
      return(false);
     }
   int ok = 0, unchanged = 0, kept = 0, failed = 0;
   int applied[4] = {0, 0, 0, 0};
   double risk = 0;
   string failTxt = "";
   for(int i = 0; i < n; i++)
     {
      if(!PositionSelectByTicket(sel[i].tk)) { failed++; failTxt += " 有单已平;"; continue; }
      double cur = PositionGetDouble(POSITION_SL), curTp = PositionGetDouble(POSITION_TP);
      bool   lockIn = cur > 0 && (isBuy ? (cur > sl && cur >= sel[i].op) : (cur < sl && cur <= sel[i].op));
      double newSl = lockIn ? cur : sl;
      double tp = (tpIdx[i] < 3) ? tps[tpIdx[i]] : curTp;
      if(MathAbs(newSl - cur) < pt / 2 && MathAbs(tp - curTp) < pt / 2)
        { unchanged++; applied[tpIdx[i]]++; if(lockIn) kept++; risk += LossAt(isBuy, sel[i].vol, sel[i].op, newSl); continue; }
      if(trade.PositionModify(sel[i].tk, newSl, tp) || trade.ResultRetcode() == TRADE_RETCODE_NO_CHANGES)
        { ok++; applied[tpIdx[i]]++; if(lockIn) kept++; risk += LossAt(isBuy, sel[i].vol, sel[i].op, newSl); }
      else
        {
         failed++;
         failTxt += " " + LastErr() + ";";
         if(PositionSelectByTicket(sel[i].tk))
           {
            double s2 = PositionGetDouble(POSITION_SL);
            risk += (s2 > 0) ? LossAt(isBuy, sel[i].vol, sel[i].op, s2) : 0;
            if(s2 <= 0) failTxt += "（这张没有止损）";
           }
        }
     }
   if(ok + unchanged > 0)
     {
      string base = "AL_G_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_sym + (isBuy ? "_B_" : "_S_");
      GlobalVariableSet(base + "tp1", tps[0]);
      GlobalVariableSet(base + "lo", c.zoneLo > 0 ? c.zoneLo - c.zoneTol : 0);
      GlobalVariableSet(base + "hi", c.zoneLo > 0 ? c.zoneHi + c.zoneTol : 0);
      GlobalVariableSet(base + "t", (double)TimeCurrent());
      GlobalVariablesFlush();
     }
   pct = bal > 0 ? risk / bal * 100.0 : 0;
   overTxt = (c.maxRiskPct > 0 && pct > c.maxRiskPct) ? StringFormat("，超过你的 %.1f%% 上限", c.maxRiskPct) : "";
   txt = StringFormat("套用 levels（%s）：设好 %d，本来就对 %d，失败 %d，共 %d 张\n止损 %s（%d 张保留保本或更好的止损）\nTP1 × %d，TP2 × %d，TP3 × %d，原止盈 × %d\n全部打到止损约 −$%.0f = 余额的 %.1f%%%s",
                      isBuy ? "买" : "卖", ok, unchanged, failed, n, Px(sl), kept, applied[0], applied[1], applied[2], applied[3], risk, pct, overTxt);
   if(outside > 0) txt += StringFormat("\n区间外的 %d 张没动。", outside);
   if(failed > 0) txt += "\n注意：" + failTxt;
   PrintFormat("TradeBot levels %s: set %d, right %d, failed %d of %d, SL %s, risk $%.0f %s", isBuy ? "buy" : "sell", ok, unchanged, failed, n, Px(sl), risk, failTxt);
   return(failed == 0);
  }

//+------------------------------------------------------------------+
//| commands                                                         |
//+------------------------------------------------------------------+
bool IsAction(const string cmd)
  {
   return(cmd == "be" || cmd == "p25" || cmd == "p50" || cmd == "p75" || cmd == "derisk" || cmd == "closeall" || cmd == "levels");
  }

// fp: what the preview showed (levels: plan fingerprint; close all: position count)
string Run(const string cmd, const string fp)
  {
   if(cmd == "status")
      return(DoStatus());
   if(!TradingAllowed())
      return("Algo Trading 关着（或 TradeBot 没有交易权限），什么都没做。打开后再按。");
   trade.SetMarginMode();
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return("TradeBot 只用于对冲（hedging）账户，什么都没做。");
   string r = "";
   if(cmd == "be")            r = DoBE();
   else if(cmd == "p25")      r = DoClosePct(25);
   else if(cmd == "p50")      r = DoClosePct(50);
   else if(cmd == "p75")      r = DoClosePct(75);
   else if(cmd == "derisk")
     {
      string a = DoClosePct(InpDeriskPct);
      r = a + "\n" + DoBE();
     }
   else if(cmd == "closeall") r = DoCloseAll(fp == "" ? -1 : (int)StringToInteger(fp));
   else if(cmd == "levels")
     {
      string now;
      DoLevels(true, fp, r, now);
     }
   return(r + "\n\n" + DoStatus());
  }

void Execute(const long chat, const string cmd, const string fp)
  {
   Status("running " + cmd);
   string r = Run(cmd, fp);
   Status("last: " + cmd + " " + TimeToString(TimeLocal(), TIME_MINUTES));
   if(!TgSend(chat, r, "menu"))
     {
      g_unsent += (g_unsent == "" ? "" : "\n\n") + r;
      g_unsentTries = 0;
     }
  }

// Shows the plan and the confirm buttons, and sets the pending command.
void AskConfirm(const long chat, const string cmd)
  {
   string t, fp = "";
   g_pending = "";
   if(cmd == "closeall")
     {
      Pos ps[];
      int n = Collect(ps);
      if(n == 0)
        { TgSend(chat, "全平：没有持仓。", "menu"); return; }
      double lots = 0, pnl = 0;
      for(int i = 0; i < n; i++) { lots += ps[i].vol; pnl += ps[i].pnl; }
      int po = PendingOrders();
      t = StringFormat("全平 %s（账户 %s）：%d 张，%.2f 手，现在浮盈亏约 $%.2f。%s\n%d 秒内点确认。", g_sym, Acct(), n, lots, pnl,
                       po > 0 ? StringFormat("\n另有挂单 %d 个，不会被取消。", po) : "", InpConfirmS);
      fp = IntegerToString(n);
     }
   else if(cmd == "derisk")
      t = StringFormat("减仓：每个方向平掉 %.0f%% 的手数（最差的进场先平），剩下的移到保本（还没浮盈的跳过）。\n%d 秒内点确认。\n\n%s",
                       InpDeriskPct, InpConfirmS, DoStatus());
   else if(!DoLevels(false, "", t, fp))
     { TgSend(chat, t, "menu"); return; }
   if(TgSend(chat, t, "confirm:" + cmd))
     {
      g_pending = cmd;
      g_pendingT = TimeLocal();
      g_pendingFp = fp;
     }
  }

// raw: typed text or button data ("p50:<keyboard id>"); stale: read after a gap in the connection
void Handle(const long chat, const string raw, const string cbId, const bool stale)
  {
   string cmd = raw;
   StringTrimLeft(cmd); StringTrimRight(cmd); StringToLower(cmd);
   if(StringGetCharacter(cmd, 0) == '/') cmd = StringSubstr(cmd, 1);
   int at = StringFind(cmd, "@");
   if(at > 0) cmd = StringSubstr(cmd, 0, at);
   long seqIn = -1;
   int colon = StringFind(cmd, ":");
   if(colon > 0)
     {
      seqIn = StringToInteger(StringSubstr(cmd, colon + 1));
      cmd = StringSubstr(cmd, 0, colon);
     }
   bool isOk = StringFind(cmd, "ok_") == 0;
   bool action = IsAction(cmd) || isOk;
   PrintFormat("TradeBot: command '%s'%s", cmd, cbId != "" ? " (button)" : "");

   if(cbId != "")
     {
      if((action || cmd == "cancel") && seqIn != g_seq)
        {
         // an older message, or a second tap on the same one: a short note only; the newest buttons
         // and a waiting confirm stay as they are
         TgAnswer(cbId, "旧按钮，没有执行");
         if(!g_kbOk)
            TgSend(chat, "上一条带按钮的消息没送到。用这条消息上的按钮。", "menu");
         return;
        }
      string why = "";
      if(action && stale)
         why = "和 Telegram 的连接断过，这个按钮可能是很久以前按的，没有执行。请重新按。";
      int code = TgAnswer(cbId, why != "" ? "没有执行" : (action ? "收到" : ""));
      if(why == "" && action && code == 400)
         why = "Telegram 说这个按钮按得太久了，没有执行。请重新按。";
      if(why != "")
        {
         g_pending = "";
         TgSend(chat, why, "menu");
         return;
        }
     }
   else if(isOk)
      return;                                          // a confirm must be a button tap

   if(cmd == "cancel")
     {
      bool was = (g_pending != "");
      g_pending = "";
      TgSend(chat, was ? "已取消，什么都没做。" : "没有等待确认的操作。", "menu");
      return;
     }
   if(isOk)
     {
      string what = StringSubstr(cmd, 3), fp = g_pendingFp;
      bool fresh = (g_pending != "" && g_pending == what && TimeLocal() - g_pendingT <= InpConfirmS);
      g_pending = "";
      if(!fresh)
        {
         TgSend(chat, "确认已过期，什么都没做。请重新按。", "menu");
         return;
        }
      Execute(chat, what, fp);
      return;
     }
   if(cmd == "derisk" || cmd == "closeall" || cmd == "levels")
     {
      AskConfirm(chat, cmd);
      return;
     }
   if(cmd == "be" || cmd == "p25" || cmd == "p50" || cmd == "p75" || cmd == "status")
     {
      Execute(chat, cmd, "");
      return;
     }
   TgSend(chat, "TradeBot（" + g_sym + "，账户 " + Acct() + "）：选一个操作。", "menu");
  }

void Poll()
  {
   string resp;
   bool gap = g_primed && g_lastOk > 0 && GetTickCount() - g_lastOk > (uint)InpMaxCmdAgeS * 1000;
   // first call: offset -1 returns only the newest update and drops everything older.
   // later calls: long polling, so a second reader of the same bot always gets 409.
   string method = g_primed ? StringFormat("getUpdates?offset=%I64d&timeout=%d", g_offset, LONGPOLL)
                            : "getUpdates?offset=-1&timeout=0";
   method += "&allowed_updates=%5B%22message%22,%22callback_query%22%5D";
   int code = TgCall(method, "", resp, g_primed ? (LONGPOLL + 5) * 1000 : 5000);
   if(IsStopped())
      return;                                        // the EA is being removed: handle nothing
   g_pollKb = false;
   if(code == 409)
     {
      if(!g_conflict && InpChatId != 0)
        {
         g_conflict = true;
         Alert("TradeBot: another program is reading this Telegram bot - TradeBot gets no commands. Run only one TradeBot per bot token.");
         TgSend(InpChatId, "警告：另一个程序（第二个 TradeBot 或别的电脑）也在读这个机器人，TradeBot 现在收不到命令。一个机器人只能给一个 TradeBot 用。", "");
        }
      return;
     }
   if(code != 200)
      return;
   g_lastOk = GetTickCount();
   g_conflict = false;
   int starts[];
   int ns = 0, pos = 0;
   while(true)
     {
      int k = StringFind(resp, "{\"update_id\":", pos);
      if(k < 0) break;
      ArrayResize(starts, ns + 1); starts[ns++] = k;
      pos = k + 12;
     }
   for(int u = 0; u < ns; u++)
     {
      int a = starts[u];
      int b = (u + 1 < ns) ? starts[u + 1] : StringLen(resp);
      string up = StringSubstr(resp, a, b - a);
      long uid = StringToInteger(JVal(up, "update_id", 0));
      if(!g_primed)
        {
         g_offset = uid + 1;                         // sent before the EA started: skipped
         continue;
        }
      if(uid >= g_offset) g_offset = uid + 1;
      long chat = 0, from = 0;
      string text = "", cbId = "";
      int cq = TopKey(up, "callback_query", 0);
      if(cq >= 0)
        {
         int ms = TopKey(up, "message", cq);
         if(ms < 0) continue;                        // a button with no message: not ours
         cbId = JVal(up, "id", TopKey(up, "id", cq));
         from = ObjId(up, "from", cq);
         chat = ObjId(up, "chat", ms);
         text = JVal(up, "data", TopKey(up, "data", cq));
        }
      else
        {
         int ms = TopKey(up, "message", 0);
         if(ms < 0) continue;
         if(TopKey(up, "forward_origin", ms) >= 0 || TopKey(up, "forward_date", ms) >= 0 ||
            TopKey(up, "via_bot", ms) >= 0 || TopKey(up, "is_automatic_forward", ms) >= 0)
           {
            Print("TradeBot: ignored a forwarded message");
            continue;
           }
         from = ObjId(up, "from", ms);
         chat = ObjId(up, "chat", ms);
         long date = StringToInteger(JVal(up, "date", TopKey(up, "date", ms)));
         text = JVal(up, "text", TopKey(up, "text", ms));
         if(date > 0 && (long)TimeGMT() - date > InpMaxCmdAgeS)
           {
            PrintFormat("TradeBot: ignored an old message (%d s)", (int)((long)TimeGMT() - date));
            continue;
           }
        }
      if(chat == 0)
         continue;
      if(InpChatId == 0)
        {
         TgSend(chat, StringFormat("你的 chat id 是 %I64d。把它填进 TradeBot 的 InpChatId，再重新挂上 EA。在那之前这个机器人不执行任何操作。", from), "");
         continue;
        }
      if(from != InpChatId || chat != InpChatId)
        {
         PrintFormat("TradeBot: ignored a command from chat %I64d (user %I64d)", chat, from);
         if(cbId != "") TgAnswer(cbId, "没有权限");
         continue;
        }
      Handle(chat, text, cbId, gap);
     }
   if(!g_primed)
     {
      g_primed = true;
      if(InpChatId != 0)
         TgSend(InpChatId, "TradeBot 已启动：" + g_sym + "，账户 " + Acct() + "。", "menu");
     }
   if(g_unsent != "" && InpChatId != 0)
     {
      // no new buttons when this poll already sent some or a confirm is waiting (they would go stale)
      string kb = (g_pollKb || g_pending != "") ? "" : "menu";
      g_unsentTries++;
      if(TgSend(InpChatId, "之前没送到的结果：\n" + g_unsent, kb) || g_unsentTries >= 3)
        {
         g_unsent = "";
         g_unsentTries = 0;
        }
     }
   if(StringFind(g_status, "ready") < 0 && StringFind(g_status, "last:") < 0)
      Status(InpChatId == 0 ? "pairing: send /start to the bot to get your chat id" : "ready - send /menu to the bot");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_sym = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_sym, true))
     { Print("TradeBot: unknown symbol ", g_sym); return(INIT_PARAMETERS_INCORRECT); }
   if(InpDeriskPct <= 0 || InpDeriskPct >= 100 || InpPollMs < 300 || InpConfirmS < 5 || InpMaxCmdAgeS < 30 || InpMaxCmdAgeS > 3600)
     { Print("TradeBot: check the inputs (derisk 1-99 %, poll >= 300 ms, confirm >= 5 s, max age 30-3600 s)"); return(INIT_PARAMETERS_INCORRECT); }
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(500);          // $5 on gold: closing matters more than the exact price
   trade.SetMarginMode();
   g_primed = false;
   g_offset = 0;
   g_conflict = false;
   g_pending = "";
   g_status = "";
   g_lastOk = 0;
   g_unsent = "";
   g_unsentTries = 0;
   g_kbOk = true;
   // a random start, so buttons of an earlier run (or of another TradeBot) never match
   MathSrand(GetTickCount() ^ (uint)TimeLocal() ^ (uint)ChartID());
   g_seq = 100000000 + (int)((((uint)MathRand() << 15) | (uint)MathRand()) % 900000000);
   string why = "";
   g_token = CleanToken(InpBotToken, why);
   if(g_token == "")
     {
      Status(why);
      return(INIT_SUCCEEDED);
     }
   // the newest keyboard of an earlier run: its buttons are removed when the first menu is sent
   g_kbVar = "TradeBot_kb_" + TokenHash();
   g_kbMsg = GlobalVariableCheck(g_kbVar) ? (long)GlobalVariableGet(g_kbVar) : 0;
   if(!TakeLock())
     {
      Alert("TradeBot: this bot token is already used by TradeBot on another chart. One bot per TradeBot.");
      return(INIT_FAILED);
     }
   PrintFormat("TradeBot settings: symbol %s | account %s | chat id %s | derisk %.0f%% | pause %d ms | confirm %d s | max age %d s",
               g_sym, Acct(), InpChatId == 0 ? "not set (pairing)" : "set", InpDeriskPct, InpPollMs, InpConfirmS, InpMaxCmdAgeS);
   Status("connecting to Telegram...");
   EventSetMillisecondTimer(InpPollMs);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   FreeLock();
   Comment("");
  }

void OnTimer()
  {
   if(g_token == "")
      return;
   if(g_pending != "" && TimeLocal() - g_pendingT > InpConfirmS)
      g_pending = "";
   Poll();
  }
//+------------------------------------------------------------------+
