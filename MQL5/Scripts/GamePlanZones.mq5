//+------------------------------------------------------------------+
//| GamePlanZones.mq5                                                |
//| Draws the zones listed in MQL5\Files\gameplan.csv on this chart. |
//| Each run first removes the previous GP_ objects, so editing the  |
//| file and running again redraws the plan.                         |
//| Line format: kind;low;high;label;tooltip  (high = 0 -> line)     |
//+------------------------------------------------------------------+
#property version     "1.00"
#property description "Draw the gameplan zones from MQL5/Files/gameplan.csv (replaces earlier GP_ objects)."

input string InpFile        = "gameplan.csv"; // File in MQL5\Files
input int    InpDaysBack    = 7;              // Zones start this many days back
input int    InpDaysForward = 5;              // Zones extend this many days forward

void Colors(const string kind, color &fill, color &text)
  {
   if(kind == "buy" || kind == "buy_line")       { fill = C'19,41,75';  text = C'111,163,255'; }
   else if(kind == "buy_mid")                    { fill = C'15,32,58';  text = C'90,135,215';  }
   else if(kind == "sell" || kind == "sell_line") { fill = C'74,30,40';  text = C'240,138,155'; }
   else if(kind == "sell_mid")                   { fill = C'52,26,34';  text = C'200,120,135'; }
   else                                          { fill = C'61,52,32';  text = C'212,168,75';  }
  }

void Label(const string name, const datetime t, const double price, const string txt, const color clr)
  {
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void OnStart()
  {
   int h = FileOpen(InpFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      Alert("GamePlanZones: cannot open MQL5/Files/", InpFile);
      return;
     }
   ObjectsDeleteAll(0, "GP_");

   datetime now = TimeCurrent();
   datetime t1  = now - (datetime)InpDaysBack * 86400;
   datetime t2  = now + (datetime)InpDaysForward * 86400;
   datetime tl  = now + (datetime)PeriodSeconds() * 3;   // labels sit just right of the last bar
   int n = 0;

   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "" || StringGetCharacter(line, 0) == '#')
         continue;
      string f[];
      if(StringSplit(line, ';', f) < 4)
         continue;
      string kind  = f[0];
      double lo    = StringToDouble(f[1]);
      double hi    = StringToDouble(f[2]);
      string label = f[3];
      string tip   = ArraySize(f) >= 5 ? f[4] : label;
      color  fill, text;
      Colors(kind, fill, text);
      string name = StringFormat("GP_%02d", n++);

      if(hi > lo)
        {
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
         ObjectSetInteger(0, name, OBJPROP_COLOR, fill);
         ObjectSetInteger(0, name, OBJPROP_FILL, true);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
         ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
         Label(name + "_t", tl, hi, label, text);
        }
      else
        {
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, lo);
         ObjectSetInteger(0, name, OBJPROP_COLOR, text);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
         ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
         Label(name + "_t", tl, lo, label, text);
        }
     }
   FileClose(h);
   ChartRedraw();
   PrintFormat("GamePlanZones: drew %d items from %s", n, InpFile);
  }
//+------------------------------------------------------------------+
