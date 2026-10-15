//+------------------------------------------------------------------+
//| NewsGuard.mq5                                                    |
//| Manages every open position on this chart's symbol (opened on    |
//| desktop or mobile):                                              |
//|  1. adds a stop loss if the position has none                    |
//|  2. moves the stop to breakeven once profit reaches the trigger, |
//|     or once price reaches the signal's TP1 (stored by            |
//|     ApplyLevels) for positions of that signal                    |
//|  3. alerts when more positions are open than the layer limit     |
//| It never opens trades and never loosens an existing stop.        |
//+------------------------------------------------------------------+
#property version     "1.10"
#property description "Auto stop loss + auto breakeven for open positions on this symbol."

#include <Trade\Trade.mqh>

input double InpPipSize       = 0.10;  // Price value of 1 pip (XAUUSD: 0.10 = 10 cents)
input double InpSLPips        = 100;   // Stop loss in pips, added only when a position has none
input double InpBETriggerPips = 40;    // Move stop to breakeven once profit reaches this many pips
input double InpBEOffsetPips  = 0;     // Pips locked beyond entry at breakeven (0 = exact)
input bool   InpCloseIfPastSL = true;  // No stop and already past the stop distance: close at market
input int    InpMaxLayers     = 4;     // Alert when more positions than this are open (0 = off)
input bool   InpAllSymbols    = false; // false = only this chart's symbol
input double InpTp1MinPips    = 20;    // Breakeven at signal TP1 only if TP1 is at least this many pips beyond the entry

CTrade trade;
ulong  g_tickets[];
uint   g_lastTry[];
int    g_alerted = 0;
uint   g_lastErr = 0;

int OnInit()
  {
   if(InpPipSize <= 0 || InpSLPips <= 0 || InpBETriggerPips <= 0 || InpTp1MinPips < 0)
     {
      Print("NewsGuard: pip size, stop loss and breakeven trigger must be positive, TP1 room not negative");
      return(INIT_PARAMETERS_INCORRECT);
     }
   trade.SetDeviationInPoints(1000);
   // log the settings in use, so reviews (and Claude) can read them from the Experts log
   PrintFormat("NewsGuard settings: pip %.2f | stop %.0f pips (%.2f) | breakeven at +%.0f pips (%.2f), offset %.0f pips | close if past stop %s | alert above %d positions | all symbols %s | TP1 room %.0f pips",
               InpPipSize, InpSLPips, InpSLPips * InpPipSize, InpBETriggerPips, InpBETriggerPips * InpPipSize, InpBEOffsetPips,
               InpCloseIfPastSL ? "yes" : "no", InpMaxLayers, InpAllSymbols ? "yes" : "no", InpTp1MinPips);
   EventSetMillisecondTimer(250);
   Manage();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
void OnTick()  { Manage(); }
void OnTimer() { Manage(); }

bool Mine(const string sym) { return(InpAllSymbols || sym == _Symbol); }

// at most one request per position every 500 ms, so a fast market does not flood the server
bool CanTry(const ulong ticket)
  {
   uint now = GetTickCount();
   int n = ArraySize(g_tickets);
   for(int i = 0; i < n; i++)
      if(g_tickets[i] == ticket)
        {
         if(now - g_lastTry[i] < 500)
            return(false);
         g_lastTry[i] = now;
         return(true);
        }
   ArrayResize(g_tickets, n + 1);
   ArrayResize(g_lastTry, n + 1);
   g_tickets[n] = ticket;
   g_lastTry[n] = now;
   return(true);
  }

void ErrPrint(const ulong ticket, const string sym, const string what)
  {
   if(GetTickCount() - g_lastErr < 1000)
      return;
   g_lastErr = GetTickCount();
   PrintFormat("NewsGuard: #%I64u %s %s failed: %u %s", ticket, sym, what, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

void Modify(const ulong ticket, const string sym, const double sl, const double tp, const string what)
  {
   if(!CanTry(ticket))
      return;
   double tpNow = tp;
   if(PositionSelectByTicket(ticket))
      tpNow = PositionGetDouble(POSITION_TP);   // keep a TP that another tool set a moment ago
   if(trade.PositionModify(ticket, sl, tpNow))
      PrintFormat("NewsGuard: #%I64u %s %s -> %s", ticket, sym, what, DoubleToString(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
   else
      ErrPrint(ticket, sym, what);
  }

bool g_offWarned = false;

// ApplyLevels stores the signal's TP1 and entry zone in terminal global variables
// AL_G_<login>_<symbol>_<B|S>_tp1 / _lo / _hi / _t (time). Groups older than 6 h are ignored.
string GroupBase(const string sym, const bool isBuy)
  {
   return("AL_G_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + sym + (isBuy ? "_B_" : "_S_"));
  }

// TP1 of the current signal in this direction (0 = none); lo/hi = entry zone incl. tolerance (0 = no zone)
double GroupTp1(const string sym, const bool isBuy, double &lo, double &hi)
  {
   lo = 0;
   hi = 0;
   string base = GroupBase(sym, isBuy);
   if(!GlobalVariableCheck(base + "tp1") || !GlobalVariableCheck(base + "t"))
      return(0);
   if(TimeCurrent() - (datetime)GlobalVariableGet(base + "t") > 6 * 3600)
      return(0);
   if(GlobalVariableCheck(base + "lo"))
      lo = GlobalVariableGet(base + "lo");
   if(GlobalVariableCheck(base + "hi"))
      hi = GlobalVariableGet(base + "hi");
   return(GlobalVariableGet(base + "tp1"));
  }

// no position left in this direction: forget the signal, so a later trade is not moved to breakeven at an old TP1
void DropGroup(const string sym, const bool isBuy)
  {
   string base = GroupBase(sym, isBuy);
   if(!GlobalVariableCheck(base + "t"))
      return;
   if(TimeCurrent() - (datetime)GlobalVariableGet(base + "t") < 60)
      return;
   GlobalVariableDel(base + "tp1");
   GlobalVariableDel(base + "lo");
   GlobalVariableDel(base + "hi");
   GlobalVariableDel(base + "t");
   GlobalVariablesFlush();
   PrintFormat("NewsGuard: no %s positions left on %s - signal TP1 cleared", isBuy ? "buy" : "sell", sym);
  }

void Manage()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Comment("NewsGuard  |  ALGO TRADING IS OFF - stops and breakeven are NOT being managed");
      if(!g_offWarned)
        {
         Alert("NewsGuard: Algo Trading is off - stops and breakeven are not being managed.");
         g_offWarned = true;
        }
      return;
     }
   g_offWarned = false;
   double slDist = InpSLPips * InpPipSize;
   double beTrig = InpBETriggerPips * InpPipSize;
   double beOff  = InpBEOffsetPips * InpPipSize;
   int    count  = 0;
   int    nBuy   = 0, nSell = 0;   // positions on this chart's symbol

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!Mine(sym))
         continue;
      count++;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(sym == _Symbol)
        {
         if(isBuy) nBuy++;
         else      nSell++;
        }
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
      double minD  = MathMax((double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt, pt);
      double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0)
         continue;
      // profit measured at the price the position would close at (bid for buys, ask for sells)
      double profit = isBuy ? bid - open : open - ask;

      // 1. breakeven once the trigger is reached, or once price reaches the signal's TP1 - the TP1 rule only
      //    for positions entered inside the signal's zone with TP1 a real distance beyond the entry
      double zLo, zHi;
      double gTp1    = GroupTp1(sym, isBuy, zLo, zHi);
      double room    = isBuy ? gTp1 - open : open - gTp1;
      bool   inGroup = gTp1 > 0 && room >= InpTp1MinPips * InpPipSize && (zLo <= 0 || (open >= zLo && open <= zHi));
      bool   atTp1   = inGroup && (isBuy ? bid >= gTp1 : ask <= gTp1);
      if(profit >= beTrig || atTp1)
        {
         double be      = NormalizeDouble(isBuy ? open + beOff : open - beOff, dg);
         bool   tighter = (sl == 0.0) || (isBuy ? be > sl + pt / 2 : be < sl - pt / 2);
         bool   valid   = isBuy ? (bid - be >= minD) : (be - ask >= minD);
         if(tighter && valid)
           {
            Modify(ticket, sym, be, tp, "breakeven");
            continue;
           }
        }

      // 2. a position without a stop gets the standard stop
      if(sl == 0.0)
        {
         double s     = NormalizeDouble(isBuy ? open - slDist : open + slDist, dg);
         bool   valid = isBuy ? (bid - s >= minD) : (s - ask >= minD);
         if(valid)
            Modify(ticket, sym, s, tp, "stop loss");
         else
            if(InpCloseIfPastSL && -profit >= slDist && CanTry(ticket))
              {
               if(trade.PositionClose(ticket))
                  PrintFormat("NewsGuard: #%I64u %s closed, already past the %.0f-pip stop", ticket, sym, InpSLPips);
               else
                  ErrPrint(ticket, sym, "close");
              }
        }
     }

   if(InpMaxLayers > 0 && count > InpMaxLayers)
     {
      if(count > g_alerted)
        {
         Alert(StringFormat("NewsGuard: %d positions open on %s, limit is %d", count, _Symbol, InpMaxLayers));
         g_alerted = count;
        }
     }
   else
      g_alerted = 0;

   if(nBuy == 0)
      DropGroup(_Symbol, true);
   if(nSell == 0)
      DropGroup(_Symbol, false);
   double l, h;
   double b1 = GroupTp1(_Symbol, true, l, h), s1 = GroupTp1(_Symbol, false, l, h);
   string grp = "";
   if(b1 > 0) grp += "  |  buy signal: breakeven at TP1 " + DoubleToString(b1, _Digits);
   if(s1 > 0) grp += "  |  sell signal: breakeven at TP1 " + DoubleToString(s1, _Digits);

   Comment(StringFormat("NewsGuard  |  stop %.0f pips (%.2f)  |  breakeven at +%.0f pips (%.2f)  |  positions %d / %d%s",
                        InpSLPips, slDist, InpBETriggerPips, beTrig, count, InpMaxLayers, grp));
  }
//+------------------------------------------------------------------+
