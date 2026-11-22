//+------------------------------------------------------------------+
//| PalmScalper.mq5 — scalping EA tuned for the TradeSetGo $100 bonus |
//| Rules baked in: lot >= 0.10, hold >= 180s, move >= 5 pips,       |
//| no trading around major news, SL always on, no martingale/grid.  |
//| v2.00 brain transplant (from published Nyao Scalper research):   |
//| entries fire on a 0-10 M5 trend score gated by the D1 trend;     |
//| exits are profit checkpoints that re-check the score — lock and  |
//| continue while the score agrees, close when it turns. Guard      |
//| stack: spread cap, news blackout, loss-streak cooldown,          |
//| paper-only mode after 4 straight losses, basket stop 8%,         |
//| hard equity stop 12%. Blue-guard trailing (v1.11) kept: a blue   |
//| trade is locked so it can never turn red. Lot compounds gently   |
//| with realised balance growth, hard-capped. One position at a     |
//| time, every position carries an SL.                              |
//| v2.01: immediate entry on attach (owner's "bot aktif" rule) —    |
//| the first position opens at once in the D1 gate's direction      |
//| (trend-score direction as fallback), still under every guard.    |
//+------------------------------------------------------------------+
#property copyright "ticol"
#property version   "2.01"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//---------------- Inputs: core ----------------
input double InpLot             = 0.10;   // Lot size (bonus qualifying minimum = 0.10)
input int    InpRSIPeriod       = 14;     // RSI period (overextension filter only)
input double InpStopLossPips    = 12.0;   // Fixed stop loss (pips) — ~$12 on gold at 0.10 lot
input double InpSafetyTPPips    = 60.0;   // Far backstop take profit (pips) — exits are checkpoint-driven; 0 = none
input double InpMaxSpreadPips   = 4.0;    // Skip entry if spread above this (pips)
input int    InpMinHoldSeconds  = 180;    // Minimum hold before a signal-exit (bonus rule)
input double InpMinMovePips     = 5.0;    // Minimum price move for a signal-exit (bonus rule)
input int    InpMaxTradesPerDay = 3;      // Max entries per day
input double InpDailyLossLimit  = 15.0;   // Stop trading for the day after this loss ($)
input double InpDailyProfitLock = 10.0;   // Lock the day's profit: stop opening trades once day P/L reaches this ($) — 0 = off
input double InpTrailStartPips  = 5.0;    // Blue-guard: once profit reaches this (pips) after min hold, SL locks it in — 0 = off
input double InpTrailDistancePips = 3.0;  // Trailing distance behind price once the blue-guard is armed (pips)
input int    InpReenterCooldownSec = 60;  // Wait this long after a close before re-entering (s)
input double InpCompoundStepUsd = 25.0;   // Compounding: one lot step per this much balance growth above start ($)
input double InpLotPerStep      = 0.01;   // Lot added per compounding step (0 = compounding off)
input double InpMaxLot          = 0.20;   // Hard cap on the compounded lot
input long   InpMagic           = 4249201;// Magic number
input string InpNewsTimes       = "";     // Server-time news to avoid, e.g. "15:30,21:00" (HH:MM, comma separated)
input int    InpNewsAvoidMin    = 30;     // Minutes before/after news time to stay out
input bool   InpImmediateEntry  = true;   // v2.01: on attach, enter at once in the D1 gate's direction (owner's "bot aktif" rule)

//---------------- Inputs: trend score + D1 gate (v2.00) ----------------
input int    InpMinScore        = 7;      // Minimum |trend score| (0-10) to enter
input int    InpScoreAgree      = 4;      // Checkpoint: score at/above this in our direction = trend still agrees
input int    InpOppScoreExit    = 6;      // Early loser exit: opposite score at/above this closes a losing position
input double InpD1BandPct       = 0.5;    // D1 gate: |close - EMA50| must exceed this % of price to define the trend
input double InpCheckpointUsd   = 5.0;    // Profit checkpoint step ($ of floating profit) — score is re-checked at each
input double InpRSIBuyMax       = 70.0;   // Do not buy at/above this RSI (overextended)
input double InpRSISellMin      = 30.0;   // Do not sell at/below this RSI (overextended)

//---------------- Inputs: guard stack (v2.00) ----------------
input int    InpStreakCooldown  = 3;      // Consecutive losses that trigger an entry cooldown
input int    InpStreakCooldownMin = 60;   // Cooldown length after the loss streak (minutes)
input int    InpStreakPaper     = 4;      // Consecutive losses that switch the EA to paper-only mode
input double InpBasketStopPct   = 8.0;    // Close the open position if its floating loss reaches this % of balance
input double InpHardEquityStopPct = 12.0; // Halt entries for the day if equity falls this % below the EA-start equity

//---------------- Globals ----------------
int hRSI, hATR, hEMA200, hEMAD1;
double PipValue; // price size of 1 pip
datetime DayStart;
int TradesToday;
double DayPnLBase; // account balance at day start
double StartBalance; // balance when the EA started (compounding baseline)
double StartEquity;  // equity when the EA started (hard-stop baseline)
datetime LastBarTime; // last M5 bar seen (entries + streak refresh run on new bars)
ulong  PosTicketSeen; // ticket of the position currently being checkpoint-tracked
int    PosCheckpoint; // highest $-checkpoint reached by the current position
bool   ImmediateDone; // v2.01: the immediate-entry attempt for this attach has run
string GVStreak, GVPaper, GVHalt, GVPapDir, GVPapPrice, GVPapTime;

//+------------------------------------------------------------------+
double PipSize()
{
   // Symbol-aware pip sizes (price units): gold 1 pip = 0.10, BTC 1 pip = 1.00
   if(StringFind(_Symbol, "XAU") >= 0) return 0.10;
   if(StringFind(_Symbol, "BTC") >= 0) return 1.00;
   if(_Digits == 3 || _Digits == 5) return _Point * 10.0;
   return _Point;
}

//+------------------------------------------------------------------+
bool IsNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime ds = StructToTime(dt);
   if(ds != DayStart) { DayStart = ds; return true; }
   return false;
}

//+------------------------------------------------------------------+
void RefreshDayStats()
{
   TradesToday = 0;
   if(!HistorySelect(DayStart, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         TradesToday++;
   }
}

//+------------------------------------------------------------------+
// Count today's CLOSED trades that meet the bonus qualifying tests:
// >= 0.10 lot, held >= 180 s, |close-open| >= 5 pips.
//+------------------------------------------------------------------+
int QualifyingTradesToday()
{
   int count = 0;
   if(!HistorySelect(DayStart, TimeCurrent())) return 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong outTicket = HistoryDealGetTicket(i);
      if(outTicket == 0) continue;
      if(HistoryDealGetInteger(outTicket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(outTicket, DEAL_SYMBOL) != _Symbol) continue;
      long entry = HistoryDealGetInteger(outTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      long posId = HistoryDealGetInteger(outTicket, DEAL_POSITION_ID);
      // find the opening deal of this position
      datetime openTime = 0; double openPrice = 0; double volume = 0;
      for(int j = 0; j < total; j++)
      {
         ulong t = HistoryDealGetTicket(j);
         if(t == 0) continue;
         if(HistoryDealGetInteger(t, DEAL_POSITION_ID) != posId) continue;
         if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            openTime  = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
            openPrice = HistoryDealGetDouble(t, DEAL_PRICE);
            volume    = HistoryDealGetDouble(t, DEAL_VOLUME);
            break;
         }
      }
      if(openTime == 0) continue;
      datetime closeTime = (datetime)HistoryDealGetInteger(outTicket, DEAL_TIME);
      double closePrice  = HistoryDealGetDouble(outTicket, DEAL_PRICE);
      if(closeTime - openTime < InpMinHoldSeconds) continue;
      if(MathAbs(closePrice - openPrice) < InpMinMovePips * PipValue) continue;
      if(volume < 0.10 - 0.001) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool InNewsWindow()
{
   if(StringLen(InpNewsTimes) == 0) return false;
   string parts[];
   int n = StringSplit(InpNewsTimes, ',', parts);
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   int nowMin = dt.hour * 60 + dt.min;
   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      int colon = StringFind(p, ":");
      if(colon < 0) continue;
      int hh = (int)StringToInteger(StringSubstr(p, 0, colon));
      int mm = (int)StringToInteger(StringSubstr(p, colon + 1));
      int newsMin = hh * 60 + mm;
      if(MathAbs(nowMin - newsMin) <= InpNewsAvoidMin) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool OurPositionOpen(ulong &ticket, long &type, double &openPrice, datetime &openTime, double &sl)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      type      = PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      openTime  = (datetime)PositionGetInteger(POSITION_TIME);
      sl        = PositionGetDouble(POSITION_SL);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(minV, MathMin(maxV, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
// Compounding, the tame version of the video's lot escalation:
// the lot grows only from REALISED balance growth, in small steps,
// and is hard-capped by InpMaxLot. Never scales inside a drawdown.
//+------------------------------------------------------------------+
double EffectiveLot()
{
   double lot = InpLot;
   if(InpLotPerStep > 0 && InpCompoundStepUsd > 0)
   {
      double growth = AccountInfoDouble(ACCOUNT_BALANCE) - StartBalance;
      if(growth > 0)
      {
         int steps = (int)MathFloor(growth / InpCompoundStepUsd);
         lot += steps * InpLotPerStep;
      }
   }
   lot = MathMin(lot, InpMaxLot);
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
datetime LastCloseTimeToday()
{
   datetime last = 0;
   if(!HistorySelect(DayStart, TimeCurrent())) return 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(t > last) last = t;
   }
   return last;
}

//+------------------------------------------------------------------+
// Nyao-style trend score, -10..+10, computed on CLOSED M5 bars.
// Components (all ATR-normalised, so the same code serves XAU+BTC):
//   range position of the close inside the 200-bar range .... 0..3
//   distance of the close from EMA200, in ATRs .............. 0..3
//   100-bar efficiency ratio (net move / path length) ....... 0..2
//   192-bar momentum, in ATRs ............................... 0..2
// Sign: direction the components agree on (close vs EMA200 and
// momentum must not contradict; momentum breaks the tie).
//+------------------------------------------------------------------+
int TrendScore()
{
   const int need = 210;
   double closes[], highs[], lows[];
   if(CopyClose(_Symbol, PERIOD_M5, 0, need, closes) < need) return 0;
   if(CopyHigh (_Symbol, PERIOD_M5, 0, need, highs)  < need) return 0;
   if(CopyLow  (_Symbol, PERIOD_M5, 0, need, lows)   < need) return 0;
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(highs,  true);
   ArraySetAsSeries(lows,   true);

   double atrBuf[];
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) < 1 || atrBuf[0] <= 0) return 0;
   double atr = atrBuf[0];

   double emaBuf[];
   if(CopyBuffer(hEMA200, 0, 1, 1, emaBuf) < 1) return 0;
   double ema200 = emaBuf[0];

   double c = closes[1]; // last closed bar
   double mom = c - closes[193]; // 192-bar momentum

   int dir;
   if(c >= ema200 && mom >= 0) dir = 1;
   else if(c <= ema200 && mom <= 0) dir = -1;
   else dir = (mom >= 0) ? 1 : -1;

   // 1) range position, measured in the trend's favour
   int hiIdx = ArrayMaximum(highs, 1, 200);
   int loIdx = ArrayMinimum(lows,  1, 200);
   double range = highs[hiIdx] - lows[loIdx];
   double rangePos = (range > 0) ? (c - lows[loIdx]) / range : 0.5;
   if(dir < 0) rangePos = 1.0 - rangePos;
   int sRange = (int)MathRound(rangePos * 3.0);

   // 2) EMA200 distance in ATRs (6+ ATRs = full marks)
   double emaDist = MathAbs(c - ema200) / atr;
   int sEma = (int)MathRound(MathMin(emaDist, 6.0) / 6.0 * 3.0);

   // 3) efficiency ratio over 100 bars
   double path = 0;
   for(int i = 1; i <= 100; i++) path += MathAbs(closes[i] - closes[i + 1]);
   double er = (path > 0) ? MathAbs(closes[1] - closes[101]) / path : 0;
   int sEff = (int)MathRound(MathMin(er, 1.0) * 2.0);

   // 4) momentum in ATRs (4+ ATRs = full marks)
   int sMom = (int)MathRound(MathMin(MathAbs(mom) / atr, 4.0) / 4.0 * 2.0);

   int total = sRange + sEma + sEff + sMom; // 0..10
   return dir * total;
}

//+------------------------------------------------------------------+
// D1 gate: +1 = uptrend (longs only), -1 = downtrend (shorts only),
// 0 = no clear daily trend (stay out). Trend is "clear" only when
// the daily close sits at least InpD1BandPct % away from EMA50(D1).
//+------------------------------------------------------------------+
int D1Gate()
{
   double emaBuf[];
   if(CopyBuffer(hEMAD1, 0, 1, 1, emaBuf) < 1) return 0;
   double closes[];
   if(CopyClose(_Symbol, PERIOD_D1, 0, 2, closes) < 2) return 0;
   ArraySetAsSeries(closes, true);
   double c = closes[1]; // last closed day
   if(c <= 0) return 0;
   double devPct = (c - emaBuf[0]) / c * 100.0;
   if(devPct >=  InpD1BandPct) return 1;
   if(devPct <= -InpD1BandPct) return -1;
   return 0;
}

//+------------------------------------------------------------------+
// Loss streak: consecutive losing closes (newest first) among our
// own deals, plus the time of the most recent losing close.
// Persisted to a global variable so a re-attach keeps the count.
//+------------------------------------------------------------------+
int LossStreak(datetime &lastLossTime)
{
   lastLossTime = 0;
   int streak = 0;
   if(!HistorySelect(0, TimeCurrent())) return 0;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(profit < 0)
      {
         streak++;
         if(lastLossTime == 0)
            lastLossTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      }
      else break; // a non-losing close ends the streak
   }
   return streak;
}

//+------------------------------------------------------------------+
bool PaperMode()
{
   return GlobalVariableCheck(GVPaper) && GlobalVariableGet(GVPaper) > 0.5;
}

//+------------------------------------------------------------------+
// Paper-only mode bookkeeping: a virtual position is tracked from
// the signal price; a virtual WIN (price reaches +safety-TP pips
// before -SL pips, judged on the live tick) clears paper mode and
// the loss streak. A virtual loss just clears the virtual position.
//+------------------------------------------------------------------+
void PaperOnTick(const MqlTick &tick, int score, int gate)
{
   bool hasVirtual = GlobalVariableCheck(GVPapDir) && GlobalVariableGet(GVPapDir) != 0;
   if(hasVirtual)
   {
      int    vdir   = (int)GlobalVariableGet(GVPapDir);
      double vprice = GlobalVariableGet(GVPapPrice);
      double fav = (vdir > 0) ? (tick.bid - vprice) / PipValue
                              : (vprice - tick.ask) / PipValue;
      double adv = (vdir > 0) ? (vprice - tick.ask) / PipValue
                              : (tick.bid - vprice) / PipValue;
      if(fav >= InpSafetyTPPips && InpSafetyTPPips > 0)
      {
         Print("PalmScalper paper WIN — back to LIVE, streak cleared");
         GlobalVariableSet(GVPaper, 0);
         GlobalVariableSet(GVPapDir, 0);
         GlobalVariableSet(GVStreak, 0);
      }
      else if(adv >= InpStopLossPips)
      {
         Print("PalmScalper paper loss — staying in paper mode");
         GlobalVariableSet(GVPapDir, 0);
      }
      return;
   }
   // no virtual position: would we enter here? (same signal as live)
   if(gate != 0 && MathAbs(score) >= InpMinScore && (score > 0 ? 1 : (score < 0 ? -1 : 0)) == gate)
   {
      int vdir = (score > 0) ? 1 : -1;
      double vprice = (vdir > 0) ? tick.ask : tick.bid;
      GlobalVariableSet(GVPapDir, vdir);
      GlobalVariableSet(GVPapPrice, vprice);
      GlobalVariableSet(GVPapTime, (double)TimeCurrent());
      PrintFormat("PalmScalper paper entry %s at %.2f (score %d)", vdir > 0 ? "BUY" : "SELL", vprice, score);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   PipValue = PipSize();
   StartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   StartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   trade.SetExpertMagicNumber(InpMagic);
   hRSI    = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   hATR    = iATR(_Symbol, PERIOD_M5, 14);
   hEMA200 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);
   hEMAD1  = iMA(_Symbol, PERIOD_D1, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      hEMA200 == INVALID_HANDLE || hEMAD1 == INVALID_HANDLE)
      return INIT_FAILED;
   string base = StringFormat("PS.%I64d.%s.", InpMagic, _Symbol);
   GVStreak = base + "streak"; GVPaper = base + "paper"; GVHalt = base + "halt";
   GVPapDir = base + "papdir"; GVPapPrice = base + "papprice"; GVPapTime = base + "paptime";
   IsNewDay();
   DayPnLBase = AccountInfoDouble(ACCOUNT_BALANCE);
   RefreshDayStats();
   LastBarTime = iTime(_Symbol, PERIOD_M5, 0);
   PosTicketSeen = 0; PosCheckpoint = 0;
   ImmediateDone = false;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hRSI); IndicatorRelease(hATR);
   IndicatorRelease(hEMA200); IndicatorRelease(hEMAD1);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewDay())
   {
      DayPnLBase = AccountInfoDouble(ACCOUNT_BALANCE);
      RefreshDayStats();
      GlobalVariableSet(GVHalt, 0); // a fresh day clears the hard-stop halt
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double spreadPips = (tick.ask - tick.bid) / PipValue;

   // New M5 bar? Entries, streak refresh and paper signals run per-bar.
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   bool newBar = (barTime != LastBarTime);
   if(newBar) LastBarTime = barTime;

   ulong posTicket; long posType; double posOpen; datetime posTime; double posSL;
   bool havePos = OurPositionOpen(posTicket, posType, posOpen, posTime, posSL);
   if(!havePos) { PosTicketSeen = 0; PosCheckpoint = 0; }
   else if(posTicket != PosTicketSeen) { PosTicketSeen = posTicket; PosCheckpoint = 0; }

   // ---- Guard stack state ----
   datetime lastLossTime;
   int streak = LossStreak(lastLossTime);
   GlobalVariableSet(GVStreak, streak);
   if(streak >= InpStreakPaper && !PaperMode())
   {
      GlobalVariableSet(GVPaper, 1);
      PrintFormat("PalmScalper: %d straight losses — PAPER-ONLY mode until a paper win", streak);
   }
   bool paper = PaperMode();
   bool halted = GlobalVariableCheck(GVHalt) && GlobalVariableGet(GVHalt) > 0.5;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!halted && StartEquity > 0 && equity <= StartEquity * (1.0 - InpHardEquityStopPct / 100.0))
   {
      GlobalVariableSet(GVHalt, 1);
      halted = true;
      Print("PalmScalper: HARD EQUITY STOP — entries halted for the day");
   }
   bool streakCooldown = (streak >= InpStreakCooldown && lastLossTime > 0 &&
                          TimeCurrent() - lastLossTime < InpStreakCooldownMin * 60);

   int score = TrendScore();
   int gate  = D1Gate();

   // ---- Dashboard ----
   double dayPnL = AccountInfoDouble(ACCOUNT_BALANCE) - DayPnLBase;
   bool profitLocked = (InpDailyProfitLock > 0 && dayPnL >= InpDailyProfitLock);
   Comment(StringFormat("PalmScalper v2.01 | %s M5 | %s\nSpread: %.1f pips | Score: %+d | D1 gate: %s\nTrades today: %d/%d | Day P/L: $%.2f (limit -$%.2f, lock +$%.2f%s)\nLot now: %.2f | Streak: %d%s%s%s\nQualifying today: %d / 10 target",
                        _Symbol, paper ? "PAPER" : "LIVE", spreadPips, score,
                        gate > 0 ? "LONG" : (gate < 0 ? "SHORT" : "FLAT"),
                        TradesToday, InpMaxTradesPerDay,
                        dayPnL, InpDailyLossLimit, InpDailyProfitLock,
                        profitLocked ? " LOCKED" : "",
                        EffectiveLot(), streak,
                        streakCooldown ? " COOLDOWN" : "",
                        halted ? " HALTED" : "",
                        QualifyingTradesToday()));

   // ---- Manage the open position (every tick) ----
   if(havePos)
   {
      double profit = PositionGetDouble(POSITION_PROFIT);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      bool heldLongEnough = (TimeCurrent() - posTime) >= InpMinHoldSeconds;
      double movePips = (posType == POSITION_TYPE_BUY)
                        ? (tick.bid - posOpen) / PipValue
                        : (posOpen - tick.ask) / PipValue;
      int dirSign = (posType == POSITION_TYPE_BUY) ? 1 : -1;

      // Basket stop: floating loss at 8% of balance closes NOW.
      if(balance > 0 && profit <= -InpBasketStopPct / 100.0 * balance)
      {
         Print("PalmScalper: BASKET STOP — closing position");
         trade.PositionClose(posTicket);
         return;
      }

      // Blue-guard trailing (v1.11): once blue by >= InpTrailStartPips after
      // the min hold, pull the SL so the close stays blue AND qualifying.
      if(InpTrailStartPips > 0 && heldLongEnough && movePips >= InpTrailStartPips)
      {
         double tp = PositionGetDouble(POSITION_TP);
         long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
         double minGap = stopLevelPts * _Point + PipValue * 0.5;
         if(posType == POSITION_TYPE_BUY)
         {
            double want = MathMax(posOpen + InpTrailStartPips * PipValue,
                                  tick.bid - InpTrailDistancePips * PipValue);
            want = NormalizeDouble(want, _Digits);
            if(want > posSL + PipValue * 0.5 && tick.bid - want >= minGap)
               if(trade.PositionModify(posTicket, want, tp)) posSL = want;
         }
         else
         {
            double want = MathMin(posOpen - InpTrailStartPips * PipValue,
                                  tick.ask + InpTrailDistancePips * PipValue);
            want = NormalizeDouble(want, _Digits);
            if((posSL == 0 || want < posSL - PipValue * 0.5) && want - tick.ask >= minGap)
               if(trade.PositionModify(posTicket, want, tp)) posSL = want;
         }
      }

      // Early loser exit: the score has flipped hard against a LOSING
      // position — cut it instead of waiting for the stop.
      if(profit < 0 && dirSign * score <= -InpOppScoreExit)
      {
         PrintFormat("PalmScalper: early loser exit (score %+d against position)", score);
         trade.PositionClose(posTicket);
         return;
      }

      // Profit checkpoints: each new $ step re-checks the score. Agree ->
      // the blue-guard keeps locking and we ride; turned -> close, but
      // only once the close still satisfies the bonus hold/move rules.
      if(InpCheckpointUsd > 0 && profit > 0)
      {
         int ckpt = (int)MathFloor(profit / InpCheckpointUsd);
         if(ckpt > PosCheckpoint)
         {
            PosCheckpoint = ckpt;
            int aligned = dirSign * score;
            PrintFormat("PalmScalper: checkpoint $%d reached (profit $%.2f, aligned score %d)",
                        ckpt * (int)InpCheckpointUsd, profit, aligned);
            if(aligned < InpScoreAgree && heldLongEnough && MathAbs(movePips) >= InpMinMovePips)
            {
               Print("PalmScalper: score no longer agrees at checkpoint — closing");
               trade.PositionClose(posTicket);
               return;
            }
         }
      }
      return; // one position at a time
   }

   // ---- Immediate entry on activation (v2.01) ----
   // Owner's rule: "bot aktif" means a position opens at once, not
   // after waiting for a full signal. Direction still comes from the
   // analysis — the D1 gate first, the trend score as fallback —
   // and every guard (halt, paper, streak cooldown, day limits,
   // spread cap, news window) still applies. One attempt per attach;
   // the position is a normal PalmScalper position (own magic), so
   // the checkpoint exits and blue-guard trailing manage it as usual.
   if(InpImmediateEntry && !ImmediateDone)
   {
      ImmediateDone = true;
      if(!paper && !halted && !streakCooldown && TradesToday < InpMaxTradesPerDay &&
         dayPnL > -InpDailyLossLimit && !profitLocked &&
         spreadPips <= InpMaxSpreadPips && !InNewsWindow())
      {
         int dir = gate;
         if(dir == 0 && MathAbs(score) >= 3) dir = (score > 0) ? 1 : -1;
         if(dir != 0)
         {
            double slDistI = InpStopLossPips * PipValue;
            double tpDistI = InpSafetyTPPips * PipValue;
            double lotI = EffectiveLot();
            bool okI = false;
            if(dir > 0)
            {
               double slI = NormalizeDouble(tick.ask - slDistI, _Digits);
               double tpI = (InpSafetyTPPips > 0) ? NormalizeDouble(tick.ask + tpDistI, _Digits) : 0;
               okI = trade.Buy(lotI, _Symbol, tick.ask, slI, tpI, "PalmScalper immediate buy");
            }
            else
            {
               double slI = NormalizeDouble(tick.bid + slDistI, _Digits);
               double tpI = (InpSafetyTPPips > 0) ? NormalizeDouble(tick.bid - tpDistI, _Digits) : 0;
               okI = trade.Sell(lotI, _Symbol, tick.bid, slI, tpI, "PalmScalper immediate sell");
            }
            if(okI)
            {
               TradesToday++;
               PrintFormat("PalmScalper: IMMEDIATE entry %s (gate %+d, score %+d)",
                           dir > 0 ? "BUY" : "SELL", gate, score);
            }
            else
               PrintFormat("PalmScalper: immediate entry order failed: %s", trade.ResultRetcodeDescription());
         }
         else
            Print("PalmScalper: immediate entry skipped — no direction (D1 gate flat, score weak)");
      }
      else
         Print("PalmScalper: immediate entry skipped — a guard is active");
      return; // the attempt consumes this tick either way
   }

   // ---- Paper mode: track virtual trades, never send real orders ----
   if(paper)
   {
      if(newBar) PaperOnTick(tick, score, gate);
      return;
   }

   // ---- Entry gates ----
   if(!newBar) return; // entries are decided once per M5 bar
   if(halted) return;
   if(streakCooldown) return;
   if(TradesToday >= InpMaxTradesPerDay) return;
   if(dayPnL <= -InpDailyLossLimit) return;
   if(profitLocked) return;
   if(spreadPips > InpMaxSpreadPips) return;
   if(InNewsWindow()) return;
   datetime lastClose = LastCloseTimeToday();
   if(lastClose > 0 && TimeCurrent() - lastClose < InpReenterCooldownSec) return;

   // ---- Entry signal: score fires in the D1 gate's direction ----
   if(gate == 0) return;
   if(MathAbs(score) < InpMinScore) return;
   if((score > 0 ? 1 : (score < 0 ? -1 : 0)) != gate) return;

   double rsiBuf[];
   if(CopyBuffer(hRSI, 0, 1, 1, rsiBuf) < 1) return;
   double rsiNow = rsiBuf[0];

   double slDist = InpStopLossPips * PipValue;
   double tpDist = InpSafetyTPPips * PipValue;
   double lot = EffectiveLot();

   if(score > 0 && rsiNow < InpRSIBuyMax)
   {
      double sl = NormalizeDouble(tick.ask - slDist, _Digits);
      double tp = (InpSafetyTPPips > 0) ? NormalizeDouble(tick.ask + tpDist, _Digits) : 0;
      if(trade.Buy(lot, _Symbol, tick.ask, sl, tp, "PalmScalper buy"))
         TradesToday++;
   }
   else if(score < 0 && rsiNow > InpRSISellMin)
   {
      double sl = NormalizeDouble(tick.bid + slDist, _Digits);
      double tp = (InpSafetyTPPips > 0) ? NormalizeDouble(tick.bid - tpDist, _Digits) : 0;
      if(trade.Sell(lot, _Symbol, tick.bid, sl, tp, "PalmScalper sell"))
         TradesToday++;
   }
}
//+------------------------------------------------------------------+
