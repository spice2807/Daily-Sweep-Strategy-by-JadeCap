//+------------------------------------------------------------------+
//|                                       DailySweep_EA.mq5          |
//|   Full trading EA implementing the Daily Sweep / SFP strategy    |
//|   exactly as built out in DailySweep_Visualizer.mq5 v1.10.       |
//|   Market-fill entries (his method - no pending order), three     |
//|   selectable exit modes, hard session-end close as a global      |
//|   backstop. Built for the Strategy Tester, not verified live.    |
//+------------------------------------------------------------------+
#property copyright "Elite Quant"
#property version   "1.81"
#include <Trade\Trade.mqh>

//====================================================================
// INPUTS
//====================================================================

//--- Bias / levels / session
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
input int              InpSwingLookbackBars = 10;       // OURS: how many g_biasTF bars back to search for a swing point
input int              InpLevelUpdateCooldownBars = 5;  // OURS: minimum execTF bars before a fresh swing can supersede the level (dampens chasing on fast timeframes)

//--- Stop loss
input double           InpSLBufferPoints = 20.0;        // OURS: SL buffer beyond the sweep extreme, in points

//--- Take profit modes
enum ENUM_TP_MODE
{
   TP_LIQUIDITY,      // Ride to the opposite session extreme (his stated default)
   TP_SESSION_CLOSE,  // Force-close at session end, no price target
   TP_PARTIAL_TRAIL   // Partial at first new intraday swing in favor, then BE, then ride to target
};
input ENUM_TP_MODE     InpTPMode         = TP_LIQUIDITY;
input double           InpPartialClosePct = 50.0;       // % closed at the partial level in TP_PARTIAL_TRAIL mode

//--- Money management
input double           InpRiskUSD        = 100.0;
input double           InpMinLots        = 0.0;         // 0 = use symbol's minimum lot as floor
input int              InpSlippagePoints = 20;

//--- Misc
input ulong            InpMagicNumber    = 990111;
input string           InpTradeComment   = "DailySweep";
input bool              InpVerboseLogging = true;      // Print bias/level diagnostics every session (turn off once tuned)

//====================================================================
// GLOBALS
//====================================================================
CTrade trade;

#define DSW_STATE_NONE     0   // no valid bias/level this session - nothing to do
#define DSW_STATE_WATCHING 1   // watching for a sweep of the level
#define DSW_STATE_SWEPT    2   // level swept, awaiting reclaim
#define DSW_STATE_ACTIVE   3   // trade live

datetime g_lastDayStart = 0;
datetime g_lastExecBar  = 0;
bool     g_sessionDone  = false; // one attempt per session, win or lose

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

// Session state
int      g_bias = 0;
double   g_pdh = 0, g_pdl = 0;
bool     g_haveLevel = false;
double   g_levelPrice = 0;
bool     g_levelIsHigh = false;
datetime g_levelTime = 0; // when the currently-watched level was formed - needed to tell if a newly-confirmed swing is actually fresher
datetime g_sessStart = 0, g_sessEnd = 0;

// Trade state machine
int      g_state = DSW_STATE_NONE;
bool     g_isBuy = false;
double   g_runExtreme = 0;
double   g_entryPx = 0, g_slPx = 0, g_tp = 0;
datetime g_entryTime = 0;
bool     g_havePartialTarget = false;
double   g_partialTargetPx = 0;
bool     g_partialDone = false;

//+------------------------------------------------------------------+
int OnInit()
{
   ResolveTraderType();
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   PrintSettings();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
void PrintSettings()
{
   Print("=== Daily Sweep EA - settings this run ===");
   Print("Trader type: ", EnumToString(InpTraderType));
   Print("Bias TF: ", EnumToString(g_biasTF), "  Exec TF: ", EnumToString(g_execTF), "  Level TF: ", EnumToString(g_levelTF));
   Print("Session: ", InpSessionStart, " - ", InpSessionEnd, " (broker time)");
   Print("Swing lookback (bias TF bars): ", InpSwingLookbackBars, "   Level update cooldown: ", InpLevelUpdateCooldownBars, " exec bars");
   Print("SL buffer: ", InpSLBufferPoints, " points   Risk/trade: $", InpRiskUSD);
   string tpTxt;
   switch(InpTPMode)
   {
      case TP_SESSION_CLOSE: tpTxt = "SESSION_CLOSE"; break;
      case TP_PARTIAL_TRAIL: tpTxt = StringFormat("PARTIAL_TRAIL (%.0f%% at first swing, then BE)", InpPartialClosePct); break;
      default:                tpTxt = "LIQUIDITY (opposite session extreme)"; break;
   }
   Print("TP mode: ", tpTxt);
}

//+------------------------------------------------------------------+
//| Find the shift of the last g_biasTF bar that has FULLY CLOSED   |
//| as of 'asOf'. iBarShift alone isn't enough: it returns whichever |
//| bar's OPEN time is at/before asOf, which - for an intraday      |
//| session start compared against a Daily (or higher) bias TF - is  |
//| always TODAY's own still-forming bar, not yesterday's closed     |
//| one. That silently blocked every single session (see v1.20 log). |
//+------------------------------------------------------------------+
int GetClosedBarShift(ENUM_TIMEFRAMES tf, datetime asOf)
{
   int shift = iBarShift(_Symbol, tf, asOf, false);
   if(shift < 0) return -1;
   datetime barOpen = iTime(_Symbol, tf, shift);
   int periodSecs = PeriodSeconds(tf);
   if(barOpen + periodSecs > asOf) shift++; // that bar hasn't closed yet as of asOf
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
//| Same 3-candle swing definition used throughout - one neighbor    |
//| on each side, strict comparison. His rule, stated directly.      |
//+------------------------------------------------------------------+
bool IsSwingHighTF(ENUM_TIMEFRAMES tf, int shift)
{
   double h0 = iHigh(_Symbol, tf, shift);
   double h1 = iHigh(_Symbol, tf, shift + 1);
   double hM1 = iHigh(_Symbol, tf, shift - 1);
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
//| Rebuild everything for a new calendar day: bias, PDH/PDL, and    |
//| the single most-recent qualifying level (three-source search,    |
//| same as the indicator v1.10).                                    |
//+------------------------------------------------------------------+
void BuildSession(datetime dayStart)
{
   g_bias = 0;
   g_pdh = 0; g_pdl = 0;
   g_haveLevel = false;
   g_levelPrice = 0; g_levelIsHigh = false; g_levelTime = 0;
   g_state = DSW_STATE_NONE;
   g_sessionDone = false;
   g_havePartialTarget = false;
   g_partialDone = false;

   int startSec = TimeStrToSeconds(InpSessionStart);
   int endSec   = TimeStrToSeconds(InpSessionEnd);
   g_sessStart = dayStart + startSec;
   g_sessEnd   = dayStart + endSec;

   datetime prevSessStart = g_sessStart - 24 * 3600;
   datetime prevSessEnd   = g_sessEnd   - 24 * 3600;

   // --- Bias: last two fully-closed bars on g_biasTF as of session start ---
   int biasShift = GetClosedBarShift(g_biasTF, g_sessStart);
   if(biasShift < 1)
   {
      if(InpVerboseLogging) PrintFormat("[%s] NO DATA - not enough %s history yet for bias check",
                                         TimeToString(dayStart, TIME_DATE), EnumToString(g_biasTF));
      return;
   }
   double h0 = iHigh(_Symbol, g_biasTF, biasShift),   l0 = iLow(_Symbol, g_biasTF, biasShift);
   double h1 = iHigh(_Symbol, g_biasTF, biasShift + 1), l1 = iLow(_Symbol, g_biasTF, biasShift + 1);
   if(h0 > h1 && l0 > l1)      g_bias = 1;
   else if(h0 < h1 && l0 < l1) g_bias = -1;
   else                         g_bias = 0;

   // --- PDH/PDL: previous fully-closed bar on g_levelTF (separate from bias -  ---
   // --- his own material scales levels to trader type, not always the same    ---
   // --- timeframe bias is read from).                                        ---
   int levelShift = GetClosedBarShift(g_levelTF, g_sessStart);
   if(levelShift < 1)
   {
      if(InpVerboseLogging) PrintFormat("[%s] NO DATA - not enough %s history yet for level lookup",
                                         TimeToString(dayStart, TIME_DATE), EnumToString(g_levelTF));
      return;
   }
   g_pdh = iHigh(_Symbol, g_levelTF, levelShift);
   g_pdl = iLow(_Symbol, g_levelTF, levelShift);

   if(g_bias == 0)
   {
      if(InpVerboseLogging) PrintFormat("[%s] NO BIAS - H0=%.5f L0=%.5f vs H1=%.5f L1=%.5f (mixed/inside/outside bar)",
                                         TimeToString(dayStart, TIME_DATE), h0, l0, h1, l1);
      return; // no bias -> no trade, leave state NONE
   }

   bool wantHigh = (g_bias == -1);
   datetime bestTime = iTime(_Symbol, g_levelTF, levelShift);
   double   bestPrice = wantHigh ? g_pdh : g_pdl;

   // Source 2: bias-TF swing point, searched back InpSwingLookbackBars
   for(int s = biasShift + 1; s < biasShift + InpSwingLookbackBars; s++)
   {
      if(wantHigh && IsSwingHighTF(g_biasTF, s))
      {
         datetime t = iTime(_Symbol, g_biasTF, s);
         if(t > bestTime) { bestTime = t; bestPrice = iHigh(_Symbol, g_biasTF, s); }
      }
      if(!wantHigh && IsSwingLowTF(g_biasTF, s))
      {
         datetime t = iTime(_Symbol, g_biasTF, s);
         if(t > bestTime) { bestTime = t; bestPrice = iLow(_Symbol, g_biasTF, s); }
      }
   }

   // Source 3: intraday swing point on g_execTF within the previous session
   int shiftAtPrevStart = iBarShift(_Symbol, g_execTF, prevSessStart, false);
   int shiftAtPrevEnd    = iBarShift(_Symbol, g_execTF, prevSessEnd, false);
   if(shiftAtPrevStart >= 0 && shiftAtPrevEnd >= 0 && shiftAtPrevStart > shiftAtPrevEnd)
   {
      datetime qTimes[]; double qPrices[];
      int qCount = FindQualifiedSwings(g_execTF, shiftAtPrevStart - 1, shiftAtPrevEnd + 1, wantHigh, qTimes, qPrices);
      if(qCount > 0 && qTimes[qCount - 1] > bestTime)
      {
         bestTime = qTimes[qCount - 1];
         bestPrice = qPrices[qCount - 1];
      }
   }
   else if(InpVerboseLogging)
   {
      PrintFormat("[%s] WARNING - not enough %s history for the intraday-swing search (source 3 skipped)",
                  TimeToString(dayStart, TIME_DATE), EnumToString(g_execTF));
   }

   g_haveLevel = true;
   g_levelPrice = bestPrice;
   g_levelIsHigh = wantHigh;
   g_levelTime = bestTime;
   g_state = DSW_STATE_WATCHING;

   if(InpVerboseLogging)
      PrintFormat("[%s] WATCHING - bias=%s  PDH=%.5f  PDL=%.5f  level=%.5f (%s)",
                  TimeToString(dayStart, TIME_DATE), g_bias==1?"BULLISH":"BEARISH",
                  g_pdh, g_pdl, g_levelPrice, wantHigh?"watching a HIGH":"watching a LOW");
}

//+------------------------------------------------------------------+
double GetLots(double slDistancePrice)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpMinLots > 0) minLot = InpMinLots;

   if(slDistancePrice <= 0 || tickValue <= 0 || tickSize <= 0) return minLot;

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return minLot;

   double lots = InpRiskUSD / lossPerLot;
   lots = MathFloor(lots / stepLot) * stepLot;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return true;
   }
   return false;
}

void CloseActivePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
{
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(stepLot <= 0) return 0;
   vol = MathFloor(vol / stepLot) * stepLot;
   if(vol < minLot) return 0;
   return vol;
}

//+------------------------------------------------------------------+
void EnterMarket(bool isBuy, double slPx, double tpPx)
{
   double refPx = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = MathAbs(refPx - slPx);
   double lots = GetLots(slDist);

   double brokerTP = (InpTPMode == TP_SESSION_CLOSE) ? 0 : tpPx;

   bool ok;
   if(isBuy) ok = trade.Buy(lots, _Symbol, 0, slPx, brokerTP, InpTradeComment);
   else      ok = trade.Sell(lots, _Symbol, 0, slPx, brokerTP, InpTradeComment);

   if(ok)
   {
      g_isBuy = isBuy; g_entryPx = refPx; g_slPx = slPx; g_tp = tpPx; g_entryTime = TimeCurrent();
      g_havePartialTarget = false; g_partialDone = false;
      g_state = DSW_STATE_ACTIVE;
      PrintFormat("[ENTRY] %s @ %.5f  SL=%.5f  TP=%.5f (mode-dependent)  lots=%.2f",
                  isBuy ? "BUY" : "SELL", refPx, slPx, tpPx, lots);
   }
   else
   {
      PrintFormat("[ERROR] Market entry failed: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      g_state = DSW_STATE_NONE; // don't keep retrying this session
      g_sessionDone = true;
   }
}

//+------------------------------------------------------------------+
//| Runs every tick - handles TP_PARTIAL_TRAIL's partial/breakeven   |
//| step, since that can't be expressed as a single broker order.    |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(InpTPMode != TP_PARTIAL_TRAIL) return;
   if(g_state != DSW_STATE_ACTIVE) return;
   if(g_partialDone) return;
   if(!HasOpenPosition()) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      double curPrice  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol        = PositionGetDouble(POSITION_VOLUME);
      double curTP      = PositionGetDouble(POSITION_TP);

      if(!g_havePartialTarget) continue; // set once the new swing confirms (in OnNewExecBar)

      bool hitPartial = g_isBuy ? (curPrice >= g_partialTargetPx) : (curPrice <= g_partialTargetPx);
      if(!hitPartial) continue;

      double closeVol = NormalizeVolume(vol * (InpPartialClosePct / 100.0));
      if(closeVol > 0 && closeVol < vol)
         trade.PositionClosePartial(ticket, closeVol);
      trade.PositionModify(ticket, openPrice, curTP); // SL -> breakeven
      g_partialDone = true;
      Print("[PARTIAL] Partial close + SL->breakeven triggered.");
   }
}

//+------------------------------------------------------------------+
//| Session-end backstop: force-close whatever's still open/pending  |
//| regardless of mode. "Everything ends by end of NY session."      |
//+------------------------------------------------------------------+
void HandleSessionEnd()
{
   if(g_sessionDone) return;
   if(TimeCurrent() < g_sessEnd) return;

   if(g_state == DSW_STATE_SWEPT)
   {
      Print("[SESSION END] Level swept but never reclaimed - clearing.");
   }
   else if(g_state == DSW_STATE_WATCHING)
   {
      if(InpVerboseLogging) Print("[SESSION END] Level was never swept this session.");
   }
   else if(g_state == DSW_STATE_ACTIVE)
   {
      if(HasOpenPosition())
      {
         CloseActivePosition();
         Print("[SESSION END] Force-closed active position.");
      }
   }
   g_state = DSW_STATE_NONE;
   g_sessionDone = true;
}

//+------------------------------------------------------------------+
//| Main per-exec-bar logic (shift 1 = the bar that just closed).    |
//+------------------------------------------------------------------+
void OnNewExecBar()
{
   if(g_sessionDone) return;
   datetime tCur = iTime(_Symbol, g_execTF, 1);
   // Gate on this bar's CLOSE time, not its open time. A bar can open
   // before session start and still close well inside the session - on
   // execution timeframes that don't divide evenly into the session start
   // (H4 is the clearest case), checking the open time alone would wrongly
   // discard the first usable bar of the session every single day.
   datetime tClose = tCur + PeriodSeconds(g_execTF);
   if(tClose <= g_sessStart || tClose > g_sessEnd) return;

   double open1 = iOpen(_Symbol, g_execTF, 1), close1 = iClose(_Symbol, g_execTF, 1);
   double high1 = iHigh(_Symbol, g_execTF, 1), low1  = iLow(_Symbol, g_execTF, 1);

   if(g_state == DSW_STATE_WATCHING)
   {
      bool isBuy = (g_bias == 1); // bullish -> watching for a swept LOW

      // Live level refinement: a fresher qualifying swing (our multi-candle
      // rule, not the bare 3-candle test) supersedes whatever was being
      // watched, once a minimum cooldown has passed as an extra safety net.
      // Re-scans from session start to the just-closed bar each time -
      // session ranges are short, so this is cheap.
      int sessStartShift = iBarShift(_Symbol, g_execTF, g_sessStart, false);
      datetime qTimes[]; double qPrices[];
      int qCount = FindQualifiedSwings(g_execTF, sessStartShift, 1, isBuy, qTimes, qPrices);
      if(qCount > 0)
      {
         datetime freshT = qTimes[qCount - 1];
         double freshPrice = qPrices[qCount - 1];
         long cooldownSecs = (long)InpLevelUpdateCooldownBars * PeriodSeconds(g_execTF);
         if(freshT >= g_levelTime + cooldownSecs)
         {
            if(InpVerboseLogging)
               PrintFormat("[LEVEL UPDATED] %.5f -> %.5f (fresher qualified swing confirmed on %s)",
                           g_levelPrice, freshPrice, EnumToString(g_execTF));
            g_levelPrice = freshPrice;
            g_levelTime = freshT;
         }
      }

      bool swept = isBuy ? (low1 < g_levelPrice) : (high1 > g_levelPrice);
      if(swept)
      {
         g_runExtreme = isBuy ? low1 : high1;
         // Same-candle SFP: check reclaim on THIS bar before waiting for
         // the next one - his own diagram's classic case is one candle
         // that both sweeps and closes back through.
         // The sweeping candle only counts as a same-candle entry if it
         // actually flips color - closing back below the level while
         // still net bullish (opened even lower) isn't genuine rejection,
         // just price sitting back inside the range for a moment.
         bool reclaimedSameBar = isBuy ? (close1 > g_levelPrice && close1 > open1)
                                        : (close1 < g_levelPrice && close1 < open1);
         if(reclaimedSameBar)
         {
            double bufPts = InpSLBufferPoints * _Point;
            double slPx = isBuy ? (g_runExtreme - bufPts) : (g_runExtreme + bufPts);
            double tp = isBuy ? g_pdh : g_pdl;
            Print("[SWEPT+RECLAIMED same candle] Level ", DoubleToString(g_levelPrice, _Digits));
            EnterMarket(isBuy, slPx, tp);
         }
         else
         {
            g_state = DSW_STATE_SWEPT;
            Print("[SWEPT] Level ", DoubleToString(g_levelPrice, _Digits), " swept, awaiting reclaim.");
         }
      }
      return;
   }

   if(g_state == DSW_STATE_SWEPT)
   {
      bool isBuy = (g_bias == 1);
      g_runExtreme = isBuy ? MathMin(g_runExtreme, low1) : MathMax(g_runExtreme, high1);
      bool reclaimed = isBuy ? (close1 > g_levelPrice) : (close1 < g_levelPrice);
      if(reclaimed)
      {
         double bufPts = InpSLBufferPoints * _Point;
         double slPx = isBuy ? (g_runExtreme - bufPts) : (g_runExtreme + bufPts);
         double tp = isBuy ? g_pdh : g_pdl;
         EnterMarket(isBuy, slPx, tp);
      }
      return;
   }

   if(g_state == DSW_STATE_ACTIVE)
   {
      // SL/TP are native broker orders except TP_SESSION_CLOSE (no TP set)
      // and the partial step of TP_PARTIAL_TRAIL (handled in ManageOpenTrade).
      // Here we only need to watch for the new post-entry swing that defines
      // the partial target in TP_PARTIAL_TRAIL mode.
      if(InpTPMode == TP_PARTIAL_TRAIL && !g_havePartialTarget)
      {
         int entryShift = iBarShift(_Symbol, g_execTF, g_entryTime, false);
         datetime qTimes[]; double qPrices[];
         int qCount = FindQualifiedSwings(g_execTF, entryShift, 1, g_isBuy, qTimes, qPrices);
         if(qCount > 0)
         {
            g_havePartialTarget = true;
            g_partialTargetPx = qPrices[0]; // first one to confirm after entry
            Print("[PARTIAL TARGET SET] ", DoubleToString(g_partialTargetPx, _Digits));
         }
      }

      // If the position already closed (SL/TP hit natively), reset for the
      // next session - one attempt per session either way.
      if(!HasOpenPosition())
      {
         g_state = DSW_STATE_NONE;
         g_sessionDone = true;
         Print("[EXIT] Position closed (SL/TP), session attempt done.");
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenTrade();

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   datetime dayStart = now - (dt.hour * 3600 + dt.min * 60 + dt.sec);

   // Build the session once we've actually REACHED session start - not the
   // instant the calendar day rolls over. Building it at, say, 01:00 and
   // asking "what closed as of 16:30 today" queries bars that don't exist
   // yet in simulated time on intraday bias TFs (H4, H1) - that's what was
   // silently producing NO DATA on every single session for those presets.
   datetime todaySessStart = dayStart + TimeStrToSeconds(InpSessionStart);
   if(dayStart != g_lastDayStart && now >= todaySessStart)
   {
      g_lastDayStart = dayStart;
      BuildSession(dayStart);
   }

   HandleSessionEnd();

   datetime curExecBar = iTime(_Symbol, g_execTF, 0);
   if(curExecBar != g_lastExecBar)
   {
      g_lastExecBar = curExecBar;
      OnNewExecBar();
   }
}
