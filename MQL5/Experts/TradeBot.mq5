//+------------------------------------------------------------------+
//| TradeBot.mq5  (v1.60)                                            |
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
//|  - levels: SL / TP1-3 from your orders (each group's first      |
//|    entry) or a forwarded signal; shows the plan first; the       |
//|    confirm applies only if the plan (each position's SL, TP and  |
//|    lots) is still the same                                       |
//|  - close all / derisk / levels need a second tap (confirm)       |
//|  - only the buttons of the newest bot message act; older buttons |
//|    and a second tap on the same message do nothing               |
//|  - a signal pasted or forwarded to the bot ("Gold sell zone      |
//|    4154-4159 SL 4164 TP1 4150 TP2 4145 TP3 4140") is written to  |
//|    levels.csv; a gameplan post is written to gameplan.csv; a     |
//|    forwarded message is only ever read as a signal or gameplan,  |
//|    never as a command                                            |
//|  - InpAutoLevels = true: the same levels are set without a tap  |
//|    a few seconds after each entry (see "automatic levels")      |
//|  - skipped: commands sent before the EA started, typed commands  |
//|    older than InpMaxCmdAgeS, button taps read after a gap in the |
//|    connection longer than InpMaxCmdAgeS or that Telegram says    |
//|    are too old, forwarded signals older than SIG_MAX_POST_MIN    |
//+------------------------------------------------------------------+
#property version     "1.60"
#property description "Telegram buttons: breakeven, close 25/50/75%, derisk, close all, levels.csv, status"

#include <Trade\Trade.mqh>

input string InpBotToken   = "";    // Telegram bot token from @BotFather (one bot per TradeBot)
input long   InpChatId     = 0;     // Your Telegram chat id (0 = pairing: the bot only tells you your id)
input string InpSymbol     = "";    // Symbol to manage ("" = this chart's symbol)
input double InpDeriskPct  = 50;    // Derisk: % of the volume to close (worst entries first), then breakeven
input int    InpPollMs     = 500;   // Pause between two requests to Telegram (ms)
input int    InpMaxCmdAgeS = 60;    // Ignore typed commands older than this; also the longest connection gap (seconds)
input int    InpConfirmS   = 30;    // Close all / derisk / levels: confirm within this many seconds
input bool   InpAutoLevels = false; // true = set SL / TP automatically after each entry; false = only when you tap 套用 levels
input double InpAutoTol    = 3.0;   // Entries this far outside a zone still count ($)
input double InpSubWidth   = 5.0;   // GP zone: his signal zone width, from the edge nearest the first entry ($)
input double InpSubSL      = 5.0;   // GP zone: SL beyond that small zone ($)
input double InpTP1        = 4.0;   // GP zone: TP1 from the small zone's near edge ($)
input double InpTP2        = 9.0;   // GP zone: TP2 from the small zone's near edge ($)
input double InpTP3        = 14.0;  // GP zone: TP3 from the small zone's near edge ($)
input int    InpAutoSigMin = 120;   // A forwarded or pasted signal is used for this many minutes
input int    InpGpMaxDays  = 4;     // Use gameplan.csv only while it is at most this many days old
input double InpAutoWarnPct = 20;   // Warn when the loss at all stops is above this % of balance
input bool   InpOrderLevels = true;  // Other positions: levels from the group's first entry (his 5-wide zone, SL $10, TP +4/+9/+14)
input bool   InpUseGp       = false; // Also use gameplan.csv zones (GP posts forwarded to the bot)
input bool   InpWithNewsGuard = false; // NewsGuard runs on this account: let it set its first stop and breakeven first

#define TG_URL  "https://api.telegram.org/bot"
#define MAGIC   261009
#define LONGPOLL 2                  // seconds Telegram may hold a getUpdates request open (also the longest wait for automatic levels)

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
bool     g_lvNoPos = false;        // the last DoLevels refused only because no position of that side is open
string   g_autoInfo = "";          // which signal / gameplan the automatic levels use (for the status)
bool     g_force = false;          // 套用 levels: set every position's SL / TP now (as Alt+L does), not only new ones
bool     g_dry = false;            // with g_force: only describe what would be set (the preview)
string   g_forceOut = "";          // text of a forced / dry run
string   g_plan = "";              // forced run: each position's planned SL / TP / lots (a confirm applies only the plan it showed)
double   g_alScore[2], g_alTp1[2], g_alLo[2], g_alHi[2];   // forced run: per side, the group NewsGuard's TP1 breakeven follows
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
            else if(e == 't') out += "\t";
            else if(e == 'r') out += "\r";
            else if(e == 'b' || e == 'f') out += " ";
            else if(e == 'u' && i + 5 < n)
              {
               int u = 0;
               for(int q = 2; q < 6; q++)              // 4 hex digits (no reliance on StringToInteger("0x.."))
                 {
                  ushort h = StringGetCharacter(js, i + q);
                  int d = (h >= '0' && h <= '9') ? h - '0' : (h >= 'a' && h <= 'f') ? h - 'a' + 10 : (h >= 'A' && h <= 'F') ? h - 'A' + 10 : -1;
                  if(d < 0) { u = -1; break; }
                  u = u * 16 + d;
                 }
               if(u >= 0)
                 {
                  out += ShortToString((ushort)u);
                  i += 4;
                 }
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
bool TgSend(const long chat, const string text, const string kb, const int timeoutMs = 10000)
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
   int code = TgCall("sendMessage", body, resp, timeoutMs);
   if(code == 429)
     {
      int wait = (int)StringToInteger(JVal(resp, "retry_after", 0));
      if(wait >= 0 && wait <= 5)
        {
         Sleep(wait * 1000 + 200);
         code = TgCall("sendMessage", body, resp, timeoutMs);
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
   long   tm;          // open time (msc)
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
      ps[n].tm  = PositionGetInteger(POSITION_TIME_MSC);
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
   if(InpAutoLevels)
      s += "\n自动 levels：" + (g_autoInfo == "" ? "没有可用的喊单或 GP（把 GP 帖或喊单转发给我）" : g_autoInfo);
   else if(InpOrderLevels)
      s += StringFormat("\nlevels：点「套用 levels」时按每组第一笔算（SL 离第一笔 $%.0f，TP 离第一笔 $%.0f / $%.0f / $%.0f）",
                        InpSubWidth + InpSubSL, InpTP1, InpTP2, InpTP3);
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
     {
      err = FileIsExist("levels.csv") ? StringFormat("打不开 MQL5/Files/levels.csv（错误 %d）", GetLastError())
                                        : "这台电脑上还没有 levels.csv：把喊单转发给我就会写好（开了自动 levels，进场后会自动设，不用按这个按钮）";
      return(false);
     }
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
   g_lvNoPos = false;
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
     { g_lvNoPos = true; txt = StringFormat("没有%s单%s。没有改动。", isBuy ? "买" : "卖", outside > 0 ? "在区间里" : ""); return(false); }
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
   else if(cmd == "levels" && StringFind(fp, "order|") == 0)
     {
      string pv = LevelsNow(true);                         // the plan now, made the same way as the preview
      if(g_plan == "")
         r = "没有改动：" + pv;
      else if("order|" + g_plan != fp)
         r = "预览之后持仓、价格或 levels 变了，没有改动。请重新按「套用 levels」看新的计划。";
      else
         r = LevelsNow(false);
     }
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
   else if(InpOrderLevels)
     {
      string pv = LevelsNow(true);
      if(g_plan == "")
        { TgSend(chat, "套用 levels：" + pv, "menu"); return; }
      t = StringFormat("套用 levels（按你每组的第一笔算：SL 离第一笔 $%.0f，TP 离第一笔 $%.0f / $%.0f / $%.0f；转发过的喊单按喊单的数字）会设成：\n\n",
                       InpSubWidth + InpSubSL, InpTP1, InpTP2, InpTP3)
          + pv + StringFormat("\n\n已经保本的止损不动。%d 秒内点确认。", InpConfirmS);
      fp = "order|" + g_plan;
     }
   else if(!DoLevels(false, "", t, fp))
     { TgSend(chat, t, "menu"); return; }
   if(TgSend(chat, t, "confirm:" + cmd))
     {
      g_pending = cmd;
      g_pendingT = TimeLocal();
      g_pendingFp = fp;
     }
  }

//+------------------------------------------------------------------+
//| signals pasted or forwarded in Telegram -> levels.csv            |
//| Format: "Gold sell zone 4154-4159 SL 4164 TP1 4150 TP2 4145 TP3  |
//| 4140" (direction word optional: the SL side decides). Typos are  |
//| repaired against the live price: one common shift of 100 / 200 / |
//| 1000 for the numbers far from the price, else a one-edit repair  |
//| (one digit changed, swapped, added or removed) that lands where  |
//| he usually puts that level. Every repair is shown to the user.   |
//| A signal that is valid as written is not repaired. When all six  |
//| numbers are far, only a forward at most 10 min old is shifted.   |
//| Tested on 163 of his past signals: 134 read as written; 23       |
//| repaired and 6 refused (forward <= 10 min old) or 17 repaired    |
//| and 12 refused (pasted or older); no GP post read as a signal.   |
//+------------------------------------------------------------------+
#define SIG_FAR             60.0    // a number further than this from the price is a typo
#define LV_MAX_AGE_MIN      30      // levels.csv older than this is refused (max_age_min); counted from writing
#define SIG_MAX_POST_MIN    120     // a forwarded signal posted longer ago than this is not written
#define SIG_WHOLE_SHIFT_MIN 10      // all six numbers may be repaired by one shift only for a forward this fresh

string Sub(const string s, const int start, const int len)  { return((len <= 0 || start >= StringLen(s)) ? "" : StringSubstr(s, start, len)); }
string Tail(const string s, const int start)                { return(start >= StringLen(s) ? "" : StringSubstr(s, start)); }

string g_sigName[6] = {"区间", "区间", "SL", "TP1", "TP2", "TP3"};

bool IsDig(const ushort c) { return(c >= '0' && c <= '9'); }
bool IsLet(const ushort c) { return((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')); }
string Num(const double x) { return(StringFormat("%.7g", x)); }

// number at i (digits with an optional .digits part): index after it, or -1
int ReadNum(const string s, const int i, double &v, int &intDigits)
  {
   int n = StringLen(s), j = i;
   while(j < n && IsDig(StringGetCharacter(s, j)))
      j++;
   if(j == i)
      return(-1);
   intDigits = j - i;
   if(j + 1 < n && StringGetCharacter(s, j) == '.' && IsDig(StringGetCharacter(s, j + 1)))
     {
      j++;
      while(j < n && IsDig(StringGetCharacter(s, j)))
         j++;
     }
   v = StringToDouble(StringSubstr(s, i, j - i));
   return(j);
  }

int SkipSep(const string s, int i)
  {
   int n = StringLen(s);
   while(i < n)
     {
      ushort c = StringGetCharacter(s, i);
      if(c != ' ' && c != ':' && c != '@' && c != '=' && c != '\n' && c != '\r' && c != '\t')
         break;
      i++;
     }
   return(i);
  }

bool PipsAfter(const string s, int i)
  {
   while(i < StringLen(s) && StringGetCharacter(s, i) == ' ')
      i++;
   return(StringSubstr(s, i, 3) == "pip");
  }

// position of w at or after 'from', not glued to other letters; -1 if none
int FindWord(const string s, const string w, const int from)
  {
   int n = StringLen(s), L = StringLen(w);
   for(int k = StringFind(s, w, from); k >= 0; k = StringFind(s, w, k + 1))
     {
      bool left  = (k == 0) || !IsLet(StringGetCharacter(s, k - 1));
      bool right = (k + L >= n) || !IsLet(StringGetCharacter(s, k + L));
      if(left && right)
         return(k);
     }
   return(-1);
  }

void AddStr(string &a[], int &n, const string s)
  {
   ArrayResize(a, n + 1);
   a[n++] = s;
  }

// numbers one edit away from x: one digit changed, two neighbours swapped, one digit added or removed
int Edits(const double x, double &out[])
  {
   string s = StringFormat("%.10g", x);
   int dot = StringFind(s, ".");
   string ip = (dot < 0) ? s : StringSubstr(s, 0, dot);
   string fp = (dot < 0) ? "" : StringSubstr(s, dot);
   string c[];
   int n = 0, L = StringLen(ip);
   for(int i = 0; i < L; i++)
     {
      for(ushort d = '0'; d <= '9'; d++)
         AddStr(c, n, Sub(ip, 0, i) + ShortToString(d) + Tail(ip, i + 1));
      if(i + 1 < L)
         AddStr(c, n, Sub(ip, 0, i) + Sub(ip, i + 1, 1) + Sub(ip, i, 1) + Tail(ip, i + 2));
      AddStr(c, n, Sub(ip, 0, i) + Tail(ip, i + 1));
     }
   for(int i = 0; i <= L; i++)
      for(ushort d = '0'; d <= '9'; d++)
         AddStr(c, n, Sub(ip, 0, i) + ShortToString(d) + Tail(ip, i));
   ArrayResize(out, 0);
   int m = 0;
   for(int k = 0; k < n; k++)
     {
      if(c[k] == "" || StringGetCharacter(c[k], 0) == '0')
         continue;
      double y = StringToDouble(c[k] + fp);
      if(MathAbs(y - x) < 1e-9)
         continue;
      bool dup = false;
      for(int q = 0; q < m && !dup; q++)
         dup = MathAbs(out[q] - y) < 1e-9;
      if(!dup)
        {
         ArrayResize(out, m + 1);
         out[m++] = y;
        }
     }
   return(m);
  }

// where he usually puts a level (k: 2 SL, 3-5 TP1-TP3), as distance from the zone; used only for repairs
bool InWin(const int k, const double v, const int side, const double lo, const double hi)
  {
   double w0, w1;
   if(k == 2)      { w0 = 2;  w1 = 10; }
   else if(k == 3) { w0 = 2;  w1 = 7;  }
   else if(k == 4) { w0 = 6;  w1 = 12; }
   else if(k == 5) { w0 = 10; w1 = 20; }
   else return(true);
   double d = (k == 2) ? (side > 0 ? lo - v : v - hi) : (side > 0 ? v - hi : lo - v);
   return(d >= w0 - 1e-9 && d <= w1 + 1e-9);
  }

// "" when v[] (zone a, zone b, SL, TP1-TP3) is a valid signal; side is set once the SL side is known.
// strict[k]: v[k] must also sit where he usually puts it.
string SigCheck(const double &v[], const int word, const bool &strict[], int &side)
  {
   double lo = MathMin(v[0], v[1]), hi = MathMax(v[0], v[1]), sl = v[2];
   side = 0;
   if(hi - lo <= 0 || hi - lo > 15)
      return(StringFormat("区间 %s-%s 宽 %s（最多 15）", Num(v[0]), Num(v[1]), Num(hi - lo)));
   int geo = (sl < lo) ? 1 : (sl > hi ? -1 : 0);
   if(geo == 0)
      return("SL " + Num(sl) + " 在区间里面");
   if(word != 0 && word != geo)
      return(StringFormat("写的是%s，但 SL %s 在%s单那一边", word > 0 ? "买" : "卖", Num(sl), geo > 0 ? "买" : "卖"));
   side = geo;
   if((side > 0 ? lo - sl : sl - hi) > 20)
      return("SL " + Num(sl) + " 离区间超过 20");
   for(int i = 0; i < 3; i++)
     {
      double x = v[3 + i];
      bool ok = (side > 0) ? (x > hi - 5 && x < hi + 40) : (x > lo - 40 && x < lo + 5);
      if(!ok)
         return(StringFormat("TP%d %s 不在%s单的方向上", i + 1, Num(x), side > 0 ? "买" : "卖"));
     }
   if(!(side > 0 ? (v[3] < v[4] && v[4] < v[5]) : (v[3] > v[4] && v[4] > v[5])))
      return("TP1、TP2、TP3 的顺序不对");
   for(int k = 2; k < 6; k++)
      if(strict[k] && !InWin(k, v[k], side, lo, hi))
         return(g_sigName[k] + " " + Num(v[k]) + " 不在他平常的位置");
   return("");
  }

// 0 = not a signal, 1 = only a direction, 2 = refused (why), 3 = ok (v[]: zone a, zone b, SL, TP1-TP3)
// allowWhole: all six numbers far from the price may be repaired by one common shift (only for a fresh forward;
// otherwise the signal may simply be old, and the would-be repair is only suggested).
int ParseSignal(const string raw, const double price, const bool allowWhole, double &v[], int &side, string &fixes, string &why)
  {
   // one kind of space, dash, digit and colon: tabs, line breaks, no-break and wide spaces, dashes, full-width forms
   string t = "";
   for(int i = 0; i < StringLen(raw); i++)
     {
      ushort c = StringGetCharacter(raw, i);
      if(c == '\t' || c == '\r' || c == '\n' || c == 0xA0 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x3000)
         c = ' ';
      else if(c >= 0xFF10 && c <= 0xFF19)
         c = (ushort)('0' + (c - 0xFF10));
      else if(c == 0xFF1A)
         c = ':';
      else if(c == 0xFF0E)
         c = '.';
      else if(c == 0xFF0D || c == 0x2010 || c == 0x2011 || c == 0x2012 || c == 0x2013 || c == 0x2014 || c == 0x2212)
         c = '-';
      t += ShortToString(c);
     }
   StringToLower(t);
   StringReplace(t, ",", " ");
   int n = StringLen(t);
   fixes = "";
   why = "";
   side = 0;
   ArrayResize(v, 6);
   // SL: the first "sl" / "stop loss" followed by a price (not by "pips")
   int slAt = -1;
   double sl = 0;
   string kw[3] = {"sl", "stop loss", "stoploss"};
   for(int q = 0; q < 3; q++)
      for(int k = FindWord(t, kw[q], 0); k >= 0; k = FindWord(t, kw[q], k + 1))
        {
         double x;
         int dg;
         int e = ReadNum(t, SkipSep(t, k + StringLen(kw[q])), x, dg);
         if(e < 0 || PipsAfter(t, e))
            continue;
         if(slAt < 0 || k < slAt) { slAt = k; sl = x; }
         break;
        }
   // TPs: "tp1 4150", "tp 4150", in the order written
   double tpv[];
   int tpl[];
   int nt = 0;
   for(int k = FindWord(t, "tp", 0); k >= 0; k = FindWord(t, "tp", k + 1))
     {
      int i = k + 2;
      while(i < n && StringGetCharacter(t, i) == ' ')
         i++;
      int label = 0;
      if(i < n)
        {
         ushort c = StringGetCharacter(t, i);
         ushort c2 = (i + 1 < n) ? StringGetCharacter(t, i + 1) : ' ';
         int run = 0;
         while(i + run < n && IsDig(StringGetCharacter(t, i + run)))
            run++;
         // "tp1 4150" (label, then the price) or "tp14150" (label glued to a 4-digit price)
         if(c >= '1' && c <= '3' && ((!IsDig(c2) && c2 != '.') || run >= 5))
           { label = c - '0'; i++; }
        }
      double x;
      int dg;
      int e = ReadNum(t, SkipSep(t, i), x, dg);
      if(e < 0 || PipsAfter(t, e))
         continue;
      ArrayResize(tpv, nt + 1); ArrayResize(tpl, nt + 1);
      tpv[nt] = x; tpl[nt] = label; nt++;
     }
   // zone: the first "a-b" of two prices (3-5 digits) before the SL
   bool hasZone = false;
   double za = 0, zb = 0;
   int zEnd = (slAt >= 0) ? slAt : n;
   for(int i = 0; i < zEnd && !hasZone; i++)
     {
      ushort c = StringGetCharacter(t, i);
      if(!IsDig(c) || (i > 0 && (IsDig(StringGetCharacter(t, i - 1)) || StringGetCharacter(t, i - 1) == '.')))
         continue;
      double x, y;
      int dg, dg2;
      int e = ReadNum(t, i, x, dg);
      if(e < 0 || dg < 3 || dg > 5)
         continue;
      int j = e;
      while(j < n && StringGetCharacter(t, j) == ' ') j++;
      if(j >= n || StringGetCharacter(t, j) != '-')
         continue;
      j++;
      while(j < n && StringGetCharacter(t, j) == ' ') j++;
      int e2 = ReadNum(t, j, y, dg2);
      if(e2 < 0 || dg2 < 3 || dg2 > 5)
         continue;
      za = x; zb = y; hasZone = true;
     }
   int wb = FindWord(t, "buy", 0), ws = FindWord(t, "sell", 0);
   int word = (wb >= 0 && (ws < 0 || wb < ws)) ? 1 : (ws >= 0 ? -1 : 0);
   if(!hasZone || (slAt < 0 && nt < 3))
     {
      if(nt == 0 && slAt < 0 && word != 0 && (FindWord(t, "now", 0) >= 0 || FindWord(t, "zone", 0) >= 0))
         return(1);
      return(0);
     }
   if(slAt < 0) { why = "没有 SL"; return(2); }
   if(nt < 3)   { why = "要有 TP1、TP2、TP3"; return(2); }
   v[0] = za; v[1] = zb; v[2] = sl;
   bool byLabel = (tpl[0] + tpl[1] + tpl[2] == 6 && tpl[0] * tpl[1] * tpl[2] == 6);   // labels 1, 2, 3 in any order
   for(int i = 0; i < 3; i++)
      v[byLabel ? 2 + tpl[i] : 3 + i] = tpv[i];

   if(price <= 0)
     {
      why = "没有报价，没法核对喊单";
      return(2);
     }
   // repairs: numbers far from the price
   bool far[6], none[6];
   bool anyFar = false;
   int nFar = 0;
   for(int k = 0; k < 6; k++)
     {
      far[k] = MathAbs(v[k] - price) > SIG_FAR;
      none[k] = false;
      anyFar = anyFar || far[k];
      if(far[k]) nFar++;
     }
   if(anyFar && nFar < 6)
     {
      // valid as written (the price has moved, e.g. a re-forward): take the numbers as he wrote them
      int sd0;
      if(SigCheck(v, word, none, sd0) == "")
         anyFar = false;
     }
   if(anyFar)
     {
      double shifts[6] = {100, -100, 200, -200, 1000, -1000};
      bool done = false;
      for(int q = 0; q < 6 && !done; q++)
        {
         double tr[6];
         bool strict[6];
         bool near = true;
         for(int k = 0; k < 6; k++)
           {
            tr[k] = far[k] ? v[k] + shifts[q] : v[k];
            strict[k] = far[k] && k >= 2;
            near = near && MathAbs(tr[k] - price) <= SIG_FAR;
           }
         int sd;
         if(near && SigCheck(tr, word, strict, sd) == "")
           {
            if(nFar == 6 && !allowWhole)
              {
               why = StringFormat("所有数字都离现价 %s 超过 $%.0f（喊单可能太旧）。如果是他把数字打错，可能是下面这条，核对后复制发给我：\n%s%s-%s SL %s TP1 %s TP2 %s TP3 %s",
                                  Px(price), SIG_FAR, word > 0 ? "buy " : (word < 0 ? "sell " : ""), Num(MathMin(tr[0], tr[1])), Num(MathMax(tr[0], tr[1])),
                                  Num(tr[2]), Num(tr[3]), Num(tr[4]), Num(tr[5]));
               return(2);
              }
            for(int k = 0; k < 6; k++)
               if(far[k])
                 {
                  fixes += g_sigName[k] + " " + Num(v[k]) + " → " + Num(tr[k]) + "；";
                  v[k] = tr[k];
                 }
            if(nFar == 6)
               fixes += "（所有数字都改了，请特别核对）；";
            done = true;
           }
        }
      if(!done && nFar == 6)
        {
         why = StringFormat("所有数字都离现价 %s 超过 $%.0f，喊单可能太旧或整条打错", Px(price), SIG_FAR);
         return(2);
        }
      for(int k = 0; k < 6 && !done; k++)                // zone ends first, then SL, then TPs
        {
         if(!far[k])
            continue;
         double c[], keep[];
         int m = Edits(v[k], c), nk = 0;
         double lo = MathMin(v[0], v[1]), hi = MathMax(v[0], v[1]);
         int sd = (word != 0) ? word : (v[2] < lo ? 1 : (v[2] > hi ? -1 : 0));
         for(int q = 0; q < m; q++)
           {
            double y = c[q];
            if(MathAbs(y - price) > SIG_FAR)
               continue;
            if(k <= 1)
              {
               double other = v[1 - k];
               if(MathAbs(other - price) <= SIG_FAR && !(MathAbs(y - other) > 0 && MathAbs(y - other) <= 15))
                  continue;
              }
            else if(sd == 0 ? !(InWin(k, y, 1, lo, hi) || InWin(k, y, -1, lo, hi)) : !InWin(k, y, sd, lo, hi))
               continue;
            ArrayResize(keep, nk + 1);
            keep[nk++] = y;
           }
         if(nk != 1)
           {
            why = StringFormat("%s %s 看起来打错了（离现价 %s 超过 $%.0f），没法自动改正", g_sigName[k], Num(v[k]), Px(price), SIG_FAR);
            return(2);
           }
         fixes += g_sigName[k] + " " + Num(v[k]) + " → " + Num(keep[0]) + "；";
         v[k] = keep[0];
        }
     }
   why = SigCheck(v, word, none, side);
   if(StringFind(why, "TP") == 0 && side != 0)
     {
      // one TP on the wrong side or out of order although near the price: one-edit repair in its usual place
      double lo = MathMin(v[0], v[1]), hi = MathMax(v[0], v[1]);
      int bad = -1, nb = 0;
      for(int k = 3; k < 6; k++)
         if(!InWin(k, v[k], side, lo, hi)) { bad = k; nb++; }
      if(nb == 1)
        {
         double c[];
         int m = Edits(v[bad], c), nk = 0;
         double y = 0;
         for(int q = 0; q < m; q++)
            if(InWin(bad, c[q], side, lo, hi)) { y = c[q]; nk++; }
         if(nk == 1)
           {
            double tr[6];
            ArrayCopy(tr, v);
            tr[bad] = y;
            int sd;
            if(SigCheck(tr, word, none, sd) == "")
              {
               fixes += g_sigName[bad] + " " + Num(v[bad]) + " → " + Num(y) + "；";
               v[bad] = y;
               why = SigCheck(v, word, none, side);
              }
           }
        }
     }
   return(why == "" ? 3 : 2);
  }

bool WriteLevels(const int side, const double &v[], const datetime created, string &err)
  {
   ResetLastError();
   int h = FileOpen("levels.csv", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      err = StringFormat("打不开 MQL5/Files/levels.csv（错误 %d）", GetLastError());
      return(false);
     }
   int dg = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   FileWriteString(h, "# written by TradeBot from a Telegram message at " + TimeToString(TimeLocal(), TIME_DATE | TIME_MINUTES) + "\n");
   FileWriteString(h, "side=" + (side > 0 ? "buy" : "sell") + "\n");
   FileWriteString(h, "created=" + TimeToString(created, TIME_DATE | TIME_MINUTES) + "\n");
   FileWriteString(h, "sl=" + DoubleToString(v[2], dg) + "\n");
   FileWriteString(h, "tp1=" + DoubleToString(v[3], dg) + "\n");
   FileWriteString(h, "tp2=" + DoubleToString(v[4], dg) + "\n");
   FileWriteString(h, "tp3=" + DoubleToString(v[5], dg) + "\n");
   FileWriteString(h, "zone_lo=" + DoubleToString(MathMin(v[0], v[1]), dg) + "\n");
   FileWriteString(h, "zone_hi=" + DoubleToString(MathMax(v[0], v[1]), dg) + "\n");
   FileWriteString(h, "zone_tol=3\ntp1_share=0.25\ntp2_share=0.45\nmax_risk_pct=20\n");
   FileWriteString(h, StringFormat("max_age_min=%d\nmin_sl_gap=2\nmax_sl_dist=20\nconfirm=1\n", LV_MAX_AGE_MIN));
   FileClose(h);
   return(true);
  }

//+------------------------------------------------------------------+
//| automatic levels                                                 |
//| Every open position of the symbol that sits inside a zone        |
//| (+- InpAutoTol) gets SL and TP1-TP3 without any tap:             |
//|  - a signal forwarded or pasted in the last InpAutoSigMin        |
//|    minutes (levels.csv): its own SL and TPs;                     |
//|  - else a zone of the latest gameplan.csv: his habit - a         |
//|    InpSubWidth zone from the edge nearest the group's FIRST      |
//|    entry, SL InpSubSL beyond it, TPs +InpTP1/2/3 from its near   |
//|    edge. The group's first entry is kept in a terminal global    |
//|    variable while the group has positions.                       |
//| TPs by entry: worst 25 % TP1, next 45 % TP2, best TP3 (as        |
//| ApplyLevels). A stop at or beyond the entry (breakeven) is kept; |
//| an SL or TP changed by you (or by Alt+L) after it was set here   |
//| is left alone; 套用 levels sets these levels' own values.        |
//| Positions outside every zone are                                 |
//| not touched (NewsGuard's fixed stop stays).                      |
//+------------------------------------------------------------------+
struct AZone
  {
   int    side;        // +1 buy, -1 sell, 0 both (pivot)
   double lo, hi;
   bool   sig;         // a signal: its own SL / TPs
   double sl;
   double tp[3];
   string name;
   datetime created;   // signal: when levels.csv was written (0 for GP zones)
  };

ulong    g_outSeen[];  // positions already reported as outside every zone
string   g_autoKey[];  // last message per group, so the same note is not sent again
string   g_autoMsg[];
datetime g_noStopWarn = 0;
string   g_noteLate = "";   // automatic notes that did not reach Telegram
datetime g_noteRetryAt = 0;
string   g_noteKey[];  // automatic notes waiting to be sent: one per group, sent 8 s after its last change
string   g_noteMsg[];
datetime g_noteTime[];
bool     g_noteUrgent[];
ulong    g_failTk[];   // positions whose last modification failed, and when to try again
datetime g_failUntil[];

string AutoPrefix() { return("TB_A_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_"); }
string TicketPrefix() { return("TB_T_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_"); }
string TicketVar(const ulong t, const string k) { return(TicketPrefix() + IntegerToString((long)t) + "_" + k); }

// "2026-10-16" (or 2026.10.16) after "gameplan " in the header line -> that day 00:00; 0 if missing
datetime GpDate(const string line)
  {
   int p = StringFind(line, "gameplan 20");
   if(p < 0)
      return(0);
   string d = StringSubstr(line, p + 9, 10);
   StringReplace(d, "-", ".");
   return(StringToTime(d));
  }

// date of the gameplan now in gameplan.csv (0 = none)
datetime GpFileDate()
  {
   int h = FileOpen("gameplan.csv", FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return(0);
   datetime day = 0;
   for(int i = 0; i < 5 && !FileIsEnding(h) && day == 0; i++)
      day = GpDate(FileReadString(h));
   FileClose(h);
   return(day);
  }

// levels.csv counts as a signal for the automatic levels only when TradeBot wrote it (not a file for Alt+L)
bool LevelsFromBot()
  {
   int h = FileOpen("levels.csv", FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return(false);
   string first = FileIsEnding(h) ? "" : FileReadString(h);
   FileClose(h);
   return(StringFind(first, "written by TradeBot") >= 0);
  }

// zones for the automatic levels: the active signal first, then the zones of the latest gameplan
int LoadZones(AZone &z[], string &info)
  {
   ArrayResize(z, 0);
   int n = 0;
   info = "";
   LvConfig c;
   string err = "";
   if(LevelsFromBot() && LvLoad(c, err) && c.zoneLo > 0 && TimeLocal() - c.created <= InpAutoSigMin * 60 && TimeLocal() - c.created >= -300)
     {
      ArrayResize(z, n + 1);
      z[n].side = c.side;
      z[n].lo = c.zoneLo;
      z[n].hi = c.zoneHi;
      z[n].sig = true;
      z[n].sl = c.sl;
      for(int k = 0; k < 3; k++) z[n].tp[k] = c.tp[k];
      z[n].name = StringFormat("喊单 %s %s–%s", c.side > 0 ? "买" : "卖", Num(c.zoneLo), Num(c.zoneHi));
      z[n].created = c.created;
      info = StringFormat("喊单 %s %s–%s（到 %s）", c.side > 0 ? "买" : "卖", Num(c.zoneLo), Num(c.zoneHi),
                          TimeToString(c.created + InpAutoSigMin * 60, TIME_MINUTES));
      n++;
     }
   if(!InpUseGp)
      return(n);
   int h = FileOpen("gameplan.csv", FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return(n);
   int first = n, nGp = 0;
   datetime day = 0;
   while(!FileIsEnding(h))
     {
      string chunk = FileReadString(h);
      string lines[];
      int cnt = StringSplit(chunk, '\n', lines);
      for(int i = 0; i < cnt; i++)
        {
         string line = lines[i];
         StringTrimLeft(line);
         StringTrimRight(line);
         if(line == "")
            continue;
         if(StringGetCharacter(line, 0) == '#')
           {
            if(day == 0)
               day = GpDate(line);
            continue;
           }
         string f[];
         if(StringSplit(line, ';', f) < 3)
            continue;
         string kind = f[0];
         StringTrimLeft(kind);
         StringTrimRight(kind);
         StringToLower(kind);
         double a = StringToDouble(f[1]), b = StringToDouble(f[2]);
         int side = (kind == "buy" || kind == "buy_mid") ? 1 : ((kind == "sell" || kind == "sell_mid") ? -1 : (kind == "pivot" ? 0 : 99));
         if(side == 99 || a <= 0 || b <= 0)
            continue;                                       // break lines are not zones
         ArrayResize(z, n + 1);
         z[n].side = side;
         z[n].lo = MathMin(a, b);
         z[n].hi = MathMax(a, b);
         z[n].sig = false;
         z[n].sl = 0;
         for(int k = 0; k < 3; k++) z[n].tp[k] = 0;
         z[n].name = StringFormat("GP %s区 %s–%s", side > 0 ? "买" : (side < 0 ? "卖" : "中枢"), Num(z[n].lo), Num(z[n].hi));
         z[n].created = 0;
         n++;
         nGp++;
        }
     }
   FileClose(h);
   if(day <= 0 || TimeLocal() - day > InpGpMaxDays * 86400 || day > TimeLocal())   // a future date is a typo
     {
      ArrayResize(z, first);                                // no date or too old: not used
      n = first;
      if(nGp > 0)
         info += (info == "" ? "" : "；") + "gameplan.csv 太旧或没有日期，没有用";
     }
   else if(nGp > 0)
      info += (info == "" ? "" : "；") + StringFormat("GP %s 的 %d 个区", TimeToString(day, TIME_DATE), nGp);
   return(n);
  }

// zone of a position: the signal if the entry is inside it, else the GP zone whose nearest edge is closest; -1 = none
int ZoneFor(const AZone &z[], const bool isBuy, const double op)
  {
   int best = -1;
   double bestD = 1e9;
   for(int k = 0; k < ArraySize(z); k++)
     {
      if(z[k].side != 0 && z[k].side != (isBuy ? 1 : -1))
         continue;
      if(op < z[k].lo - InpAutoTol || op > z[k].hi + InpAutoTol)
         continue;
      if(z[k].sig)
         return(k);
      double d = (op >= z[k].lo && op <= z[k].hi) ? 0 : MathMin(MathAbs(op - z[k].lo), MathAbs(op - z[k].hi));
      if(d < bestD)
        {
         bestD = d;
         best = k;
        }
     }
   return(best);
  }

string GroupVar(const AZone &zz, const bool isBuy)
  {
   return(AutoPrefix() + (isBuy ? "B_" : "S_") + DoubleToString(zz.lo, 2) + "_" + DoubleToString(zz.hi, 2));
  }

// Removes the remembered values of closed positions, and the first entry of groups that no open position
// belongs to any more (a position of a neighbouring zone does not keep it alive).
void AutoCleanup(const AZone &z[], const int nz, const Pos &ps[], const int n)
  {
   string pre = AutoPrefix(), tpre = TicketPrefix(), npre = "NG_S_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string nm = GlobalVariableName(i);
      if(StringFind(nm, tpre) == 0)
        {
         string f[];
         if(StringSplit(StringSubstr(nm, StringLen(tpre)), '_', f) == 2 && !PositionSelectByTicket((ulong)StringToInteger(f[0])))
            GlobalVariableDel(nm);
        }
      else if(StringFind(nm, npre) == 0)
        {
         // NewsGuard's fixed stop of a position that is closed
         if(!PositionSelectByTicket((ulong)StringToInteger(StringSubstr(nm, StringLen(npre)))))
            GlobalVariableDel(nm);
        }
      else if(StringFind(nm, pre) == 0)
        {
         bool used = false;
         for(int k = 0; k < n && !used; k++)
           {
            int zk = ZoneFor(z, ps[k].buy, ps[k].op);
            used = (zk >= 0 && GroupVar(z[zk], ps[k].buy) == nm && (z[zk].sig || !SignalSourced(ps[k].tk)));
           }
         if(!used)
            GlobalVariableDel(nm);
        }
     }
   // failed-modification pauses of closed positions
   for(int i = ArraySize(g_failTk) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(g_failTk[i]))
        {
         int last = ArraySize(g_failTk) - 1;
         g_failTk[i] = g_failTk[last];
         g_failUntil[i] = g_failUntil[last];
         ArrayResize(g_failTk, last);
         ArrayResize(g_failUntil, last);
        }
  }

bool FailPaused(const ulong t)
  {
   for(int i = 0; i < ArraySize(g_failTk); i++)
      if(g_failTk[i] == t)
         return(TimeLocal() < g_failUntil[i]);
   return(false);
  }

int FailCount(const ulong t)
  {
   string k = TicketVar(t, "n");
   double c = GlobalVariableCheck(k) ? GlobalVariableGet(k) + 1 : 1;
   GlobalVariableSet(k, c);
   return((int)c - 1);
  }

void FailMark(const ulong t, const int secs)
  {
   for(int i = 0; i < ArraySize(g_failTk); i++)
      if(g_failTk[i] == t)
        {
         g_failUntil[i] = TimeLocal() + secs;
         return;
        }
   int q = ArraySize(g_failTk);
   ArrayResize(g_failTk, q + 1);
   ArrayResize(g_failUntil, q + 1);
   g_failTk[q] = t;
   g_failUntil[q] = TimeLocal() + secs;
  }

// which levels a position follows: 1e10 + zone for a signal, 2e10 + zone for a GP zone
double SourceKey(const AZone &zz) { return((zz.sig ? 1e10 : 2e10) + MathRound(zz.lo * 10) * 1e5 + MathRound(zz.hi * 10)); }
bool   SignalSourced(const ulong t)
  {
   string kz = TicketVar(t, "z");
   return(GlobalVariableCheck(kz) && GlobalVariableGet(kz) < 2e10);
  }

// the position's stop is the fixed stop NewsGuard set (NewsGuard v1.20 stores it in NG_S_<login>_<ticket>)
string NgVar(const ulong t) { return("NG_S_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString((long)t)); }
bool   IsNewsGuardStop(const ulong t, const double cur)
  {
   string kn = NgVar(t);
   return(cur != 0.0 && GlobalVariableCheck(kn) && MathAbs(cur - GlobalVariableGet(kn)) < SymbolInfoDouble(g_sym, SYMBOL_POINT) / 2);
  }

// Sets the group's SL / TPs where needed. Returns a note for Telegram ("" = nothing new).
// Rules for each position:
//  - first sight (nothing remembered): a position younger than 5 s without a stop is left to NewsGuard for
//    this cycle; a position older than 60 s keeps a stop / TP it already has (set by you or another tool);
//  - SL: the first stop set here may replace NewsGuard's fixed stop; after that only a tighter one; a stop at
//    or beyond the entry (breakeven) is kept; a stop you changed is left alone;
//  - TPs are ranked (worst 25 % TP1, next 45 % TP2, best TP3) only when a new position joins the group, so
//    positions closing never pull the others to nearer TPs; a TP you changed is left alone.
string AutoApplyGroup(const AZone &zz, const bool isBuy, Pos &mem[], const int m, const double anchor)
  {
   int    dg   = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double pt   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   long   lvl  = MathMax(SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(g_sym, SYMBOL_TRADE_FREEZE_LEVEL));
   double minD = MathMax((double)lvl * pt, pt);
   MqlTick t;
   if(!SymbolInfoTick(g_sym, t) || t.bid <= 0 || t.ask <= 0)
     {
      if(g_force)
         g_forceOut += (g_forceOut == "" ? "" : "\n\n") + zz.name + "：没有报价，这组现在算不了。";
      return("");
     }
   // levels: the signal's own, or his habit from the zone edge nearest the first entry
   double sl, tp[3], slo = zz.lo, shi = zz.hi;
   string how = "";
   if(zz.sig)
     {
      sl = zz.sl;
      for(int k = 0; k < 3; k++) tp[k] = zz.tp[k];
     }
   else
     {
      if(shi - slo > InpSubWidth + 0.001)
        {
         bool lowEdge = MathAbs(anchor - zz.lo) <= MathAbs(anchor - zz.hi);
         if(lowEdge) shi = slo + InpSubWidth;
         else        slo = shi - InpSubWidth;
         how = StringFormat("（第一笔 %s 离%s %s 近，按 %s–%s 算）", Px(anchor), lowEdge ? "下沿" : "上沿",
                            Num(lowEdge ? zz.lo : zz.hi), Num(slo), Num(shi));
        }
      if(isBuy)
        {
         sl = slo - InpSubSL;
         tp[0] = shi + InpTP1; tp[1] = shi + InpTP2; tp[2] = shi + InpTP3;
        }
      else
        {
         sl = shi + InpSubSL;
         tp[0] = slo - InpTP1; tp[1] = slo - InpTP2; tp[2] = slo - InpTP3;
        }
     }
   sl = NormalizeDouble(sl, dg);
   for(int k = 0; k < 3; k++) tp[k] = NormalizeDouble(tp[k], dg);
   bool slOk = isBuy ? (t.bid - sl >= minD) : (sl - t.ask >= minD);
   bool tpPassed[3];
   for(int k = 0; k < 3; k++) tpPassed[k] = isBuy ? (tp[k] - t.bid < minD) : (t.ask - tp[k] < minD);
   long nowMsc = (long)TimeCurrent() * 1000;
   double srcKey = SourceKey(zz);

   // 1. first sight, a new source and repairs; which positions take part this cycle
   SortWorstFirst(mem);
   bool skip[], fresh[], repair[], newSrc[];
   ArrayResize(skip, m); ArrayResize(fresh, m); ArrayResize(repair, m); ArrayResize(newSrc, m);
   bool reRank = false;
   for(int i = 0; i < m; i++)
     {
      skip[i] = fresh[i] = repair[i] = newSrc[i] = false;
      if(!PositionSelectByTicket(mem[i].tk) || (!g_force && FailPaused(mem[i].tk)))
        { skip[i] = true; continue; }
      double cur = PositionGetDouble(POSITION_SL), curTp = PositionGetDouble(POSITION_TP);
      long   ageS = (nowMsc - mem[i].tm) / 1000;
      string ks = TicketVar(mem[i].tk, "s"), kt = TicketVar(mem[i].tk, "t"), kz = TicketVar(mem[i].tk, "z");
      bool hasS = GlobalVariableCheck(ks), hasT = GlobalVariableCheck(kt);
      bool isNg = IsNewsGuardStop(mem[i].tk, cur);
      if(!g_force && !hasS && !hasT)
        {
         if(InpWithNewsGuard && cur == 0.0 && ageS < 5)
           { skip[i] = true; continue; }                   // NewsGuard adds its stop first
         if(ageS > 60 || !InpWithNewsGuard)
           {
            // an older position (or any position when NewsGuard is not used): a stop / TP it already has was set by you or another tool - keep it
            // (NewsGuard's fixed stop is only a placeholder and may be replaced at any age)
            if(cur != 0.0 && !isNg) { GlobalVariableSet(ks, -1); hasS = true; }
            if(curTp != 0.0)        { GlobalVariableSet(kt, -1); hasT = true; }
           }
        }
      // a new source for this position: a signal forwarded after the GP levels were set, or a new GP zone
      if(GlobalVariableCheck(kz) && MathAbs(GlobalVariableGet(kz) - srcKey) > 0.5)
         newSrc[i] = true;
      string kc = TicketVar(mem[i].tk, "c");
      if(zz.sig && GlobalVariableCheck(kz) && (!GlobalVariableCheck(kc) || MathAbs(GlobalVariableGet(kc) - (double)zz.created) > 0.5))
         newSrc[i] = true;                                // the same signal zone sent again with other levels
      // a position skipped last cycle (it changed while being read) takes part in the re-rank now
      if(GlobalVariableCheck(TicketVar(mem[i].tk, "p")))
        {
         fresh[i] = true;
         reRank = true;
        }
      // NewsGuard's first stop landed just after ours and wiped our TP: set both again
      if(!g_dry && InpWithNewsGuard && hasT && GlobalVariableGet(kt) > 0 && curTp == 0.0 && (isNg || ageS <= 60) && !GlobalVariableCheck(TicketVar(mem[i].tk, "r")))
        {
         repair[i] = true;
         GlobalVariableSet(TicketVar(mem[i].tk, "r"), 1);
        }
      if(!hasT || repair[i] || newSrc[i] || g_force)
        {
         fresh[i] = true;
         reRank = true;
        }
     }

   // 2. apply
   int n1 = (int)MathRound(0.25 * m);
   int n2 = (int)MathRound(0.70 * m) - n1;
   if(n1 + n2 > m) n2 = m - n1;
   int changed = 0, failed = 0, slSkipped = 0, kept = 0, handled = 0, reSig = 0, slTighterKept = 0, beWait = 0, fallback = 0, noStop = 0, tpFail = 0;
   int cnt[4] = {0, 0, 0, 0};
   double lots = 0, risk = 0;
   string lastErr = "", tpErr = "";
   for(int i = 0; i < m; i++)
     {
      if(skip[i] || !PositionSelectByTicket(mem[i].tk))
         continue;
      double op = mem[i].op, cur = PositionGetDouble(POSITION_SL), curTp = PositionGetDouble(POSITION_TP);
      string ks = TicketVar(mem[i].tk, "s"), kt = TicketVar(mem[i].tk, "t"), kz = TicketVar(mem[i].tk, "z");
      bool hasS = GlobalVariableCheck(ks), hasT = GlobalVariableCheck(kt);
      double sv = hasS ? GlobalVariableGet(ks) : 0, tv = hasT ? GlobalVariableGet(kt) : 0;
      bool isNg = IsNewsGuardStop(mem[i].tk, cur);
      bool ours = sv > 0 && MathAbs(cur - sv) < pt / 2;
      // the first stop set here may replace NewsGuard's fixed stop; a newly forwarded signal sets its own stop
      // over a stop set here; otherwise a stop set here is only ever tightened
      bool firstS = g_force || !hasS || repair[i] || isNg || (newSrc[i] && zz.sig && ours);
      bool ownS = firstS || ours;
      bool ownT = g_force || !hasT || repair[i] || (tv > 0 && MathAbs(curTp - tv) < pt / 2);
      double opN = NormalizeDouble(op, dg);
      bool lockIn = cur > 0 && (isBuy ? cur >= opN - pt / 2 : cur <= opN + pt / 2);
      double newSl = cur;
      if(lockIn)
         kept++;
      else if(ownS)
        {
         bool tighter = (cur == 0.0) || (isBuy ? sl > cur + pt / 2 : sl < cur - pt / 2);
         if(!slOk)
           {
            if(cur == 0.0)
              {
               double fb = NormalizeDouble(isBuy ? op - (InpSubWidth + InpSubSL) : op + (InpSubWidth + InpSubSL), dg);
               if(isBuy ? (t.bid - fb >= minD) : (fb - t.ask >= minD))
                 {
                  newSl = fb;
                  fallback++;
                  if(!g_dry)
                     GlobalVariableSet(TicketVar(mem[i].tk, "f"), fb);
                 }
               else
                  noStop++;
              }
            else if(!(GlobalVariableCheck(TicketVar(mem[i].tk, "f")) && MathAbs(GlobalVariableGet(TicketVar(mem[i].tk, "f")) - cur) < pt / 2))
               slSkipped++;
           }
         else if(firstS || tighter)
            newSl = sl;
         else if(MathAbs(sl - cur) >= pt / 2)
            slTighterKept++;
        }
      int k = (i < n1) ? 0 : (i < n1 + n2 ? 1 : 2);
      while(k < 3 && (tpPassed[k] || (isBuy ? tp[k] < op + 0.30 : tp[k] > op - 0.30)))
         k++;
      double newTp = curTp;
      if(ownT && k < 3 && (reRank || curTp == 0.0))
         newTp = tp[k];
      // a position about to be moved to breakeven by NewsGuard (+$4) is left to it first (both would change it at once)
      double prof = isBuy ? t.bid - op : op - t.ask;
      if(InpWithNewsGuard && !lockIn && !firstS && prof >= 3.5 && (MathAbs(newSl - cur) >= pt / 2 || MathAbs(newTp - curTp) >= pt / 2))
        {
         GlobalVariableSet(TicketVar(mem[i].tk, "p"), 1);
         beWait++;
         continue;
        }
      if(g_force)
         g_plan += IntegerToString((long)mem[i].tk) + ":" + DoubleToString(newSl, dg) + ":" + DoubleToString(newTp, dg) + ":" + DoubleToString(mem[i].vol, 2) + ";";
      bool tpLost = false;
      if(g_dry)
        {
         if(MathAbs(newSl - cur) >= pt / 2 || MathAbs(newTp - curTp) >= pt / 2)
            changed++;
        }
      else if(MathAbs(newSl - cur) >= pt / 2 || MathAbs(newTp - curTp) >= pt / 2)
        {
         // the position may have changed since it was read (e.g. NewsGuard's breakeven): then wait a cycle
         if(!PositionSelectByTicket(mem[i].tk) || MathAbs(PositionGetDouble(POSITION_SL) - cur) >= pt / 2 ||
            MathAbs(PositionGetDouble(POSITION_TP) - curTp) >= pt / 2)
           {
            GlobalVariableSet(TicketVar(mem[i].tk, "p"), 1);   // takes part in the next cycle's re-rank
            if(g_force)
              {
               failed++;
               lastErr = "刚被改动";
              }
            continue;
           }
         bool ok = trade.PositionModify(mem[i].tk, newSl, newTp) || trade.ResultRetcode() == TRADE_RETCODE_NO_CHANGES;
         if(!ok && cur == 0.0 && newSl > 0 && MathAbs(newTp - curTp) >= pt / 2 && PositionSelectByTicket(mem[i].tk) &&
            PositionGetDouble(POSITION_SL) == 0.0 && MathAbs(PositionGetDouble(POSITION_TP) - curTp) < pt / 2)
           {
            // the TP was refused: set the stop alone, so the position is not left without one
            string e1 = LastErr();
            if(trade.PositionModify(mem[i].tk, newSl, curTp) || trade.ResultRetcode() == TRADE_RETCODE_NO_CHANGES)
              {
               ok = true;
               tpLost = true;
               tpFail++;
               tpErr = e1;
               newTp = curTp;
              }
           }
         if(ok)
            changed++;
         else
           {
            failed++;
            lastErr = LastErr();
            uint rc = trade.ResultRetcode();
            bool closed = (rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED || rc == TRADE_RETCODE_SERVER_DISABLES_AT || rc == TRADE_RETCODE_CLIENT_DISABLES_AT);
            FailMark(mem[i].tk, closed ? 60 : (cur == 0.0 ? (FailCount(mem[i].tk) < 3 ? 3 : 10) : 30));
            continue;
           }
         if(newSrc[i] && zz.sig && MathAbs(newSl - cur) >= pt / 2)
            reSig++;
         if(isNg && MathAbs(newSl - cur) >= pt / 2)
            GlobalVariableDel(NgVar(mem[i].tk));
        }
      // remember what was set here: a later change by you (or by another tool) is then left alone
      if(!g_dry)
        {
         if(ownS && !lockIn && newSl > 0 && (firstS || MathAbs(newSl - sv) >= pt / 2))
            GlobalVariableSet(ks, newSl);
         if(ownT && newTp > 0 && !tpLost)
            GlobalVariableSet(kt, newTp);
         GlobalVariableSet(kz, srcKey);
         if(zz.sig)
            GlobalVariableSet(TicketVar(mem[i].tk, "c"), (double)zz.created);
         GlobalVariableDel(TicketVar(mem[i].tk, "p"));
        }
      if(MathAbs(newTp - tp[0]) < pt / 2) cnt[0]++;
      else if(MathAbs(newTp - tp[1]) < pt / 2) cnt[1]++;
      else if(MathAbs(newTp - tp[2]) < pt / 2) cnt[2]++;
      else cnt[3]++;
      handled++;
      lots += mem[i].vol;
      double eff = g_dry ? newSl : (PositionSelectByTicket(mem[i].tk) ? PositionGetDouble(POSITION_SL) : newSl);
      risk += (eff > 0) ? LossAt(isBuy, mem[i].vol, op, eff) : 0;
     }
   if(handled > 0 && g_force && !g_dry)
     {
      // one group per side for NewsGuard: a signal's group first, else the group with the newest entry (written by LevelsNow)
      long newest = 0;
      for(int i = 0; i < m; i++)
         newest = MathMax(newest, mem[i].tm);
      double sc = (zz.sig ? 1e15 : 0) + (double)newest + 1;
      int d = isBuy ? 0 : 1;
      if(sc > g_alScore[d])
        {
         g_alScore[d] = sc;
         g_alTp1[d] = tp[0];
         g_alLo[d] = zz.lo - InpAutoTol;
         g_alHi[d] = zz.hi + InpAutoTol;
        }
     }
   else if(!g_force && changed > 0 && !g_dry)
     {
      // NewsGuard moves the group to breakeven at this TP1
      string base = "AL_G_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_sym + (isBuy ? "_B_" : "_S_");
      GlobalVariableSet(base + "tp1", tp[0]);
      GlobalVariableSet(base + "lo", zz.lo - InpAutoTol);
      GlobalVariableSet(base + "hi", zz.hi + InpAutoTol);
      GlobalVariableSet(base + "t", (double)TimeCurrent());
      GlobalVariablesFlush();
     }
   if(!g_force && changed == 0 && failed == 0 && slSkipped == 0 && noStop == 0)
      return("");
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = (bal > 0) ? risk / bal * 100.0 : 0;
   string s = StringFormat("%s%s%s\n%s %d 张 %.2f 手，SL %s；TP1 %s × %d，TP2 %s × %d，TP3 %s × %d%s\n全部打到止损约 −$%.0f（余额的 %.1f%%）",
                           g_force ? (g_dry ? "" : "已套用 levels：") : "自动设好 levels：", zz.name, how, isBuy ? "买" : "卖", handled, lots, Px(sl), Px(tp[0]), cnt[0], Px(tp[1]), cnt[1], Px(tp[2]), cnt[2],
                           cnt[3] > 0 ? StringFormat("，其他止盈 × %d", cnt[3]) : "", risk, pct);
   if(slTighterKept > 0)
      s += StringFormat("\n%d 张保留了原来更紧的止损（自动设的止损只会收紧）。", slTighterKept);
   if(beWait > 0)
      s += StringFormat("\n%d 张快到保本，先等 NewsGuard 移保本，再设 TP。", beWait);
   if(reSig > 0)
      s += StringFormat("\n%d 张按新转发的喊单重设了止损和止盈。", reSig);
   if(pct > InpAutoWarnPct)
      s += StringFormat("\n⚠️ 超过 %.0f%%。", InpAutoWarnPct);
   if(kept > 0)
      s += StringFormat("\n%d 张已在保本或更好，止损没动。", kept);
   if(slSkipped > 0)
      s += StringFormat("\n注意：价格已经越过 SL %s，%d 张的止损没有改（保留原来的）。", Px(sl), slSkipped);
   if(fallback > 0)
      s += StringFormat("\n注意：价格已经越过 SL %s，%d 张先设了离进场 $%.0f 的止损；价格回来后%s收紧到 %s。", Px(sl), fallback, InpSubWidth + InpSubSL,
                        g_force ? "再点一次「套用 levels」" : "再", Px(sl));
   if(noStop > 0)
      s += StringFormat("\n⚠️ %d 张没有止损：价格已经越过 SL %s，离进场 $%.0f 的止损也设不了。请手动处理。", noStop, Px(sl), InpSubWidth + InpSubSL);
   if(failed > 0)
      s += StringFormat("\n注意：%d 张没设成功（%s），%s。", failed, lastErr, g_force ? "再点一次「套用 levels」" : "稍后再试");
   if(tpFail > 0)
      s += StringFormat("\n注意：%d 张的止盈没设成功（%s），只设了止损%s。", tpFail, tpErr, g_force ? "；再点一次「套用 levels」" : "，稍后再试");
   if(g_force)
     {
      if(g_dry && changed == 0)
         s += "\n（这组本来就是这样，不会有改动）";
      g_forceOut += (g_forceOut == "" ? "" : "\n\n") + s;
      if(!g_dry)
         PrintFormat("TradeBot levels %s %s: changed %d, failed %d, SL %s, risk $%.0f %s", zz.name, isBuy ? "buy" : "sell", changed, failed, Px(sl), risk, lastErr);
      return(s);
     }
   // the same note twice in a row (e.g. a stop that cannot be set yet) is not sent again,
   // except the no-stop warning, which repeats every 60 s
   string key = GroupVar(zz, isBuy);
   bool urgent = false;
   if(noStop > 0 && TimeLocal() - g_noStopWarn >= 60)
     {
      urgent = true;
      g_noStopWarn = TimeLocal();
     }
   int q = -1;
   for(int i = 0; i < ArraySize(g_autoKey) && q < 0; i++)
      if(g_autoKey[i] == key)
         q = i;
   if(q >= 0 && changed == 0 && g_autoMsg[q] == s && !urgent)
      return("");
   bool firstNote = (q < 0);
   if(q < 0)
     {
      q = ArraySize(g_autoKey);
      ArrayResize(g_autoKey, q + 1);
      ArrayResize(g_autoMsg, q + 1);
      g_autoKey[q] = key;
     }
   g_autoMsg[q] = s;
   PrintFormat("TradeBot auto levels %s %s: changed %d, failed %d, SL skipped %d, SL %s, risk $%.0f %s", zz.name, isBuy ? "buy" : "sell",
               changed, failed, slSkipped, Px(sl), risk, lastErr);
   NoteQueue(key, s, urgent || firstNote || noStop > 0 || fallback > 0);
   return(s);
  }

string OrderPrefix() { return("TB_O_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_"); }

// the zone of an order group: his 5-wide signal zone with the group's first entry as its near edge
// (sell: first entry = lower edge; buy: first entry = upper edge)
void OrderZone(const bool isBuy, const double anchor, AZone &gz)
  {
   gz.side = isBuy ? 1 : -1;
   gz.lo = isBuy ? anchor - InpSubWidth : anchor;
   gz.hi = isBuy ? anchor : anchor + InpSubWidth;
   gz.sig = false;
   gz.sl = 0;
   for(int k = 0; k < 3; k++) gz.tp[k] = 0;
   gz.created = 0;
   gz.name = StringFormat("按第一笔 %s 算（区间 %s–%s）", Px(anchor), Px(gz.lo), Px(gz.hi));
  }

// Levels from your own orders: positions that are not in a forwarded signal's zone (and do not follow an
// expired signal) are grouped by their first entry. A position stays in the group it was set in; a saved first
// entry lives only while one of its positions is open; a new position joins the nearest live group whose zone
// (+- InpAutoTol) contains it, else it starts a new group. First entries: TB_O_<login>_<B|S>_<price>_<ticket>.
string OrderLevels(const AZone &z[], const Pos &ps[], const int n)
  {
   string msg = "";
   for(int d = 0; d < 2; d++)
     {
      bool isBuy = (d == 0);
      string pre = OrderPrefix() + (isBuy ? "B_" : "S_");
      double anc[], key[];
      string var[];
      bool   live[];
      int na = 0;
      for(int g = 0; g < GlobalVariablesTotal(); g++)
        {
         string nm = GlobalVariableName(g);
         if(StringFind(nm, pre) != 0)
            continue;
         ArrayResize(anc, na + 1); ArrayResize(key, na + 1); ArrayResize(var, na + 1); ArrayResize(live, na + 1);
         anc[na] = GlobalVariableGet(nm);
         var[na] = nm;
         AZone t;
         OrderZone(isBuy, anc[na], t);
         key[na] = SourceKey(t);
         live[na] = false;
         na++;
        }
      // this side's positions outside a signal zone, oldest first
      Pos un[];
      int nu = 0;
      for(int i = 0; i < n; i++)
         if(ps[i].buy == isBuy && ZoneFor(z, isBuy, ps[i].op) < 0 && !SignalSourced(ps[i].tk))
           {
            ArrayResize(un, nu + 1);
            un[nu++] = ps[i];
           }
      for(int i = 0; i < nu - 1; i++)
         for(int j = i + 1; j < nu; j++)
            if(un[j].tm < un[i].tm)
              {
               Pos x = un[i]; un[i] = un[j]; un[j] = x;
              }
      // 1. a position stays in the group it was set in
      int grp[];
      ArrayResize(grp, nu);
      for(int i = 0; i < nu; i++)
        {
         grp[i] = -1;
         string kz = TicketVar(un[i].tk, "z");
         if(!GlobalVariableCheck(kz))
            continue;
         double v = GlobalVariableGet(kz);
         for(int a2 = 0; a2 < na && grp[i] < 0; a2++)
            if(MathAbs(v - key[a2]) < 0.5)
              {
               grp[i] = a2;
               live[a2] = true;
              }
        }
      // 2. a first entry without an open position of its group is forgotten
      for(int a2 = 0; a2 < na; a2++)
         if(!live[a2])
            if(!g_dry)
               GlobalVariableDel(var[a2]);
      // 3. new positions: the nearest live group zone, else a new group
      for(int i = 0; i < nu; i++)
        {
         if(grp[i] >= 0)
            continue;
         int best = -1;
         double bestD = 1e9;
         for(int a2 = 0; a2 < na; a2++)
           {
            if(!live[a2])
               continue;
            double lo = isBuy ? anc[a2] - InpSubWidth : anc[a2], hi = isBuy ? anc[a2] : anc[a2] + InpSubWidth;
            if(un[i].op < lo - InpAutoTol || un[i].op > hi + InpAutoTol)
               continue;
            double dd = (un[i].op >= lo && un[i].op <= hi) ? 0 : MathMin(MathAbs(un[i].op - lo), MathAbs(un[i].op - hi));
            dd = dd * 1000 + MathAbs(un[i].op - anc[a2]);              // tie: the nearest first entry
            if(dd < bestD)
              {
               bestD = dd;
               best = a2;
              }
           }
         if(best < 0)
           {
            ArrayResize(anc, na + 1); ArrayResize(key, na + 1); ArrayResize(var, na + 1); ArrayResize(live, na + 1);
            anc[na] = un[i].op;
            var[na] = pre + DoubleToString(un[i].op, 2) + "_" + IntegerToString((long)un[i].tk);
            AZone t;
            OrderZone(isBuy, anc[na], t);
            key[na] = SourceKey(t);
            live[na] = true;
            if(!g_dry)
               GlobalVariableSet(var[na], anc[na]);
            best = na++;
           }
         grp[i] = best;
        }
      for(int a2 = 0; a2 < na; a2++)
        {
         if(!live[a2])
            continue;
         Pos mem[];
         int m = 0;
         for(int i = 0; i < nu; i++)
            if(grp[i] == a2)
              {
               ArrayResize(mem, m + 1);
               mem[m++] = un[i];
              }
         if(m == 0)
            continue;
         AZone gz;
         OrderZone(isBuy, anc[a2], gz);
         string s2 = AutoApplyGroup(gz, isBuy, mem, m, anc[a2]);
         if(s2 != "")
            msg += (msg == "" ? "" : "\n\n") + s2;
        }
     }
   return(msg);
  }

// queue an automatic note (one per key; a newer note replaces the older one)
void NoteQueue(const string key, const string text, const bool urgent)
  {
   for(int i = 0; i < ArraySize(g_noteKey); i++)
      if(g_noteKey[i] == key)
        {
         g_noteMsg[i] = text;
         g_noteTime[i] = TimeLocal();
         g_noteUrgent[i] = g_noteUrgent[i] || urgent;
         return;
        }
   int q = ArraySize(g_noteKey);
   ArrayResize(g_noteKey, q + 1); ArrayResize(g_noteMsg, q + 1); ArrayResize(g_noteTime, q + 1); ArrayResize(g_noteUrgent, q + 1);
   g_noteKey[q] = key;
   g_noteMsg[q] = text;
   g_noteTime[q] = TimeLocal();
   g_noteUrgent[q] = urgent;
  }

// send the notes whose group did not change for 8 s (urgent ones at once), in one message without buttons,
// with a short timeout so a slow Telegram does not hold up the automatic levels
void NoteFlush()
  {
   string out = "";
   for(int i = ArraySize(g_noteKey) - 1; i >= 0; i--)
     {
      if(!g_noteUrgent[i] && TimeLocal() - g_noteTime[i] < 8)
         continue;
      out = g_noteMsg[i] + (out == "" ? "" : "\n\n" + out);
      int last = ArraySize(g_noteKey) - 1;
      g_noteKey[i] = g_noteKey[last]; g_noteMsg[i] = g_noteMsg[last]; g_noteTime[i] = g_noteTime[last]; g_noteUrgent[i] = g_noteUrgent[last];
      ArrayResize(g_noteKey, last); ArrayResize(g_noteMsg, last); ArrayResize(g_noteTime, last); ArrayResize(g_noteUrgent, last);
     }
   if(g_token == "" || InpChatId == 0)
      return;
   bool retry = (g_noteLate != "" && TimeLocal() >= g_noteRetryAt);
   string body = retry ? g_noteLate + (out == "" ? "" : "\n\n" + out) : out;
   if(body == "")
      return;
   if(TgSend(InpChatId, (retry ? "之前没送到的通知：\n" : "") + body, "", 3000))
     {
      if(retry)
         g_noteLate = "";
     }
   else
     {
      g_noteLate = retry ? body : g_noteLate + (g_noteLate == "" || out == "" ? "" : "\n\n") + out;
      if(StringLen(g_noteLate) > 3000)
         g_noteLate = StringSubstr(g_noteLate, StringLen(g_noteLate) - 3000);   // keep the newest
      g_noteRetryAt = TimeLocal() + 30;
     }
  }

void AutoLevels()
  {
   if(!InpAutoLevels && !g_force)
      return;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      if(g_force)
         g_forceOut = "MT5 没连上服务器，现在设不了 levels。";
      return;
     }
   if(StringFind(g_sym, "XAU") != 0 && StringFind(g_sym, "GOLD") < 0)
     {
      if(g_force)
         g_forceOut = "levels 只用于黄金，现在管理的是 " + g_sym + "。";
      return;
     }
   AZone z[];
   string info;
   int nz = LoadZones(z, info);
   if(InpOrderLevels)
      info += (info == "" ? "" : "；") + StringFormat("其他单按每组第一笔算（SL 离第一笔 $%.0f，TP 离第一笔 $%.0f / $%.0f / $%.0f）",
                                                     InpSubWidth + InpSubSL, InpTP1, InpTP2, InpTP3);
   g_autoInfo = info;
   Pos ps[];
   int n = Collect(ps);
   if(!g_dry)
      AutoCleanup(z, nz, ps, n);
   if(n == 0)
     {
      if(g_force)
         g_forceOut = "没有持仓。";
      if(g_dry)
         return;
      ArrayResize(g_outSeen, 0);
      string pre = OrderPrefix();                         // no position open: no order group
      for(int g = GlobalVariablesTotal() - 1; g >= 0; g--)
         if(StringFind(GlobalVariableName(g), pre) == 0)
            GlobalVariableDel(GlobalVariableName(g));
      return;
     }
   string msg = "";
   if(g_force)
     {
      // positions set by a signal that has expired keep its levels (neither the zone groups nor the order groups take them)
      int nOld = 0;
      for(int i = 0; i < n; i++)
        {
         int zk = ZoneFor(z, ps[i].buy, ps[i].op);
         if(SignalSourced(ps[i].tk) && (zk < 0 || !z[zk].sig))
            nOld++;
        }
      if(nOld > 0)
         msg = StringFormat("%d 张之前按喊单设过（喊单已过期或被新喊单替换），这次没动。", nOld);
     }
   // positions outside every zone: one note each
   int nOut = 0;
   double oLo = 0, oHi = 0;
   for(int i = 0; i < n; i++)
     {
      if(InpOrderLevels || ZoneFor(z, ps[i].buy, ps[i].op) >= 0 || GlobalVariableCheck(TicketVar(ps[i].tk, "z")))
         continue;                                         // in a zone, or levels were set here before
      bool seen = false;
      for(int q = 0; q < ArraySize(g_outSeen) && !seen; q++)
         seen = (g_outSeen[q] == ps[i].tk);
      if(seen)
         continue;
      int q = ArraySize(g_outSeen);
      ArrayResize(g_outSeen, q + 1);
      g_outSeen[q] = ps[i].tk;
      oLo = (nOut == 0) ? ps[i].op : MathMin(oLo, ps[i].op);
      oHi = (nOut == 0) ? ps[i].op : MathMax(oHi, ps[i].op);
      nOut++;
     }
   if(nOut > 0)
      msg += StringFormat("%d 张（进场价 %s–%s）不在任何区里，没有自动设 levels（NewsGuard 的固定止损照常）。%s", nOut, Px(oLo), Px(oHi),
                          nz == 0 ? "\n这台电脑上没有可用的喊单或 GP：早上把他的 GP 帖转发给我。" : "");
   if(nz > 0 || InpOrderLevels)
     {
      if(!TradingAllowed())
        {
         static datetime warned = 0;
         if(g_force)
            msg += (msg == "" ? "" : "\n\n") + "Algo Trading 关着，现在设不了 levels：先打开 Algo Trading。";
         else if(TimeLocal() - warned > 600)
           {
            warned = TimeLocal();
            msg += (msg == "" ? "" : "\n\n") + "Algo Trading 关着，没法自动设 levels。";
           }
        }
      else
        {
         for(int k = 0; k < nz; k++)
            for(int d = 0; d < 2; d++)
              {
               bool isBuy = (d == 0);
               if(z[k].side != 0 && z[k].side != (isBuy ? 1 : -1))
                  continue;
               Pos mem[];
               int m = 0;
               long firstTm = 0;
               double firstOp = 0;
               for(int i = 0; i < n; i++)
                  // after a signal expires, its positions keep the signal's levels (not regrouped into a GP zone)
                  if(ps[i].buy == isBuy && ZoneFor(z, isBuy, ps[i].op) == k && (z[k].sig || !SignalSourced(ps[i].tk)))
                    {
                     ArrayResize(mem, m + 1);
                     mem[m++] = ps[i];
                     if(firstTm == 0 || ps[i].tm < firstTm)
                       {
                        firstTm = ps[i].tm;
                        firstOp = ps[i].op;
                       }
                    }
               if(m == 0)
                  continue;
               // the group's first entry decides the edge, and stays while the group has positions
               string gv = GroupVar(z[k], isBuy);
               double anchor, sk = SourceKey(z[k]);
               bool alive = false;
               for(int i = 0; i < m && !alive; i++)
                 {
                  string kz = TicketVar(mem[i].tk, "z");
                  alive = GlobalVariableCheck(kz) && MathAbs(GlobalVariableGet(kz) - sk) < 0.5;
                 }
               if(alive && GlobalVariableCheck(gv))
                  anchor = GlobalVariableGet(gv);
               else
                 {
                  anchor = firstOp;
                  if(!g_dry)
                     GlobalVariableSet(gv, anchor);
                 }
               AutoApplyGroup(z[k], isBuy, mem, m, anchor);        // queues its own note
              }
         if(InpOrderLevels)
           {
            OrderLevels(z, ps, n);                                // each group queues its own note
           }
        }
     }
   if(msg != "")
     {
      if(g_force)
         g_forceOut = msg + (g_forceOut == "" ? "" : "\n\n" + g_forceOut);
      else
         NoteQueue("misc", msg, true);
     }
  }

//+------------------------------------------------------------------+
//| gameplan posts pasted or forwarded -> gameplan.csv               |
//| Same reading as the research script gp_backtest.py: numbered     |
//| items; "medium risk" / "risky" -> *_mid; "pivotal" -> pivot;     |
//| "break(s) ... at X" -> a line; two prices -> a zone.             |
//+------------------------------------------------------------------+
// 4-5 digit prices in s, in order (typos of the thousands digit are fixed against the price)
int GpNumbers(const string s, const double price, double &out[])
  {
   ArrayResize(out, 0);
   int n = StringLen(s), m = 0;
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(!IsDig(c) || (i > 0 && (IsDig(StringGetCharacter(s, i - 1)) || StringGetCharacter(s, i - 1) == '.')))
         continue;
      double x;
      int dg;
      int e = ReadNum(s, i, x, dg);
      if(e < 0)
         continue;
      i = e - 1;
      if(dg < 4 || dg > 5)
         continue;
      if(dg == 5)
         x /= 10;                                         // "44645" -> 4464.5
      if(price > 0 && MathAbs(x - price) > 500)
        {
         if(MathAbs(x - 1000 - price) <= 500)      x -= 1000;
         else if(MathAbs(x + 1000 - price) <= 500) x += 1000;
        }
      ArrayResize(out, m + 1);
      out[m++] = x;
     }
   return(m);
  }

bool HasWord(const string s, const string w) { return(FindWord(s, w, 0) >= 0); }

string CsvSafe(const string s, const int maxLen)
  {
   string r = s;
   StringReplace(r, ";", ",");
   StringReplace(r, "\n", " ");
   StringReplace(r, "\r", " ");
   StringTrimLeft(r);
   StringTrimRight(r);
   if(StringLen(r) > maxLen)
      r = StringSubstr(r, 0, maxLen);
   return(r);
  }

// keyboard for gameplan replies: none while a confirm is waiting (a new menu would make it stale)
string GpKb() { return((g_pending != "" && TimeLocal() - g_pendingT <= InpConfirmS) ? "" : "menu"); }

// 套用 levels from your orders: dry = the preview text, else set them now and return what was set.
// g_plan: each position's SL / TP / lots of this run ("" = nothing to set)
string LevelsNow(const bool dry)
  {
   g_force = true;
   g_dry = dry;
   g_forceOut = "";
   g_plan = "";
   for(int d = 0; d < 2; d++)
      g_alScore[d] = 0;
   AutoLevels();
   g_force = false;
   g_dry = false;
   if(!dry)
      for(int d = 0; d < 2; d++)
         if(g_alScore[d] > 0)
           {
            // NewsGuard moves this group to breakeven at its TP1
            string base = "AL_G_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + g_sym + (d == 0 ? "_B_" : "_S_");
            GlobalVariableSet(base + "tp1", g_alTp1[d]);
            GlobalVariableSet(base + "lo", g_alLo[d]);
            GlobalVariableSet(base + "hi", g_alHi[d]);
            GlobalVariableSet(base + "t", (double)TimeCurrent());
            GlobalVariablesFlush();
           }
   return(g_forceOut == "" ? "没有要设的单。" : g_forceOut);
  }

// A gameplan post: write gameplan.csv and gameplans/<date>.csv. Returns false when the text is not a gameplan.
bool TryGameplan(const long chat, const string text, const long origin)
  {
   string low = text;
   StringToLower(low);
   if(StringFind(low, "gameplan") < 0)
      return(false);
   MqlTick tk;
   double price = SymbolInfoTick(g_sym, tk) ? (tk.bid + tk.ask) / 2 : 0;
   // one kind of space and dash, keep the line breaks
   string t = "";
   for(int i = 0; i < StringLen(text); i++)
     {
      ushort c = StringGetCharacter(text, i);
      if(c == '\t' || c == '\r' || c == 0xA0 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x3000)
         c = ' ';
      else if(c == 0x2010 || c == 0x2011 || c == 0x2012 || c == 0x2013 || c == 0x2014 || c == 0x2212 || c == 0xFF0D)
         c = '-';
      t += ShortToString(c);
     }
   string tf = "";
   string tfs[4] = {"(m30)", "(h1)", "(h4)", "(m15)"};
   for(int i = 0; i < 4 && tf == ""; i++)
      if(StringFind(low, tfs[i]) >= 0)
        {
         tf = StringSubstr(tfs[i], 1, StringLen(tfs[i]) - 2);
         StringToUpper(tf);
        }
   // numbered items: a line that starts with "1." / "2 ." ...; following lines belong to it
   string lines[], items[];
   int nl = StringSplit(t, '\n', lines), ni = 0;
   for(int i = 0; i < nl; i++)
     {
      string ln = lines[i];
      StringTrimLeft(ln);
      StringTrimRight(ln);
      if(ln == "")
         continue;
      int j = 0;
      bool start = false;
      if(IsDig(StringGetCharacter(ln, 0)))
        {
         j = 1;
         while(j < StringLen(ln) && StringGetCharacter(ln, j) == ' ') j++;
         start = (j < StringLen(ln) && StringGetCharacter(ln, j) == '.');
        }
      if(start)
        {
         ArrayResize(items, ni + 1);
         items[ni++] = StringSubstr(ln, j + 1);
        }
      else if(ni > 0)
         items[ni - 1] += " " + ln;
     }
   string rows = "", list = "";
   int nz = 0;
   for(int i = 0; i < ni; i++)
     {
      string body = items[i];
      StringTrimLeft(body);
      string lb = body;
      StringToLower(lb);
      // "sell-side liquidity" / "buy-side" are not directions
      StringReplace(lb, "buy-side", "liquidity-side");
      StringReplace(lb, "sell-side", "liquidity-side");
      StringReplace(lb, "buyside", "liquidityside");
      StringReplace(lb, "sellside", "liquidityside");
      StringReplace(lb, "buy side", "liquidity side");
      StringReplace(lb, "sell side", "liquidity side");
      bool mid = StringFind(lb, "medium risk") >= 0 || StringFind(lb, "risky") >= 0;
      bool pivot = StringFind(lb, "pivotal") >= 0;
      int sv = StringFind(lb, "serves");
      string pre = (sv >= 0) ? StringSubstr(lb, 0, sv) : lb;
      bool brk = !pivot && (HasWord(pre, "break") || HasWord(pre, "breaks") || HasWord(pre, "rebreak") || HasWord(pre, "rebreaks"));
      int sIf = StringFind(lb, " if ");
      string preIf = (sIf >= 0) ? StringSubstr(lb, 0, sIf) : lb;
      int side = 0;
      bool buyW = HasWord(lb, "buy") || HasWord(lb, "buys");
      bool sellPre = HasWord(preIf, "sell") || HasWord(preIf, "sells");
      bool buyPre = HasWord(preIf, "buy") || HasWord(preIf, "buys");
      if(!pivot && buyPre && sellPre)
         side = 0;                                         // both directions in one item: not read
      else if(buyW && !sellPre)
         side = 1;
      else if(HasWord(lb, "sell") || HasWord(lb, "sells"))
         side = -1;
      double nums[];
      int nn = GpNumbers(body, price, nums);
      string kind = "";
      double a = 0, b = 0;
      // a conditional break item ("sells if price breaks ... at X") is always a line, never a tradable zone
      if(pivot && nn >= 2)
        { kind = "pivot"; a = nums[0]; b = nums[1]; }
      else if((brk && nn >= 1) || nn == 1)
        {
         if(side != 0)
           { kind = side > 0 ? "buy_line" : "sell_line"; a = nums[0]; b = 0; }
        }
      else if(nn >= 2 && side != 0)
        { kind = side > 0 ? (mid ? "buy_mid" : "buy") : (mid ? "sell_mid" : "sell"); a = nums[0]; b = nums[1]; }
      if(kind == "")
         continue;
      double lo = (b > 0) ? MathMin(a, b) : a, hi = (b > 0) ? MathMax(a, b) : 0;
      if(hi > 0 && hi - lo > 40)
        {
         // "4435-4319.5" -> 4419.5: the far number has a wrong hundreds digit
         if(hi - (lo + 100) >= 0 && hi - (lo + 100) < 40)           lo += 100;
         else if((hi - 100) - lo >= 0 && (hi - 100) - lo < 40)       hi -= 100;
        }
      if(hi > 0 && hi - lo > 40)
         continue;                                          // still not a zone
      string shortBody = CsvSafe(body, 50), longBody = CsvSafe(body, 200);
      if(StringLen(longBody) > 50 && StringGetCharacter(longBody, 50) != ' ')
        {
         int sp = -1;                                       // cut the label at the last space, not inside a number
         for(int q = StringLen(shortBody) - 1; q > 20 && sp < 0; q--)
            if(StringGetCharacter(shortBody, q) == ' ')
               sp = q;
         if(sp > 0)
            shortBody = StringSubstr(shortBody, 0, sp);
        }
      rows += StringFormat("%s;%s;%s;%s;%s\n", kind, Num(lo), hi > 0 ? Num(hi) : "0",
                           CsvSafe(StringFormat("%s %s", hi > 0 ? Num(lo) + "-" + Num(hi) : Num(lo), shortBody), 70), CsvSafe(body, 150));
      string sideTxt = (kind == "pivot") ? "中枢" : (side > 0 ? "买" : "卖");
      list += StringFormat("\n%d. %s %s%s", i + 1, sideTxt, hi > 0 ? Num(lo) + "–" + Num(hi) : "突破线 " + Num(lo),
                           (kind == "buy_mid" || kind == "sell_mid") ? "（medium risk）" : "");
      if(hi > 0)
         nz++;
     }
   if(rows == "")
     {
      if(ni < 2 || (tf == "" && StringFind(low, "analysis") < 0))
         return(false);                                     // not a gameplan after all (the text may still be a signal)
      TgSend(chat, "这条是 GP，但里面没有能读的区，没有写 gameplan.csv。", GpKb());
      return(true);
     }
   datetime when = (origin > 0) ? TimeLocal() - (datetime)MathMax(0, (long)TimeGMT() - origin) : TimeLocal();
   MqlDateTime md;
   TimeToStruct(when, md);
   string day = StringFormat("%04d-%02d-%02d", md.year, md.mon, md.day);
   string head = "# kind;low;high;label;tooltip   (kind: buy, buy_mid, sell, sell_mid, pivot, buy_line, sell_line; high=0 draws a line)\n"
                 + StringFormat("# OrientFX gameplan %s, %s %s (from Telegram %s)\n", day, g_sym, tf, TimeToString(TimeLocal(), TIME_MINUTES));
   // an older gameplan (e.g. yesterday's, forwarded to ask about it) is only archived, not used
   datetime cur = GpFileDate(), newDay = StringToTime(StringFormat("%04d.%02d.%02d", md.year, md.mon, md.day));
   bool older = (cur > 0 && cur <= TimeLocal() && newDay < cur);
   string files[2] = {"gameplans\\" + day + ".csv", "gameplan.csv"};
   bool keptArchive = false;
   for(int f = 0; f < (older ? 1 : 2); f++)
     {
      if(older && FileIsExist(files[f]))
        {
         keptArchive = true;                                 // an existing archive (maybe edited by hand) is kept
         continue;
        }
      int h = FileOpen(files[f], FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(h == INVALID_HANDLE)
        {
         TgSend(chat, StringFormat("写 %s 失败（错误 %d）。", files[f], GetLastError()), "menu");
         return(true);
        }
      FileWriteString(h, head + rows);
      FileClose(h);
     }
   PrintFormat("TradeBot: gameplan %s written, %d zones%s", day, nz, older ? " (older: archived only)" : "");
   if(older)
     {
      bool curOld = TimeLocal() - cur > InpGpMaxDays * 86400;
      TgSend(chat, StringFormat("这是 %s 的 GP，比现在用的（%s）旧，%s%s%s", day, TimeToString(cur, TIME_DATE),
                                keptArchive ? "那天的存档已经有了，没有改。" : "只存了档。",
                                curOld ? StringFormat("现在的 gameplan.csv 已经超过 %d 天，自动 levels 没有可用的 GP：把今天的 GP 帖转发给我。", InpGpMaxDays)
                                       : "自动 levels 还是用 " + TimeToString(cur, TIME_DATE) + " 的区。", list), GpKb());
      return(true);
     }
   bool tooOld = TimeLocal() - newDay > InpGpMaxDays * 86400;
   TgSend(chat, StringFormat("已记下 %s 的 GP（%s），gameplan.csv 已更新：%s\n\n%s", day, tf == "" ? "?" : tf, list,
                             !InpUseGp ? "GP 模式关着（InpUseGp）：这份 GP 只用来画图（拖一次 GamePlanZones），自动 levels 按你每组的第一笔算。" :
                             tooOld ? StringFormat("注意：这份 GP 已经超过 %d 天，自动 levels 不会用它。", InpGpMaxDays)
                                    : StringFormat("在这些区里（±$%.0f）进场的单会自动设 SL / TP。要在图上画出来，拖一次 GamePlanZones。", InpAutoTol)), GpKb());
   AutoLevels();
   return(true);
  }

// A signal pasted or forwarded in Telegram: write levels.csv, then show the levels plan with the confirm
// button (or say to tap 套用 levels after entering). origin: when it was first posted (unix time, 0 = now).
// Returns false when the text is not a signal and was not forwarded (the caller then shows the menu).
bool TrySignal(const long chat, const string text, const long origin, const bool fwd)
  {
   // notes must not make a waiting confirm button stale (a menu would): e.g. a signal and its reasons forwarded together
   string kbNote = (g_pending != "" && TimeLocal() - g_pendingT <= InpConfirmS) ? "" : "menu";
   long age = -1;                                         // seconds since he posted it; -1 = unknown (typed or pasted)
   if(fwd)
     {
      if(origin <= 0)
        {
         TgSend(chat, "不知道这条转发的消息是什么时候发的，没有写 levels。请复制原文发给我。", kbNote);
         return(true);
        }
      age = MathMax(0, (long)TimeGMT() - origin);
     }
   MqlTick tk;
   double price = SymbolInfoTick(g_sym, tk) ? (tk.bid + tk.ask) / 2 : 0;
   double v[];
   int side = 0;
   string fixes = "", why = "";
   bool whole = (age >= 0 && age <= SIG_WHOLE_SHIFT_MIN * 60);
   int r = ParseSignal(text, price, whole, v, side, fixes, why);
   if(r == 0)
     {
      if(!fwd)
         return(false);
      TgSend(chat, "这条不是喊单：要有区间（例如 4154-4159）、SL 和 TP1–TP3。转发的消息只用来识别喊单，不会执行别的操作。", kbNote);
      return(true);
     }
   if(r == 1)
     {
      TgSend(chat, "这条只有方向。等他发区间、SL、TP 的那条，再转发给我。", kbNote);
      return(true);
     }
   if(age > SIG_MAX_POST_MIN * 60)
     {
      TgSend(chat, StringFormat("这条喊单是 %d 分钟前发的（超过 %d 分钟），没有写 levels。", (int)(age / 60), SIG_MAX_POST_MIN), kbNote);
      return(true);
     }
   if(r == 2)
     {
      bool editable = StringFind(why, "发给我") < 0 && StringFind(why, "没有报价") < 0;
      TgSend(chat, "没有写 levels：" + why + (editable ? "。\n可以复制原文，改好后发给我。" : ""), kbNote);
      PrintFormat("TradeBot: signal refused: %s", why);
      return(true);
     }
   if(StringFind(g_sym, "XAU") != 0 && StringFind(g_sym, "GOLD") < 0)
     {
      TgSend(chat, "levels 只用于黄金，现在管理的是 " + g_sym + "。", kbNote);
      return(true);
     }
   datetime created = TimeLocal();                         // the 30-minute window for 套用 levels starts now
   string err = "";
   if(!WriteLevels(side, v, created, err))
     {
      TgSend(chat, "写 levels.csv 失败：" + err, kbNote);
      return(true);
     }
   double lo = MathMin(v[0], v[1]), hi = MathMax(v[0], v[1]);
   string head = StringFormat("已记下喊单：%s %s–%s，SL %s，TP1 %s / TP2 %s / TP3 %s%s。levels.csv 已更新。",
                              side > 0 ? "买" : "卖", Num(lo), Num(hi), Num(v[2]), Num(v[3]), Num(v[4]), Num(v[5]),
                              age >= 0 ? "（他 " + TimeToString(TimeLocal() - (datetime)age, TIME_MINUTES) + " 发的）" : "");
   if(fixes != "")
      head += "\n注意：原文有数字看起来打错了，已按现价改正：" + fixes + "请对照原文核对。";
   PrintFormat("TradeBot: signal %s %s-%s SL %s TP %s/%s/%s%s", side > 0 ? "buy" : "sell", Num(lo), Num(hi),
               Num(v[2]), Num(v[3]), Num(v[4]), Num(v[5]), fixes != "" ? " (repaired: " + fixes + ")" : "");
   if(!InpAutoLevels && InpOrderLevels)
     {
      Pos ps0[];
      if(Collect(ps0) == 0)
        {
         TgSend(chat, head + StringFormat("\n进场后点「套用 levels」：在这个区间里（±$%.0f）的单按喊单的数字设，%s 前有效。", InpAutoTol,
                                          TimeToString(created + InpAutoSigMin * 60, TIME_MINUTES)), "menu");
         return(true);
        }
      g_pending = "";
      string pv = LevelsNow(true), fp0 = "order|" + g_plan;
      if(g_plan == "")
        {
         TgSend(chat, head + "\n\n套用 levels：" + pv, "menu");
         return(true);
        }
      string t2 = head + "\n\n套用 levels 会设成：\n\n" + pv + StringFormat("\n\n已经保本的止损不动。%d 秒内点确认。", InpConfirmS);
      if(TgSend(chat, t2, "confirm:levels"))
        {
         g_pending = "levels";
         g_pendingT = TimeLocal();
         g_pendingFp = fp0;
        }
      return(true);
     }
   if(InpAutoLevels)
     {
      // automatic: positions in the zone get these levels without a tap (now and for the next InpAutoSigMin minutes)
      TgSend(chat, head + StringFormat("\n在区间里（±$%.0f）进场的单会自动设 SL / TP，%s 前有效。", InpAutoTol,
                                       TimeToString(created + InpAutoSigMin * 60, TIME_MINUTES)), "menu");
      AutoLevels();
      return(true);
     }
   string t = "", fp = "";
   g_pending = "";
   if(DoLevels(false, "", t, fp))
     {
      if(TgSend(chat, head + "\n\n" + t, "confirm:levels"))
        {
         g_pending = "levels";
         g_pendingT = TimeLocal();
         g_pendingFp = fp;
        }
     }
   else if(g_lvNoPos)
      TgSend(chat, head + "\n\n" + t + StringFormat("\n进场后在 %s 前点「套用 levels」（30 分钟内）。过了时间，再转发一次同一条喊单（他发出后 %d 分钟内都可以）。",
                                                  TimeToString(created + LV_MAX_AGE_MIN * 60, TIME_MINUTES), SIG_MAX_POST_MIN), "menu");
   else
      TgSend(chat, head + "\n\n" + t, "menu");
   return(true);
  }

// raw: typed text or button data ("p50:<keyboard id>"); stale: read after a gap in the connection
void Handle(const long chat, const string raw, const string cbId, const bool stale)
  {
   string cmd = raw;
   StringTrimLeft(cmd); StringTrimRight(cmd); StringToLower(cmd);
   long seqIn = -1;
   if(cbId != "")
     {
      // button data: "<cmd>:<keyboard id>"
      int colon = StringFind(cmd, ":");
      if(colon > 0)
        {
         seqIn = StringToInteger(StringSubstr(cmd, colon + 1));
         cmd = StringSubstr(cmd, 0, colon);
        }
     }
   else
     {
      // typed: only an exact command - "p50", "/p50" or "/p50@botname"; text with more in it is not a command
      if(StringGetCharacter(cmd, 0) == '/')
        {
         cmd = StringSubstr(cmd, 1);
         int at = StringFind(cmd, "@");
         if(at > 0) cmd = StringSubstr(cmd, 0, at);
        }
      if(StringFind(cmd, " ") >= 0 || StringFind(cmd, ":") >= 0 || StringFind(cmd, "\n") >= 0 || StringFind(cmd, "@") >= 0)
         cmd = "";
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
   if(cbId == "" && (TryGameplan(chat, raw, 0) || TrySignal(chat, raw, 0, false)))
      return;                                          // a pasted signal
   TgSend(chat, "TradeBot（" + g_sym + "，账户 " + Acct() + "）：选一个操作。也可以把他的喊单转发给我。", "menu");
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
   int code = TgCall(method, "", resp, g_primed ? (LONGPOLL + 3) * 1000 : 5000);
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
      long chat = 0, from = 0, origin = 0;
      string text = "", cbId = "";
      bool fwd = false;
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
         if(TopKey(up, "via_bot", ms) >= 0)
           {
            Print("TradeBot: ignored a message sent via a bot");
            continue;
           }
         // a forwarded message is only read as a signal (never as a command); origin = when it was first posted
         int fo = TopKey(up, "forward_origin", ms), fd = TopKey(up, "forward_date", ms);
         fwd = (fo >= 0 || fd >= 0 || TopKey(up, "is_automatic_forward", ms) >= 0);
         if(fo >= 0)
            origin = StringToInteger(JVal(up, "date", TopKey(up, "date", fo)));
         else if(fd >= 0)
            origin = StringToInteger(JVal(up, "forward_date", fd));
         from = ObjId(up, "from", ms);
         chat = ObjId(up, "chat", ms);
         long date = StringToInteger(JVal(up, "date", TopKey(up, "date", ms)));
         text = JVal(up, "text", TopKey(up, "text", ms));
         if(text == "")
            text = JVal(up, "caption", TopKey(up, "caption", ms));   // a signal posted with a picture
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
      if(fwd)
        {
         if(!TryGameplan(chat, text, origin))
            TrySignal(chat, text, origin, true);
        }
      else
         Handle(chat, text, cbId, gap);
     }
   if(!g_primed)
     {
      g_primed = true;
      if(InpChatId != 0)
         TgSend(InpChatId, "TradeBot 已启动：" + g_sym + "，账户 " + Acct() + "。" +
                (InpAutoLevels ? (InpOrderLevels ? "\n自动 levels 开着：下单后几秒内，按每组第一笔进场自动设 SL / TP（转发喊单的话按喊单的数字）。"
                                                  : "\n自动 levels 开着：把他的 GP 帖和喊单转发给我，在区里进场的单会自动设 SL / TP。")
                               : (InpOrderLevels ? "\n下单后点「套用 levels」：按每组第一笔进场算 SL / TP，先给你看，点确认才设。" : "")), "menu");
     }
   if(g_unsent != "" && InpChatId != 0)
     {
      // no new buttons when this poll already sent some or a confirm is waiting (they would go stale)
      string kb = (g_pollKb || g_pending != "") ? "" : "menu";
      g_unsentTries++;
      if(TgSend(InpChatId, "之前没送到的结果：\n" + g_unsent, kb, 3000) || g_unsentTries >= 3)
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
   if(InpAutoTol < 0 || InpSubWidth <= 0 || InpSubSL <= 0 || InpTP1 <= 0 || InpTP2 <= InpTP1 || InpTP3 <= InpTP2 ||
      InpAutoSigMin < 1 || InpGpMaxDays < 1 || InpAutoWarnPct <= 0)
     { Print("TradeBot: check the automatic levels inputs (tolerance >= 0, width / SL > 0, TP1 < TP2 < TP3, minutes / days >= 1)"); return(INIT_PARAMETERS_INCORRECT); }
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
      // no token: nothing runs (a copy without a token has no lock against a second TradeBot, so it must not trade)
      Status(why + (InpAutoLevels ? " | automatic levels need the bot token too" : ""));
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
   // automatic levels run before and after the (up to 5 s) Telegram request, also while Telegram is unreachable
   if(g_token == "")
      return;
   AutoLevels();
   if(IsStopped())
      return;
   if(g_pending != "" && TimeLocal() - g_pendingT > InpConfirmS)
      g_pending = "";
   Poll();
   if(!IsStopped())
      AutoLevels();
   if(!IsStopped())
      NoteFlush();
  }
//+------------------------------------------------------------------+
