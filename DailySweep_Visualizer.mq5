//+------------------------------------------------------------------+
//|                                    DailySweep_Visualizer.mq5     |
//|   Visual-only indicator for the "Daily Sweep" (SFP) strategy.    |
//|   Draws the previous-session PDH/PDL, the intraday swing points, |
//|   the watched liquidity level, the sweep, the reclaim/entry, and |
//|   the SL/TP zones for whichever exit mode is selected.           |
//|                                                                    |
//|   v1.20: fixed a same-candle sweep+reclaim bug - a single candle    |
//|   that both sweeps the level AND closes back through it (his own   |
//|   diagram's classic case) was being missed, since the old logic     |
//|   only checked for reclaim starting the NEXT bar after a sweep.     |
//|                                                                    |
//|   v1.10: the watched level is now searched across THREE sources  |
//|   - the previous bias-TF bar's high/low, a confirmed swing point  |
//|   on the bias TF itself (his daily "Identification" swing point,  |
//|   which can sit several bars back), and an intraday swing point   |
//|   on the execution TF - most recent wins. v1.00 only searched the |
//|   execution TF and mislabeled a same-session range as PDH/PDL.    |
//|                                                                    |
//|   Rule provenance (kept explicit per project convention):         |
//|   - Bias (2-candle HH/HL vs LH/LL comparison), PDH/PDL, the       |
//|     3-candle swing definition, the sweep+reclaim entry, and the   |
//|     liquidity-target / session-close / partial+BE+trail exits     |
//|     are all directly from the source video.                      |
//|   - The sweep/SL buffer size, the "most recent qualifying level   |
//|     wins" tie-break, and the single-attempt-per-session rule are  |
//|     OUR definitions, added where the video left a gray area.      |
//|                                                                    |
//|   NO trading, NO orders, NO trade management - visuals only.      |
//+------------------------------------------------------------------+
#property copyright "Elite Quant"
#property version   "1.81"
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1
#property indicator_label1  "DSW"
#property indicator_type1   DRAW_NONE

//--- Inputs
enum ENUM_TRADER_TYPE
{
   TT_CUSTOM,        // Use the manual Bias/Execution/Level timeframes below
   TT_SWING,         // Weekly bias -> 4H entry (Weekly levels)
   TT_SHORT_TERM,    // Daily bias -> 1H entry (Daily levels)
   TT_DAY_TRADING_1, // 4H bias -> 15M entry (Daily levels)
   TT_DAY_TRADING_2  // 1H bias -> 5M entry (Daily levels)
};
input ENUM_TRADER_TYPE InpTraderType   = TT_SHORT_TERM;  // Pick a preset, or Custom to set the three timeframes yourself
input ENUM_TIMEFRAMES  InpBiasTF        = PERIOD_D1;    // Custom mode only: Bias Timeframe
input ENUM_TIMEFRAMES  InpExecTF        = PERIOD_H1;    // Custom mode only: Execution Timeframe
input ENUM_TIMEFRAMES  InpLevelTF       = PERIOD_D1;    // Custom mode only: Level Timeframe (source of PDH/PDL)
input string           InpSessionStart  = "16:30";      // NY Session Start (HH:MM, broker server time)
input string           InpSessionEnd    = "23:00";      // NY Session End (HH:MM, broker server time)
input int              InpHistoryDays   = 60;           // How Many Past Sessions To Draw
input int              InpSwingLookbackBars = 10;       // OURS: how many g_biasTF bars back to search for a swing point
input int              InpLevelUpdateCooldownBars = 5;  // OURS: minimum execTF bars before a fresh swing can supersede the level (dampens chasing on fast timeframes)

input double           InpSLBufferPoints = 20.0;        // OURS: SL buffer beyond the sweep extreme, in points

enum ENUM_TP_MODE
{
   TP_LIQUIDITY,      // Ride to the opposite session extreme (his stated default)
   TP_SESSION_CLOSE,  // Force-close at session end, no price target (his "manage before the handoff")
   TP_PARTIAL_TRAIL   // Partial at first new intraday swing in favor, then BE, then ride to target (his live-trade example)
};
input ENUM_TP_MODE     InpTPMode         = TP_LIQUIDITY;
input double           InpPartialClosePct = 50.0;       // % closed at the partial level in TP_PARTIAL_TRAIL mode

input bool             InpShowSwingMarkers = true;
input color            InpSessionBoxClr  = clrLightSkyBlue;
input color            InpLevelClr       = clrDodgerBlue;
input color            InpBullColor      = clrLime;
input color            InpBearColor      = clrRed;
input color            InpNoBiasClr      = clrGray;
input color            InpSweptColor     = clrOrange;
input color            InpRiskZoneClr    = clrMistyRose;
input color            InpRewardZoneClr  = clrPaleGreen;
input color            InpSLHitClr       = clrCrimson;
input color            InpTPHitClr       = clrForestGreen;
input color            InpPartialClr     = clrKhaki;
input int              InpLineWidth      = 2;

//--- State machine constants
#define DSW_STATE_WATCHING 0   // watching for a sweep of the level
#define DSW_STATE_SWEPT    1   // level swept, awaiting reclaim
#define DSW_STATE_ACTIVE   2   // trade live

//--- Globals
double   DummyBuffer[];
datetime g_lastEntryBarTime = 0;
ENUM_TIMEFRAMES g_biasTF, g_execTF, g_levelTF; // resolved once from InpTraderType (or Custom inputs)

void ResolveTraderType()
{
   switch(InpTraderType)
   {
      case TT_SWING:         g_biasTF = PERIOD_W1; g_execTF = PERIOD_H4;  g_levelTF = PERIOD_W1; break;
      case TT_SHORT_TERM:    g_biasTF = PERIOD_D1; g_execTF = PERIOD_H1;  g_levelTF = PERIOD_D1; break;
      case TT_DAY_TRADING_1: g_biasTF = PERIOD_H4; g_execTF = PERIOD_M15; g_levelTF = PERIOD_D1; break;
      case TT_DAY_TRADING_2: g_biasTF = PERIOD_H1; g_execTF = PERIOD_M5;  g_levelTF = PERIOD_D1; break;
      default:               g_biasTF = InpBiasTF; g_execTF = InpExecTF; g_levelTF = InpLevelTF; break; // Custom
   }
}

struct SessionInfo
{
   bool     valid;        // bias != 0 (a trade may be attempted)
   int      bias;         // +1 bullish (watch a low), -1 bearish (watch a high), 0 = none
   double   pdh, pdl;      // previous session's high/low
   bool     haveLevel;
   double   levelPrice;
   datetime levelTime;
   bool     levelIsHigh;   // true = watching a swept HIGH (bearish), false = swept LOW (bullish)
   string   levelSource;    // "Prev Bias TF" / "Bias TF Swing" / "Intraday Swing" - for on-chart transparency
   datetime dayStart;
   datetime sessStart, sessEnd;
   datetime prevSessStart, prevSessEnd;
};

//+------------------------------------------------------------------+
int OnInit()
{
   ResolveTraderType();
   SetIndexBuffer(0, DummyBuffer, INDICATOR_DATA);
   ArraySetAsSeries(DummyBuffer, false);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "DSW_");
}

//+------------------------------------------------------------------+
//| Find the shift of the last g_biasTF bar that has FULLY CLOSED   |
//| as of 'asOf'. iBarShift alone returns whichever bar's OPEN time  |
//| is at/before asOf, which - for an intraday session start vs a    |
//| Daily (or higher) bias TF - is always the CURRENT day's own      |
//| still-forming bar, not the prior closed one.                     |
//+------------------------------------------------------------------+
int GetClosedBarShift(ENUM_TIMEFRAMES tf, datetime asOf)
{
   int shift = iBarShift(_Symbol, tf, asOf, false);
   if(shift < 0) return -1;
   datetime barOpen = iTime(_Symbol, tf, shift);
   int periodSecs = PeriodSeconds(tf);
   if(barOpen + periodSecs > asOf) shift++;
   return shift;
}

//+------------------------------------------------------------------+
int TimeStrToSeconds(string hhmm)
{
   string parts[];
   int n = StringSplit(hhmm, ':', parts);
   if(n < 2) return 0;
   return ((int)StringToInteger(parts[0]) * 3600) + ((int)StringToInteger(parts[1]) * 60);
}

//+------------------------------------------------------------------+
//| Is bar 'shift' on the given timeframe a confirmed 3-bar swing?    |
//| Same 3-candle pattern he uses on the bias TF ("Bearish/Bullish    |
//| Swing Point") and the execution TF (intraday swings).             |
//+------------------------------------------------------------------+
bool IsSwingHighTF(ENUM_TIMEFRAMES tf, int shift)
{
   double h0 = iHigh(_Symbol, tf, shift);
   double h1 = iHigh(_Symbol, tf, shift + 1);  // older neighbor
   double hM1 = iHigh(_Symbol, tf, shift - 1); // newer neighbor
   return (h0 > h1 && h0 > hM1);
}

bool IsSwingLowTF(ENUM_TIMEFRAMES tf, int shift)
{
   double l0 = iLow(_Symbol, tf, shift);
   double l1 = iLow(_Symbol, tf, shift + 1);
   double lM1 = iLow(_Symbol, tf, shift - 1);
   return (l0 < l1 && l0 < lM1);
}

//+------------------------------------------------------------------+
//| OUR swing rule for the EXECUTION timeframe ONLY. The bias-TF     |
//| swing search above (his stated 3-candle test) is untouched - this|
//| is a separate, stricter rule built from watching his actual      |
//| trades, not stated on camera:                                    |
//|  - A push of >=2 consecutive candles in the push direction       |
//|  - The first opposite candle after it (the "anchor") sets a      |
//|    ceiling/floor at the ANCHOR'S OWN OPEN                        |
//|  - Any number of noise candles can follow, either direction, as  |
//|    long as none CLOSES past that ceiling/floor                   |
//|  - Confirmed the instant a same-direction-as-anchor candle       |
//|    CLOSES past the ANCHOR'S OWN CLOSE (not its low/high, not     |
//|    whatever the last noise candle did)                           |
//|  - Invalidated (reset) if any candle closes past the ceiling/    |
//|    floor before confirmation                                      |
//| Swing price = the extreme reached across the push + the anchor.  |
//| Scans the whole range and returns every qualifying swing found - |
//| callers wanting "the most recent" take the last array entry,     |
//| callers wanting "the first after entry" take the first entry.    |
//+------------------------------------------------------------------+
int FindQualifiedSwings(ENUM_TIMEFRAMES tf, int fromShift, int toShift, bool wantHigh,
                         datetime &outTimes[], double &outPrices[])
{
   ArrayResize(outTimes, 0);
   ArrayResize(outPrices, 0);
   if(fromShift < toShift) return 0;

   int STATE_SEEKING = 0, STATE_IN_PUSH = 1, STATE_NOISE = 2;
   int state = STATE_SEEKING;
   int pushCount = 0;
   double extremePrice = 0;
   double anchorClose = 0, ceilingFloor = 0;

   for(int i = fromShift; i >= toShift; i--)
   {
      double o = iOpen(_Symbol, tf, i), c = iClose(_Symbol, tf, i);
      double h = iHigh(_Symbol, tf, i), l = iLow(_Symbol, tf, i);
      bool isPush = wantHigh ? (c > o) : (c < o);
      bool isAnchorDir = wantHigh ? (c < o) : (c > o);

      if(state == STATE_SEEKING)
      {
         if(isPush) { pushCount = 1; extremePrice = wantHigh ? h : l; state = STATE_IN_PUSH; }
         continue;
      }

      if(state == STATE_IN_PUSH)
      {
         if(isPush)
         {
            pushCount++;
            extremePrice = wantHigh ? MathMax(extremePrice, h) : MathMin(extremePrice, l);
            continue;
         }
         if(isAnchorDir)
         {
            if(pushCount >= 2)
            {
               extremePrice = wantHigh ? MathMax(extremePrice, h) : MathMin(extremePrice, l);
               anchorClose = c;
               ceilingFloor = o;
               state = STATE_NOISE;
            }
            else { state = STATE_SEEKING; pushCount = 0; }
            continue;
         }
         continue; // exact doji (o==c) - ignore, stay in push
      }

      if(state == STATE_NOISE)
      {
         bool isConfirmCandle = isAnchorDir && (wantHigh ? (c < anchorClose) : (c > anchorClose));
         bool isInvalidate    = wantHigh ? (c > ceilingFloor) : (c < ceilingFloor);

         if(isConfirmCandle)
         {
            int n = ArraySize(outTimes);
            ArrayResize(outTimes, n + 1);
            ArrayResize(outPrices, n + 1);
            outTimes[n] = iTime(_Symbol, tf, i);
            outPrices[n] = extremePrice;
            state = STATE_SEEKING;
            pushCount = 0;
            continue;
         }
         if(isInvalidate)
         {
            state = STATE_SEEKING;
            pushCount = 0;
            if(isPush) { pushCount = 1; extremePrice = wantHigh ? h : l; state = STATE_IN_PUSH; }
            continue;
         }
         // pure noise - stay in STATE_NOISE, ceiling/floor unchanged
      }
   }
   return ArraySize(outTimes);
}

//+------------------------------------------------------------------+
//| Build one session: bias, previous session's PDH/PDL, and the     |
//| single most-recent qualifying level to watch.                    |
//+------------------------------------------------------------------+
SessionInfo BuildSession(datetime dayStart)
{
   SessionInfo info;
   info.valid = false;
   info.bias = 0;
   info.pdh = 0; info.pdl = 0;
   info.haveLevel = false;
   info.levelPrice = 0; info.levelTime = 0; info.levelIsHigh = false; info.levelSource = "";
   info.dayStart = dayStart;

   int startSec = TimeStrToSeconds(InpSessionStart);
   int endSec   = TimeStrToSeconds(InpSessionEnd);
   info.sessStart = dayStart + startSec;
   info.sessEnd   = dayStart + endSec;

   // Previous session = same clock window, one calendar day back
   info.prevSessStart = info.sessStart - 24 * 3600;
   info.prevSessEnd   = info.sessEnd   - 24 * 3600;

   // --- Bias: last two fully-closed bars on g_biasTF as of session start ---
   int biasShift = GetClosedBarShift(g_biasTF, info.sessStart);
   if(biasShift < 1) return info; // not enough history yet
   double h0 = iHigh(_Symbol, g_biasTF, biasShift),   l0 = iLow(_Symbol, g_biasTF, biasShift);
   double h1 = iHigh(_Symbol, g_biasTF, biasShift + 1), l1 = iLow(_Symbol, g_biasTF, biasShift + 1);
   if(h0 > h1 && l0 > l1)      info.bias = 1;   // higher high + higher low -> bullish
   else if(h0 < h1 && l0 < l1) info.bias = -1;  // lower high + lower low -> bearish
   else                         info.bias = 0;   // inside/outside/mixed -> no bias

   // --- PDH/PDL: previous fully-closed bar on g_levelTF (separate from bias -  ---
   // --- his own material scales levels to trader type (weekly/daily/session), ---
   // --- which isn't always the same timeframe bias is read from).            ---
   int levelShift = GetClosedBarShift(g_levelTF, info.sessStart);
   if(levelShift < 1) { info.valid = false; return info; }
   info.pdh = iHigh(_Symbol, g_levelTF, levelShift);
   info.pdl = iLow(_Symbol, g_levelTF, levelShift);

   if(info.bias == 0) { info.valid = false; return info; }
   info.valid = true;

   // --- Candidate levels, most-recent-wins, from THREE sources:            ---
   // ---  1) the previous g_levelTF bar's high/low (PDH/PDL above)          ---
   // ---  2) a confirmed 3-bar swing point on g_biasTF itself (his daily   ---
   // ---     "Identification" swing point - can sit several bars back)     ---
   // ---  3) a confirmed 3-bar swing point on g_execTF within the         ---
   // ---     previous session (his "intraday swing" refinement)            ---
   bool wantHigh = (info.bias == -1); // bearish -> watch a swept HIGH
   datetime bestTime = iTime(_Symbol, g_levelTF, levelShift);
   double   bestPrice = wantHigh ? info.pdh : info.pdl;
   string   bestSource = "Prev Level TF";

   // Source 2: bias-TF swing point, searched back InpSwingLookbackBars
   for(int s = biasShift + 1; s < biasShift + InpSwingLookbackBars; s++)
   {
      if(wantHigh && IsSwingHighTF(g_biasTF, s))
      {
         datetime t = iTime(_Symbol, g_biasTF, s);
         if(t > bestTime) { bestTime = t; bestPrice = iHigh(_Symbol, g_biasTF, s); bestSource = "Bias TF Swing"; }
      }
      if(!wantHigh && IsSwingLowTF(g_biasTF, s))
      {
         datetime t = iTime(_Symbol, g_biasTF, s);
         if(t > bestTime) { bestTime = t; bestPrice = iLow(_Symbol, g_biasTF, s); bestSource = "Bias TF Swing"; }
      }
   }

   // Source 3: intraday swing point on g_execTF within the previous session
   int shiftAtPrevStart = iBarShift(_Symbol, g_execTF, info.prevSessStart, false);
   int shiftAtPrevEnd    = iBarShift(_Symbol, g_execTF, info.prevSessEnd, false);
   if(shiftAtPrevStart >= 0 && shiftAtPrevEnd >= 0 && shiftAtPrevStart > shiftAtPrevEnd)
   {
      datetime qTimes[]; double qPrices[];
      int qCount = FindQualifiedSwings(g_execTF, shiftAtPrevStart - 1, shiftAtPrevEnd + 1, wantHigh, qTimes, qPrices);
      if(qCount > 0 && qTimes[qCount - 1] > bestTime)
      {
         bestTime = qTimes[qCount - 1];
         bestPrice = qPrices[qCount - 1];
         bestSource = "Intraday Swing";
      }
   }

   info.haveLevel = true;
   info.levelPrice = bestPrice;
   info.levelTime = bestTime;
   info.levelIsHigh = wantHigh;
   info.levelSource = bestSource;

   return info;
}

//+------------------------------------------------------------------+
void DrawSession(const SessionInfo &info)
{
   string tag = TimeToString(info.dayStart, TIME_DATE);
   color biasClr = (info.bias == 1) ? InpBullColor : (info.bias == -1) ? InpBearColor : InpNoBiasClr;

   string boxName = "DSW_Box_" + tag;
   ObjectDelete(0, boxName);
   ObjectCreate(0, boxName, OBJ_RECTANGLE, 0, info.sessStart, info.pdh, info.sessEnd, info.pdl);
   ObjectSetInteger(0, boxName, OBJPROP_COLOR, InpSessionBoxClr);
   ObjectSetInteger(0, boxName, OBJPROP_FILL, false);
   ObjectSetInteger(0, boxName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, boxName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, boxName, OBJPROP_BACK, true);

   string pdhName = "DSW_PDH_" + tag;
   ObjectDelete(0, pdhName);
   ObjectCreate(0, pdhName, OBJ_TREND, 0, info.sessStart, info.pdh, info.sessEnd, info.pdh);
   ObjectSetInteger(0, pdhName, OBJPROP_COLOR, InpLevelClr);
   ObjectSetInteger(0, pdhName, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, pdhName, OBJPROP_RAY_RIGHT, false);

   string pdlName = "DSW_PDL_" + tag;
   ObjectDelete(0, pdlName);
   ObjectCreate(0, pdlName, OBJ_TREND, 0, info.sessStart, info.pdl, info.sessEnd, info.pdl);
   ObjectSetInteger(0, pdlName, OBJPROP_COLOR, InpLevelClr);
   ObjectSetInteger(0, pdlName, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, pdlName, OBJPROP_RAY_RIGHT, false);

   string biasTxt;
   if(info.bias == 1) biasTxt = "BULLISH - watch a swept LOW";
   else if(info.bias == -1) biasTxt = "BEARISH - watch a swept HIGH";
   else biasTxt = "NO BIAS - no trade";

   string lblName = "DSW_Label_" + tag;
   ObjectDelete(0, lblName);
   ObjectCreate(0, lblName, OBJ_TEXT, 0, info.sessStart, info.pdh);
   string txt = StringFormat("%s | %s - %s | %s", EnumToString(InpTraderType),
                              TimeToString(info.sessStart, TIME_MINUTES),
                              TimeToString(info.sessEnd, TIME_MINUTES), biasTxt);
   ObjectSetString(0, lblName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, biasClr);
   ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);

   if(info.valid && info.haveLevel)
   {
      string lvlName = "DSW_Level_" + tag + "_v0";
      ObjectDelete(0, lvlName);
      ObjectCreate(0, lvlName, OBJ_TREND, 0, info.levelTime, info.levelPrice, info.sessEnd, info.levelPrice);
      ObjectSetInteger(0, lvlName, OBJPROP_COLOR, biasClr);
      ObjectSetInteger(0, lvlName, OBJPROP_STYLE, STYLE_DASHDOT);
      ObjectSetInteger(0, lvlName, OBJPROP_WIDTH, InpLineWidth);
      ObjectSetInteger(0, lvlName, OBJPROP_RAY_RIGHT, false);

      string lvlLbl = "DSW_LevelLbl_" + tag + "_v0";
      ObjectDelete(0, lvlLbl);
      ObjectCreate(0, lvlLbl, OBJ_TEXT, 0, info.levelTime, info.levelPrice);
      ObjectSetString(0, lvlLbl, OBJPROP_TEXT, "WATCHED LEVEL (" + info.levelSource + ")");
      ObjectSetInteger(0, lvlLbl, OBJPROP_COLOR, biasClr);
      ObjectSetInteger(0, lvlLbl, OBJPROP_FONTSIZE, 7);
      ObjectSetInteger(0, lvlLbl, OBJPROP_ANCHOR, info.levelIsHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
   }
}

//+------------------------------------------------------------------+
//| Optional small marker for every confirmed intraday swing point,  |
//| purely for visual context (not all of them get watched).         |
//+------------------------------------------------------------------+
void DrawSwingMarkers(const SessionInfo &info)
{
   if(!InpShowSwingMarkers || !info.valid) return;

   int shiftAtStart = iBarShift(_Symbol, g_execTF, info.prevSessStart, false);
   int shiftAtEnd    = iBarShift(_Symbol, g_execTF, info.prevSessEnd, false);
   if(shiftAtStart < 0 || shiftAtEnd < 0) return;

   datetime startBarClose = iTime(_Symbol, g_execTF, shiftAtStart) + PeriodSeconds(g_execTF);
   int loopStart = (startBarClose > info.prevSessStart) ? shiftAtStart : shiftAtStart - 1;

   bool wantHigh = (info.bias == -1);
   datetime qTimes[]; double qPrices[];
   int qCount = FindQualifiedSwings(g_execTF, loopStart, shiftAtEnd + 1, wantHigh, qTimes, qPrices);
   for(int k = 0; k < qCount; k++)
   {
      datetime t = qTimes[k];
      string nm = "DSW_Swing_" + TimeToString(t, TIME_DATE | TIME_MINUTES);
      ObjectDelete(0, nm);
      if(wantHigh)
      {
         ObjectCreate(0, nm, OBJ_ARROW_DOWN, 0, t, qPrices[k]);
         ObjectSetInteger(0, nm, OBJPROP_COLOR, InpBearColor);
      }
      else
      {
         ObjectCreate(0, nm, OBJ_ARROW_UP, 0, t, qPrices[k]);
         ObjectSetInteger(0, nm, OBJPROP_COLOR, InpBullColor);
      }
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
   }
}

//+------------------------------------------------------------------+
string BuildBaseName(datetime t)
{
   return "DSW_Trade_" + TimeToString(t, TIME_DATE | TIME_MINUTES | TIME_SECONDS);
}

//+------------------------------------------------------------------+
//| A fresher same-direction swing confirmed on g_execTF - trim the  |
//| current level line here and start a new versioned segment from   |
//| this point forward. Matches his own live-trade example: a        |
//| recently-formed swing supersedes an older one, not the reverse.   |
//+------------------------------------------------------------------+
void ReviseWatchedLevel(string tag, int &levelVersion, datetime tCur, double newPrice,
                         bool isHigh, datetime sessEnd, color clr)
{
   string oldLine = "DSW_Level_" + tag + "_v" + IntegerToString(levelVersion);
   string oldLbl  = "DSW_LevelLbl_" + tag + "_v" + IntegerToString(levelVersion);
   if(ObjectFind(0, oldLine) >= 0) ObjectSetInteger(0, oldLine, OBJPROP_TIME, 1, tCur);
   ObjectDelete(0, oldLbl); // stale label position - replaced by the new one below

   levelVersion++;
   string newLine = "DSW_Level_" + tag + "_v" + IntegerToString(levelVersion);
   ObjectDelete(0, newLine);
   ObjectCreate(0, newLine, OBJ_TREND, 0, tCur, newPrice, sessEnd, newPrice);
   ObjectSetInteger(0, newLine, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, newLine, OBJPROP_STYLE, STYLE_DASHDOT);
   ObjectSetInteger(0, newLine, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, newLine, OBJPROP_RAY_RIGHT, false);

   string newLbl = "DSW_LevelLbl_" + tag + "_v" + IntegerToString(levelVersion);
   ObjectDelete(0, newLbl);
   ObjectCreate(0, newLbl, OBJ_TEXT, 0, tCur, newPrice);
   ObjectSetString(0, newLbl, OBJPROP_TEXT, "WATCHED LEVEL (updated - fresh swing)");
   ObjectSetInteger(0, newLbl, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, newLbl, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, newLbl, OBJPROP_ANCHOR, isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
}

//+------------------------------------------------------------------+
//| Mark the sweep - the level got run through, awaiting reclaim.    |
//+------------------------------------------------------------------+
string MarkSwept(datetime t, double extremePrice, datetime sessEnd, bool isBuy)
{
   string base = BuildBaseName(t);

   string arrName = base + "_Swept";
   ObjectDelete(0, arrName);
   ObjectCreate(0, arrName, isBuy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, t, extremePrice);
   ObjectSetInteger(0, arrName, OBJPROP_COLOR, InpSweptColor);
   ObjectSetInteger(0, arrName, OBJPROP_WIDTH, 1);

   string lblName = base + "_SweptLbl";
   ObjectDelete(0, lblName);
   ObjectCreate(0, lblName, OBJ_TEXT, 0, t, extremePrice);
   ObjectSetString(0, lblName, OBJPROP_TEXT, "SWEPT - awaiting reclaim");
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, InpSweptColor);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, isBuy ? ANCHOR_UPPER : ANCHOR_LOWER);

   string lineName = base + "_SweptLine";
   ObjectDelete(0, lineName);
   ObjectCreate(0, lineName, OBJ_TREND, 0, t, extremePrice, sessEnd, extremePrice);
   ObjectSetInteger(0, lineName, OBJPROP_COLOR, InpSweptColor);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);

   return base;
}

//+------------------------------------------------------------------+
//| Reclaim confirmed -> entry. Draw entry/SL/TP.                    |
//+------------------------------------------------------------------+
void MarkEntry(string base, datetime tEntry, double entryPx, double slPx, double tpPx,
               datetime sessEnd, bool isBuy)
{
   ObjectDelete(0, base + "_SweptLine");

   color clr = isBuy ? InpBullColor : InpBearColor;

   string arrName = base + "_Entry";
   ObjectDelete(0, arrName);
   ObjectCreate(0, arrName, isBuy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, tEntry, entryPx);
   ObjectSetInteger(0, arrName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, arrName, OBJPROP_WIDTH, 2);

   string lineName = base + "_EntryLine";
   ObjectDelete(0, lineName);
   ObjectCreate(0, lineName, OBJ_TREND, 0, tEntry, entryPx, sessEnd, entryPx);
   ObjectSetInteger(0, lineName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);

   string riskName = base + "_Risk";
   ObjectDelete(0, riskName);
   ObjectCreate(0, riskName, OBJ_RECTANGLE, 0, tEntry, entryPx, sessEnd, slPx);
   ObjectSetInteger(0, riskName, OBJPROP_COLOR, InpRiskZoneClr);
   ObjectSetInteger(0, riskName, OBJPROP_FILL, true);
   ObjectSetInteger(0, riskName, OBJPROP_BACK, true);
   ObjectSetInteger(0, riskName, OBJPROP_WIDTH, 1);

   if(tpPx != 0)
   {
      string rewardName = base + "_Reward";
      ObjectDelete(0, rewardName);
      ObjectCreate(0, rewardName, OBJ_RECTANGLE, 0, tEntry, entryPx, sessEnd, tpPx);
      ObjectSetInteger(0, rewardName, OBJPROP_COLOR, InpRewardZoneClr);
      ObjectSetInteger(0, rewardName, OBJPROP_FILL, true);
      ObjectSetInteger(0, rewardName, OBJPROP_BACK, true);
      ObjectSetInteger(0, rewardName, OBJPROP_WIDTH, 1);
   }
}

//+------------------------------------------------------------------+
void MarkPartial(string base, datetime t, double px)
{
   string nm = base + "_Partial";
   ObjectDelete(0, nm);
   ObjectCreate(0, nm, OBJ_TEXT, 0, t, px);
   ObjectSetString(0, nm, OBJPROP_TEXT, "PARTIAL + BE");
   ObjectSetInteger(0, nm, OBJPROP_COLOR, InpPartialClr);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_CENTER);
}

//+------------------------------------------------------------------+
void CloseTradeVisual(string base, datetime tExit, double exitPx, string tag, color clr)
{
   string lineName   = base + "_EntryLine";
   string riskName   = base + "_Risk";
   string rewardName = base + "_Reward";

   if(ObjectFind(0, lineName) >= 0)   ObjectSetInteger(0, lineName, OBJPROP_TIME, 1, tExit);
   if(ObjectFind(0, riskName) >= 0)   ObjectSetInteger(0, riskName, OBJPROP_TIME, 1, tExit);
   if(ObjectFind(0, rewardName) >= 0) ObjectSetInteger(0, rewardName, OBJPROP_TIME, 1, tExit);

   string exitName = base + "_Exit";
   ObjectDelete(0, exitName);
   ObjectCreate(0, exitName, OBJ_TEXT, 0, tExit, exitPx);
   ObjectSetString(0, exitName, OBJPROP_TEXT, tag);
   ObjectSetInteger(0, exitName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, exitName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, exitName, OBJPROP_ANCHOR, ANCHOR_CENTER);
}

//+------------------------------------------------------------------+
//| Scan one session's execution-TF bars: watch -> swept -> active   |
//| -> resolved. One trade attempt per session, matching his "one    |
//| setup, repeat daily" framing.                                    |
//+------------------------------------------------------------------+
void ScanSession(const SessionInfo &info)
{
   if(!info.valid || !info.haveLevel) return;

   int shiftAtStart = iBarShift(_Symbol, g_execTF, info.sessStart, false);
   int shiftAtEnd    = iBarShift(_Symbol, g_execTF, info.sessEnd, false);
   if(shiftAtStart < 0 || shiftAtEnd < 0) return;

   // Include the bar at shiftAtStart itself if its CLOSE falls inside the
   // session, matching the EA's close-time fix - an H1 bar opening 16:00
   // (before a 16:30 session start) can still close well inside the
   // session, and was being silently dropped by an open-time-only check.
   datetime startBarClose = iTime(_Symbol, g_execTF, shiftAtStart) + PeriodSeconds(g_execTF);
   int loopStart = (startBarClose > info.sessStart) ? shiftAtStart : shiftAtStart - 1;

   bool isBuy = (info.bias == 1);        // bullish -> buy on reclaim of a swept low
   double level = info.levelPrice;
   datetime levelTime = info.levelTime;
   int levelVersion = 0;
   double tp = isBuy ? info.pdh : info.pdl;
   double bufPts = InpSLBufferPoints * _Point;
   color levelClr = isBuy ? InpBullColor : InpBearColor;
   string tag = TimeToString(info.dayStart, TIME_DATE);

   int state = DSW_STATE_WATCHING;
   double runExtreme = 0;
   string base = "";
   double entryPx = 0, slPx = 0;
   int entryShift = -1;
   bool partialDone = false;
   double partialTargetPx = 0; bool havePartialTarget = false;

   for(int s = loopStart; s >= shiftAtEnd; s--)
   {
      datetime tCur = iTime(_Symbol, g_execTF, s);
      double open1 = iOpen(_Symbol, g_execTF, s), close1 = iClose(_Symbol, g_execTF, s);
      double high1 = iHigh(_Symbol, g_execTF, s), low1  = iLow(_Symbol, g_execTF, s);

      if(state == DSW_STATE_WATCHING)
      {
         // Live level refinement: a fresher qualifying swing (our multi-candle
         // rule, not the bare 3-candle test) supersedes whatever was being
         // watched, once a minimum cooldown has passed as an extra safety net.
         datetime qTimes[]; double qPrices[];
         int qCount = FindQualifiedSwings(g_execTF, loopStart, s, isBuy, qTimes, qPrices);
         if(qCount > 0)
         {
            datetime freshT = qTimes[qCount - 1];
            double freshPrice = qPrices[qCount - 1];
            long cooldownSecs = (long)InpLevelUpdateCooldownBars * PeriodSeconds(g_execTF);
            if(freshT >= levelTime + cooldownSecs)
            {
               ReviseWatchedLevel(tag, levelVersion, tCur, freshPrice, !isBuy, info.sessEnd, levelClr);
               level = freshPrice;
               levelTime = freshT;
            }
         }

         bool swept = isBuy ? (low1 < level) : (high1 > level);
         if(swept)
         {
            runExtreme = isBuy ? low1 : high1;
            // Same-candle SFP (his own diagram's classic case): the bar that
            // sweeps can also be the bar that closes back through. Check
            // reclaim on THIS bar before waiting for the next one.
            // The sweeping candle only counts as a same-candle entry if it
            // actually flips color - closing back below the level while
            // still net bullish (opened even lower) isn't genuine rejection,
            // just price sitting back inside the range for a moment.
            bool reclaimedSameBar = isBuy ? (close1 > level && close1 > open1)
                                           : (close1 < level && close1 < open1);
            if(reclaimedSameBar)
            {
               entryPx = close1;
               entryShift = s;
               slPx = isBuy ? (runExtreme - bufPts) : (runExtreme + bufPts);
               base = MarkSwept(tCur, runExtreme, info.sessEnd, isBuy);
               MarkEntry(base, tCur, entryPx, slPx, (InpTPMode == TP_SESSION_CLOSE ? 0 : tp), info.sessEnd, isBuy);
               state = DSW_STATE_ACTIVE;
            }
            else
            {
               base = MarkSwept(tCur, runExtreme, info.sessEnd, isBuy);
               state = DSW_STATE_SWEPT;
            }
         }
         continue;
      }

      if(state == DSW_STATE_SWEPT)
      {
         runExtreme = isBuy ? MathMin(runExtreme, low1) : MathMax(runExtreme, high1);
         bool reclaimed = isBuy ? (close1 > level) : (close1 < level);
         if(reclaimed)
         {
            entryPx = close1;
            entryShift = s;
            slPx = isBuy ? (runExtreme - bufPts) : (runExtreme + bufPts);
            MarkEntry(base, tCur, entryPx, slPx, (InpTPMode == TP_SESSION_CLOSE ? 0 : tp), info.sessEnd, isBuy);
            state = DSW_STATE_ACTIVE;
         }
         continue;
      }

      if(state == DSW_STATE_ACTIVE)
      {
         bool hitSL = isBuy ? (low1 <= slPx) : (high1 >= slPx);
         if(hitSL)
         {
            CloseTradeVisual(base, tCur, slPx, "SL", InpSLHitClr);
            return; // one attempt per session - done either way
         }

         if(InpTPMode == TP_LIQUIDITY)
         {
            bool hitTP = isBuy ? (high1 >= tp) : (low1 <= tp);
            if(hitTP) { CloseTradeVisual(base, tCur, tp, "TP", InpTPHitClr); return; }
         }
         else if(InpTPMode == TP_PARTIAL_TRAIL)
         {
            if(!havePartialTarget && entryShift >= 0)
            {
               datetime qTimes[]; double qPrices[];
               int qCount = FindQualifiedSwings(g_execTF, entryShift, s, isBuy, qTimes, qPrices);
               if(qCount > 0)
               {
                  havePartialTarget = true;
                  partialTargetPx = qPrices[0]; // first one to confirm after entry
               }
            }
            if(havePartialTarget && !partialDone)
            {
               bool hitPartial = isBuy ? (high1 >= partialTargetPx) : (low1 <= partialTargetPx);
               if(hitPartial)
               {
                  MarkPartial(base, tCur, partialTargetPx);
                  slPx = entryPx; // move to breakeven
                  partialDone = true;
               }
            }
            bool hitTP = isBuy ? (high1 >= tp) : (low1 <= tp);
            if(hitTP) { CloseTradeVisual(base, tCur, tp, "TP", InpTPHitClr); return; }
         }
         // TP_SESSION_CLOSE: no price target, just keep checking SL until session end
      }
   }

   // Session ended - force-close anything still open/pending, per the
   // explicit "everything ends by end of NY session" rule.
   if(state == DSW_STATE_SWEPT)
   {
      ObjectDelete(0, base + "_SweptLine");
      string nm = base + "_SweptExpired";
      ObjectCreate(0, nm, OBJ_TEXT, 0, info.sessEnd, runExtreme);
      ObjectSetString(0, nm, OBJPROP_TEXT, "X (session ended, never reclaimed)");
      ObjectSetInteger(0, nm, OBJPROP_COLOR, InpSweptColor);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 7);
   }
   else if(state == DSW_STATE_ACTIVE)
   {
      double lastClose = iClose(_Symbol, g_execTF, shiftAtEnd);
      CloseTradeVisual(base, info.sessEnd, lastClose, "SESSION CLOSE", InpPartialClr);
   }
}

//+------------------------------------------------------------------+
void ProcessAll()
{
   int startSec = TimeStrToSeconds(InpSessionStart);
   for(int d = 0; d < InpHistoryDays; d++)
   {
      datetime dayOpen = iTime(_Symbol, PERIOD_D1, d);
      if(dayOpen == 0) break;
      SessionInfo info = BuildSession(dayOpen);
      DrawSession(info);
      DrawSwingMarkers(info);
      ScanSession(info);
   }
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                 const int prev_calculated,
                 const datetime &time[],
                 const double &open[],
                 const double &high[],
                 const double &low[],
                 const double &close[],
                 const long &tick_volume[],
                 const long &volume[],
                 const int &spread[])
{
   datetime latestEntryBar = iTime(_Symbol, g_execTF, 0);
   if(latestEntryBar != g_lastEntryBarTime)
   {
      g_lastEntryBarTime = latestEntryBar;
      ProcessAll();
   }
   return(rates_total);
}
