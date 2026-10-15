//+------------------------------------------------------------------+
//| CloseAll.mq5  (v2 - fast)                                        |
//| One key press: close every open position on this chart's symbol |
//| at market (buys and sells). No dialog. Pending orders untouched. |
//| v2: all close requests are sent at once (asynchronously, largest |
//| position first) instead of one by one (~0.27 s each), then it    |
//| waits for them; anything still open is retried normally.         |
//+------------------------------------------------------------------+
#property version     "2.00"
#property description "Close all positions on this chart's symbol at market (fast)"

#include <Trade\Trade.mqh>

input bool InpAllSymbols = false;   // true = close positions on every symbol

void Show(const string msg, const color clr)
  {
   string name = "CA_last";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 64);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, msg);
   ChartRedraw();
  }

bool Mine(const ulong t)
  {
   return(t != 0 && (InpAllSymbols || PositionGetString(POSITION_SYMBOL) == _Symbol));
  }

// open positions of ours, largest volume first
int Collect(ulong &tk[], double &vol[], double &pnl)
  {
   int n = 0;
   pnl = 0;
   ArrayResize(tk, 0);
   ArrayResize(vol, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!Mine(t))
         continue;
      ArrayResize(tk, n + 1);
      ArrayResize(vol, n + 1);
      tk[n]  = t;
      vol[n] = PositionGetDouble(POSITION_VOLUME);
      pnl   += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      n++;
     }
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
         if(vol[j] > vol[i])
           {
            ulong a = tk[i]; tk[i] = tk[j]; tk[j] = a;
            double x = vol[i]; vol[i] = vol[j]; vol[j] = x;
           }
   return(n);
  }

void OnStart()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      string m = "CloseAll: Algo Trading is off - nothing was closed. Turn it on or close in the Trade tab.";
      Print(m); Show(m, C'240,138,155'); Alert(m);
      return;
     }
   ulong  tk[];
   double vol[], pnl0;
   int    n0 = Collect(tk, vol, pnl0);
   double lots0 = 0;
   for(int i = 0; i < n0; i++)
      lots0 += vol[i];
   if(n0 == 0)
     {
      Show("CloseAll " + _Symbol + ": nothing open", C'111,163,255');
      return;
     }
   uint start = GetTickCount();
   CTrade trade;
   trade.SetExpertMagicNumber(261008);
   trade.SetDeviationInPoints(500);          // $5 on gold: closing matters more than the exact price

   // 1. fire all close requests at once
   trade.SetAsyncMode(true);
   for(int i = 0; i < n0; i++)
      if(PositionSelectByTicket(tk[i]))
         trade.PositionClose(tk[i]);
   trade.SetAsyncMode(false);

   // 2. wait up to 5 s for them to go
   double pnlLeft;
   int    left = n0;
   while(GetTickCount() - start < 5000)
     {
      Sleep(50);
      left = Collect(tk, vol, pnlLeft);
      if(left == 0)
         break;
     }

   // 3. retry anything still open, one by one, normal (synchronous) mode
   string lastErr = "";
   for(int round = 0; round < 2 && left > 0; round++)
     {
      for(int i = 0; i < left; i++)
         if(PositionSelectByTicket(tk[i]) && !trade.PositionClose(tk[i]))
           {
            lastErr = StringFormat("%u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
            PrintFormat("CloseAll: #%I64u failed: %s", tk[i], lastErr);
           }
      Sleep(200);
      left = Collect(tk, vol, pnlLeft);
     }

   string msg = StringFormat("CloseAll %s: closed %d of %d (%.2f lots, about $%.2f) in %.1f s%s",
                             InpAllSymbols ? "all symbols" : _Symbol, n0 - left, n0, lots0, pnl0,
                             (GetTickCount() - start) / 1000.0,
                             left > 0 ? StringFormat(" | %d STILL OPEN %s", left, lastErr) : "");
   Print(msg);
   Show(msg, left > 0 ? C'240,138,155' : C'111,163,255');
   if(left > 0)
      Alert(msg);
  }
//+------------------------------------------------------------------+
