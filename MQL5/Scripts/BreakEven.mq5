//+------------------------------------------------------------------+
//| BreakEven.mq5  (v2 - all at once)                                |
//| Moves the stop loss of every open position on this chart's       |
//| symbol to its entry price (plus an optional offset).             |
//| Never loosens an existing stop and leaves take profit unchanged. |
//| v2: all modify requests are sent at once (asynchronously)        |
//| instead of one by one, then it waits for them; anything not yet  |
//| moved is checked again and retried normally.                     |
//+------------------------------------------------------------------+
#property version     "2.00"
#property description "One-key breakeven: SL -> entry price for open positions on this symbol (all at once)."

#include <Trade\Trade.mqh>

input double InpOffset     = 0.0;   // Extra distance beyond entry, in price (0 = exact breakeven)
input bool   InpAllSymbols = false; // true = every symbol, false = only this chart's symbol

void Show(const string msg, const color clr)
  {
   string name = "BE_last";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 82);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, msg);
   ChartRedraw();
  }

// Breakeven stop for the selected position, or "" if it is ok to move; otherwise the reason it is skipped.
// The position must be selected (PositionSelectByTicket / PositionGetTicket) before calling.
string Target(double &newSL)
  {
   string sym     = PositionGetString(POSITION_SYMBOL);
   long   type    = PositionGetInteger(POSITION_TYPE);
   double open    = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl      = PositionGetDouble(POSITION_SL);
   int    digits  = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
   long   lvl     = MathMax(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL));
   double minDist = MathMax((double)lvl * point, point);
   double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);

   if(type == POSITION_TYPE_BUY)
     {
      newSL = NormalizeDouble(open + InpOffset, digits);
      if(bid - newSL < minDist)
         return("price is not far enough above entry yet");
      if(sl != 0.0 && newSL <= sl + point / 2)
         return("stop is already at or above breakeven");
     }
   else
     {
      newSL = NormalizeDouble(open - InpOffset, digits);
      if(newSL - ask < minDist)
         return("price is not far enough below entry yet");
      if(sl != 0.0 && newSL >= sl - point / 2)
         return("stop is already at or below breakeven");
     }
   return("");
  }

bool Mine(const ulong t)
  {
   return(t != 0 && (InpAllSymbols || PositionGetString(POSITION_SYMBOL) == _Symbol));
  }

// true when the position is gone or its stop is at the target (within half a point).
// hit is set only when the stop was actually seen at the target while the position was open,
// so a position that closed before its stop moved is not counted as moved.
bool Done(const ulong t, const double target, bool &hit)
  {
   if(!PositionSelectByTicket(t))
      return(true);                          // gone: finished for loop control only
   double point = SymbolInfoDouble(PositionGetString(POSITION_SYMBOL), SYMBOL_POINT);
   bool ok = MathAbs(PositionGetDouble(POSITION_SL) - target) < point / 2;
   if(ok)
      hit = true;
   return(ok);
  }

void OnStart()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      string m = "BreakEven: Algo Trading is off - no stop was moved. Turn it on and press again.";
      Print(m); Show(m, C'240,138,155'); Alert(m);
      return;
     }

   // 1. decide, for every position, whether its stop moves and to where
   ulong  tk[];
   double target[];
   int    n = 0, skipped = 0, total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!Mine(t))
         continue;
      total++;
      double newSL;
      string why = Target(newSL);
      if(why != "")
        {
         skipped++;
         PrintFormat("BreakEven: #%I64u %s skipped (%s)", t, PositionGetString(POSITION_SYMBOL), why);
         continue;
        }
      ArrayResize(tk, n + 1);
      ArrayResize(target, n + 1);
      tk[n] = t;
      target[n] = newSL;
      n++;
     }
   if(n == 0)
     {
      string m = StringFormat("BreakEven %s: nothing to move (%d open, %d skipped - see Experts tab)",
                              InpAllSymbols ? "all symbols" : _Symbol, total, skipped);
      Print(m); Show(m, C'111,163,255');
      return;
     }

   uint start = GetTickCount();
   CTrade trade;

   // 2. send all modify requests at once; TP is re-read right before each request so it stays unchanged
   trade.SetAsyncMode(true);
   for(int i = 0; i < n; i++)
      if(PositionSelectByTicket(tk[i]))
         trade.PositionModify(tk[i], target[i], PositionGetDouble(POSITION_TP));
   trade.SetAsyncMode(false);

   // per-position outcome: hit = stop seen at target while open; late = skipped when re-checked
   bool hit[], late[];
   ArrayResize(hit, n);
   ArrayResize(late, n);
   ArrayInitialize(hit, false);
   ArrayInitialize(late, false);

   // 3. wait up to 5 s until every stop shows the new price
   int left = n;
   while(GetTickCount() - start < 5000 && !IsStopped())
     {
      Sleep(50);
      left = 0;
      for(int i = 0; i < n; i++)
         if(!Done(tk[i], target[i], hit[i]))
            left++;
      if(left == 0)
         break;
     }

   // 4. anything not moved yet: check again (price may have moved) and retry one by one, normal mode
   string lastErr = "";
   for(int round = 0; round < 2 && left > 0 && !IsStopped(); round++)
     {
      for(int i = 0; i < n; i++)
        {
         if(late[i] || Done(tk[i], target[i], hit[i]))
            continue;
         double newSL;
         string why = Target(newSL);          // position is selected by Done()
         if(why != "")
           {
            PrintFormat("BreakEven: #%I64u not retried (%s)", tk[i], why);
            late[i] = true;                   // counted once, as skipped, not as a failure
            continue;
           }
         target[i] = newSL;
         if(!trade.PositionModify(tk[i], newSL, PositionGetDouble(POSITION_TP)))
           {
            lastErr = StringFormat("%u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
            PrintFormat("BreakEven: #%I64u failed: %s", tk[i], lastErr);
           }
        }
      Sleep(200);
      left = 0;
      for(int i = 0; i < n; i++)
         if(!late[i] && !Done(tk[i], target[i], hit[i]))
            left++;
     }

   // 5. final tally from each position's own state. When the script was stopped (for example the
   //    hotkey pressed again: the new run stops this one), positions not yet confirmed are not failures.
   bool stopped = IsStopped();
   int moved = 0, lateSkip = 0, gone = 0, failed = 0, unchecked = 0;
   for(int i = 0; i < n; i++)
     {
      if(hit[i])
         moved++;
      else if(late[i])
         lateSkip++;
      else if(!PositionSelectByTicket(tk[i]))
         gone++;
      else if(stopped)
         unchecked++;
      else
         failed++;
     }
   bool bad = (failed > 0 || gone > 0);
   string msg = StringFormat("BreakEven %s: moved %d of %d in %.1f s, skipped %d%s%s%s",
                             InpAllSymbols ? "all symbols" : _Symbol, moved, total,
                             (GetTickCount() - start) / 1000.0, skipped + lateSkip,
                             gone > 0 ? StringFormat(" | %d CLOSED before its stop moved", gone) : "",
                             failed > 0 ? StringFormat(" | %d FAILED %s", failed, lastErr) : "",
                             unchecked > 0 ? StringFormat(" | %d not checked: stopped (pressed again?) - the new run handles them", unchecked) : "");
   Print(msg);
   Show(msg, bad ? C'240,138,155' : (unchecked > 0 ? C'240,190,100' : C'111,163,255'));
   if(bad)
      Alert(msg, " - see the Experts tab.");
  }
//+------------------------------------------------------------------+
