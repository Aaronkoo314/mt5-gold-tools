//+------------------------------------------------------------------+
//| ApplyLevels.mq5  (v2.1)                                          |
//| One key press: set the stop loss and TP1/TP2/TP3 of the open     |
//| positions on this chart's symbol in the signal's direction, from |
//| MQL5/Files/levels.csv (written by Claude from the zone the user  |
//| sends after entering). Shows a preview and asks before changing. |
//|  - one SL price for all positions; a stop that already sits at   |
//|    or beyond the entry (breakeven / profit lock) is kept, any    |
//|    other stop (e.g. NewsGuard's temporary one) is replaced       |
//|  - TPs by entry: worst entries TP1, middle TP2, best TP3 (shares |
//|    from the file); a TP that price has passed, or that is not    |
//|    beyond that position's own entry, moves to the next TP; if    |
//|    none fits, the position keeps its current TP                  |
//|  - optional zone filter: positions entered far outside the zone  |
//|    are left alone and listed                                     |
//|  - stores the signal's TP1 so NewsGuard moves the group to       |
//|    breakeven when TP1 is reached                                 |
//| It never opens or closes positions.                              |
//+------------------------------------------------------------------+
#property version     "2.10"
#property description "Set SL and TP1-TP3 for the open positions from levels.csv (with preview)"

#include <Trade\Trade.mqh>

struct ALConfig
  {
   int      side;        // +1 buy, -1 sell
   double   sl;
   double   tp[3];
   double   share1;      // fraction of positions on TP1
   double   share2;      // fraction on TP2 (rest TP3)
   double   maxRiskPct;  // warn above this % of balance (0 = off)
   int      maxAgeMin;
   datetime created;     // local PC time the file was written
   double   zoneLo, zoneHi, zoneTol;   // optional zone filter (0 = off)
   double   minSlGap;    // SL must be at least this far from the price
   double   maxSlDist;   // and at most this far from the average entry
   bool     confirm;     // ask before applying
  };

void ALShow(const string msg, const color clr)
  {
   string name = "AL_last";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 44);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, msg);
   ChartRedraw();
  }

void ALRefuse(const string why)
  {
   string msg = "ApplyLevels: " + why + " - nothing was changed.";
   Print(msg);
   ALShow(msg, C'240,138,155');
   Alert(msg);
  }

bool ALLoad(ALConfig &c, string &err)
  {
   c.side = 0; c.sl = 0; c.tp[0] = 0; c.tp[1] = 0; c.tp[2] = 0;
   c.share1 = 0.25; c.share2 = 0.45; c.maxRiskPct = 0; c.maxAgeMin = 30; c.created = 0;
   c.zoneLo = 0; c.zoneHi = 0; c.zoneTol = 3.0; c.minSlGap = 2.0; c.maxSlDist = 20.0; c.confirm = true;
   ResetLastError();
   int h = FileOpen("levels.csv", FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     {
      err = StringFormat("cannot open MQL5/Files/levels.csv (error %d)", GetLastError());
      return(false);
     }
   int seen = 0;
   while(!FileIsEnding(h))
     {
      string chunk = FileReadString(h);
      string lines[];
      int n = StringSplit(chunk, '\n', lines);
      for(int i = 0; i < n; i++)
        {
         string line = lines[i];
         int hash = StringFind(line, "#");
         if(hash >= 0)
            line = StringSubstr(line, 0, hash);
         StringTrimLeft(line);
         StringTrimRight(line);
         if(line == "")
            continue;
         string kv[];
         if(StringSplit(line, '=', kv) != 2)
           { FileClose(h); err = "bad line in levels.csv: " + line; return(false); }
         string k = kv[0], v = kv[1];
         StringTrimLeft(k); StringTrimRight(k); StringToLower(k);
         StringTrimLeft(v); StringTrimRight(v);
         string vl = v;
         StringToLower(vl);
         if(k == "side")
           {
            if(vl == "buy") c.side = 1;
            else if(vl == "sell") c.side = -1;
            else { FileClose(h); err = "side must be buy or sell"; return(false); }
            seen |= 1;
           }
         else if(k == "created")
           {
            c.created = StringToTime(v);
            if(c.created <= 0) { FileClose(h); err = "created must look like 2026.10.07 13:05"; return(false); }
            seen |= 2;
           }
         else
           {
            double x = StringToDouble(v);
            if(x == 0.0 && v != "0" && v != "0.0")
              { FileClose(h); err = "not a number: " + line; return(false); }
            if(k == "sl")                { c.sl = x;        seen |= 4;  }
            else if(k == "tp1")          { c.tp[0] = x;     seen |= 8;  }
            else if(k == "tp2")          { c.tp[1] = x;     seen |= 16; }
            else if(k == "tp3")          { c.tp[2] = x;     seen |= 32; }
            else if(k == "tp1_share")    { c.share1 = x; }
            else if(k == "tp2_share")    { c.share2 = x; }
            else if(k == "max_risk_pct") { c.maxRiskPct = x; }
            else if(k == "max_age_min")  { c.maxAgeMin = (int)x; }
            else if(k == "zone_lo")      { c.zoneLo = x; }
            else if(k == "zone_hi")      { c.zoneHi = x; }
            else if(k == "zone_tol")     { c.zoneTol = x; }
            else if(k == "min_sl_gap")   { c.minSlGap = x; }
            else if(k == "max_sl_dist")  { c.maxSlDist = x; }
            else if(k == "confirm")      { c.confirm = (x != 0); }
            else { FileClose(h); err = "unknown setting: " + k; return(false); }
           }
        }
     }
   FileClose(h);
   if(seen != 63)
     { err = "levels.csv must set side, created, sl, tp1, tp2 and tp3"; return(false); }
   if(c.sl <= 0 || c.tp[0] <= 0 || c.tp[1] <= 0 || c.tp[2] <= 0)
     { err = "sl and tp1-tp3 must be prices above 0"; return(false); }
   bool geo = (c.side < 0) ? (c.sl > c.tp[0] && c.tp[0] > c.tp[1] && c.tp[1] > c.tp[2])
                           : (c.sl < c.tp[0] && c.tp[0] < c.tp[1] && c.tp[1] < c.tp[2]);
   if(!geo)
     { err = (c.side < 0) ? "for a sell, need sl > tp1 > tp2 > tp3" : "for a buy, need sl < tp1 < tp2 < tp3"; return(false); }
   if(c.share1 < 0 || c.share2 < 0 || c.share1 + c.share2 > 1.0 + 1e-9)
     { err = "tp1_share and tp2_share must be >= 0 and add up to 1 or less"; return(false); }
   if((c.zoneLo > 0) != (c.zoneHi > 0) || (c.zoneLo > 0 && c.zoneLo >= c.zoneHi))
     { err = "zone_lo and zone_hi must both be set (lo < hi) or both be 0"; return(false); }
   return(true);
  }

// loss in account currency if the position is closed at price 'stop' (0 if that is a profit)
double ALLoss(const string sym, const bool isBuy, const double vol, const double entry, const double stop)
  {
   double p = 0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, entry, stop, p))
      p = (isBuy ? stop - entry : entry - stop) * vol * SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   return(MathMax(0.0, -p));
  }

void OnStart()
  {
   string sym = _Symbol;
   if(StringFind(sym, "XAU") != 0 && StringFind(sym, "GOLD") < 0)
     { ALRefuse("levels are for gold, this chart is " + sym); return; }
   ALConfig c;
   string err = "";
   if(!ALLoad(c, err))
     { ALRefuse(err); return; }
   long ageMin = (long)(TimeLocal() - c.created) / 60;
   if(c.maxAgeMin > 0 && (ageMin > c.maxAgeMin || ageMin < -5))
     { ALRefuse(StringFormat("levels.csv is %d minutes old (limit %d) - send the zone again", (int)ageMin, c.maxAgeMin)); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { ALRefuse("Algo Trading is off"); return; }

   MqlTick t;
   if(!SymbolInfoTick(sym, t) || t.ask <= 0 || t.bid <= 0)
     { ALRefuse("no price for " + sym); return; }
   int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minD  = MathMax((double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt, pt);
   bool   isBuy = c.side > 0;
   double sl    = NormalizeDouble(c.sl, dg);
   double tps[3];
   for(int k = 0; k < 3; k++)
      tps[k] = NormalizeDouble(c.tp[k], dg);

   // SL: right side of the price and not suspiciously close (a typo like 4127 for 4172 is caught here)
   double gap = isBuy ? t.bid - sl : sl - t.ask;
   if(gap < MathMax(minD, c.minSlGap))
     { ALRefuse(StringFormat("SL %s is only %.2f from the price (%s) - check the levels", DoubleToString(sl, dg), gap, DoubleToString(isBuy ? t.bid : t.ask, dg))); return; }
   bool tpPassed[3];
   for(int k = 0; k < 3; k++)
      tpPassed[k] = isBuy ? (tps[k] - t.bid < minD) : (t.ask - tps[k] < minD);

   // collect the positions in the signal's direction (and inside the zone, if one is given)
   ulong  tk[];
   double entry[], vol[];
   int    n = 0, outside = 0;
   string outsideTxt = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) != isBuy)
         continue;
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(c.zoneLo > 0 && (op < c.zoneLo - c.zoneTol || op > c.zoneHi + c.zoneTol))
        {
         outside++;
         outsideTxt += " " + DoubleToString(op, dg);
         continue;
        }
      ArrayResize(tk, n + 1); ArrayResize(entry, n + 1); ArrayResize(vol, n + 1);
      tk[n] = ticket; entry[n] = op; vol[n] = PositionGetDouble(POSITION_VOLUME);
      n++;
     }
   if(n == 0)
     { ALRefuse(StringFormat("no open %s positions on %s%s", isBuy ? "buy" : "sell", sym, outside > 0 ? " inside the zone" : "")); return; }

   double avgEntry = 0, totVol = 0;
   for(int i = 0; i < n; i++) { avgEntry += entry[i] * vol[i]; totVol += vol[i]; }
   avgEntry /= totVol;
   if(MathAbs(avgEntry - sl) > c.maxSlDist)
     { ALRefuse(StringFormat("SL %s is $%.2f from the average entry %s (limit %.0f) - check the levels", DoubleToString(sl, dg), MathAbs(avgEntry - sl), DoubleToString(avgEntry, dg), c.maxSlDist)); return; }

   // sort worst entry first (sell: lowest entry, buy: highest entry)
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
         if(isBuy ? (entry[j] > entry[i]) : (entry[j] < entry[i]))
           {
            ulong a = tk[i]; tk[i] = tk[j]; tk[j] = a;
            double x = entry[i]; entry[i] = entry[j]; entry[j] = x;
            x = vol[i]; vol[i] = vol[j]; vol[j] = x;
           }
   int n1 = (int)MathRound(c.share1 * n);
   int n2 = (int)MathRound((c.share1 + c.share2) * n) - n1;
   if(n1 + n2 > n)
      n2 = n - n1;

   // ---- plan: target TP per position (TP must be still ahead AND beyond that position's entry)
   int    tpIdx[];
   ArrayResize(tpIdx, n);
   int    cnt[4] = {0, 0, 0, 0};               // TP1, TP2, TP3, keeps its TP
   double planRisk = 0;
   double tpRoom = MathMax(minD, 0.30);        // a TP must be at least $0.30 beyond the position's entry
   for(int i = 0; i < n; i++)
     {
      int k = (i < n1) ? 0 : (i < n1 + n2 ? 1 : 2);
      while(k < 3 && (tpPassed[k] || (isBuy ? tps[k] < entry[i] + tpRoom : tps[k] > entry[i] - tpRoom)))
         k++;
      tpIdx[i] = k;
      cnt[k]++;
      planRisk += ALLoss(sym, isBuy, vol[i], entry[i], sl);
     }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = bal > 0 ? planRisk / bal * 100.0 : 0;
   string preview = StringFormat("%s %d positions on %s (avg entry %s)\n\nSL %s  ($%.2f from the price)\nTP1 %s x%d   TP2 %s x%d   TP3 %s x%d   keep own TP x%d\n\nLoss if every stop is hit: about $%.0f = %.1f%% of balance%s%s\n\nApply?",
                                 isBuy ? "BUY" : "SELL", n, sym, DoubleToString(avgEntry, dg), DoubleToString(sl, dg), gap,
                                 DoubleToString(tps[0], dg), cnt[0], DoubleToString(tps[1], dg), cnt[1], DoubleToString(tps[2], dg), cnt[2], cnt[3],
                                 planRisk, pct,
                                 (c.maxRiskPct > 0 && pct > c.maxRiskPct) ? StringFormat("  - ABOVE your %.0f%% limit", c.maxRiskPct) : "",
                                 outside > 0 ? StringFormat("\n%d position(s) outside the zone are left alone:%s", outside, outsideTxt) : "");
   if(c.confirm && MessageBox(preview, "ApplyLevels", MB_OKCANCEL | MB_ICONQUESTION) != IDOK)
     {
      ALShow("ApplyLevels: cancelled - nothing was changed.", C'212,168,75');
      return;
     }

   // ---- the preview may have stayed open a while: check the price again
   if(c.confirm)
     {
      if(!SymbolInfoTick(sym, t) || t.ask <= 0 || t.bid <= 0)
        { ALRefuse("no price for " + sym); return; }
      gap = isBuy ? t.bid - sl : sl - t.ask;
      if(gap < MathMax(minD, c.minSlGap))
        { ALRefuse(StringFormat("price moved while the preview was open - SL is now only %.2f away. Press again", gap)); return; }
      for(int i = 0; i < n; i++)
         if(tpIdx[i] < 3 && (isBuy ? tps[tpIdx[i]] - t.bid < minD : t.ask - tps[tpIdx[i]] < minD))
           { ALRefuse(StringFormat("price moved while the preview was open - TP%d %s is already reached. Press again", tpIdx[i] + 1, DoubleToString(tps[tpIdx[i]], dg))); return; }
     }

   // ---- apply
   CTrade trade;
   trade.SetExpertMagicNumber(261007);
   int    ok = 0, unchanged = 0, kept = 0, failed = 0;
   int    applied[4] = {0, 0, 0, 0};           // what actually got set (cnt[] is only the plan)
   double risk = 0;
   string failTxt = "";
   for(int i = 0; i < n; i++)
     {
      if(!PositionSelectByTicket(tk[i]))
        { failed++; failTxt += StringFormat(" #%I64u gone;", tk[i]); continue; }
      double cur   = PositionGetDouble(POSITION_SL);   // re-read: another tool may have moved it to breakeven
      double curTp = PositionGetDouble(POSITION_TP);
      bool   lockIn = cur > 0 && (isBuy ? (cur > sl && cur >= entry[i]) : (cur < sl && cur <= entry[i]));
      double newSl = lockIn ? cur : sl;
      double tp    = (tpIdx[i] < 3) ? tps[tpIdx[i]] : curTp;
      if(MathAbs(newSl - cur) < pt / 2 && MathAbs(tp - curTp) < pt / 2)
        {
         unchanged++;
         applied[tpIdx[i]]++;
         if(lockIn) kept++;
         risk += ALLoss(sym, isBuy, vol[i], entry[i], newSl);
         continue;
        }
      if(trade.PositionModify(tk[i], newSl, tp) || trade.ResultRetcode() == TRADE_RETCODE_NO_CHANGES)
        {
         ok++;
         applied[tpIdx[i]]++;
         if(lockIn) kept++;
         risk += ALLoss(sym, isBuy, vol[i], entry[i], newSl);
        }
      else
        {
         failed++;
         failTxt += StringFormat(" #%I64u %u %s;", tk[i], trade.ResultRetcode(), trade.ResultRetcodeDescription());
         PrintFormat("ApplyLevels: #%I64u failed: %u %s", tk[i], trade.ResultRetcode(), trade.ResultRetcodeDescription());
         // count what is actually there now
         if(PositionSelectByTicket(tk[i]))
           {
            double s2 = PositionGetDouble(POSITION_SL);
            risk += (s2 > 0) ? ALLoss(sym, isBuy, vol[i], entry[i], s2) : 0;
            if(s2 <= 0) failTxt += " (that position has NO stop)";
           }
        }
     }

   // remember the signal's TP1 and zone, so NewsGuard moves this group (only) to breakeven at TP1.
   // NewsGuard deletes these once no position in this direction is left.
   if(ok + unchanged > 0)
     {
      string base = "AL_G_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + sym + (isBuy ? "_B_" : "_S_");
      GlobalVariableSet(base + "tp1", tps[0]);
      GlobalVariableSet(base + "lo", c.zoneLo > 0 ? c.zoneLo - c.zoneTol : 0);
      GlobalVariableSet(base + "hi", c.zoneLo > 0 ? c.zoneHi + c.zoneTol : 0);
      GlobalVariableSet(base + "t", (double)TimeCurrent());
      GlobalVariablesFlush();
     }

   pct = bal > 0 ? risk / bal * 100.0 : 0;
   string msg = StringFormat("ApplyLevels %s: %d set, %d already right, %d failed of %d | SL %s (%d kept at breakeven or better) | TP1 x%d, TP2 x%d, TP3 x%d, own TP x%d | loss at all stops $%.0f = %.1f%%%s",
                             isBuy ? "BUY" : "SELL", ok, unchanged, failed, n, DoubleToString(sl, dg), kept,
                             applied[0], applied[1], applied[2], applied[3], risk, pct,
                             outside > 0 ? StringFormat(" | %d outside the zone left alone", outside) : "");
   Print(msg);
   bool warn = failed > 0 || (c.maxRiskPct > 0 && pct > c.maxRiskPct);
   ALShow(msg, warn ? C'240,138,155' : C'111,163,255');
   if(failed > 0)
      Alert(msg, " | failed:", failTxt);
   else
      if(c.maxRiskPct > 0 && pct > c.maxRiskPct)
         Alert(msg, StringFormat(" | above your %.0f%% limit", c.maxRiskPct));
  }
//+------------------------------------------------------------------+
