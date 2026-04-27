

#property copyright "TrendPullback EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

input group "=== EMA SETTINGS ==="
input int  InpEmaFast = 20;   // Fast EMA period (H1 + M15)
input int  InpEmaSlow = 50;   // Slow EMA period (H1 only)

input group "=== RISK MANAGEMENT ==="
input double InpRiskPercent = 1.0;   // Risk % of balance per trade
input double InpRR_Multiple = 2.0;   // Risk:Reward ratio
input int    InpFixedSL     = 15;    // Stop Loss in pips
input int    InpMinSL_Pips  = 10;    // Minimum SL in pips
input int    InpMaxSL_Pips  = 25;    // Maximum SL in pips
input int    InpBE_Pips     = 15;    // Breakeven trigger (pips profit)
input int    InpTrailActivate = 22;  // Trail activation (pips profit)
input int    InpTrailPips   = 10;    // Trail distance (pips)

input group "=== SESSION FILTER (GMT) ==="
input int  InpLondonStart  = 7;    // London session start (GMT hour)
input int  InpLondonEnd    = 10;   // London session end (GMT hour)
input int  InpOverlapStart = 12;   // NY Overlap start (GMT hour)
input int  InpOverlapEnd   = 16;   // NY Overlap end (GMT hour)

input group "=== SPREAD LIMITS (pips × 10 for 5-digit) ==="
input double InpSpreadEURUSD = 1.5;  // EURUSD max spread (pips)
input double InpSpreadGBPUSD = 2.0;  // GBPUSD max spread (pips)
input double InpSpreadUSDJPY = 1.8;  // USDJPY max spread (pips)
input double InpSpreadDefault= 2.5;  // Default max spread (pips)

input group "=== TRADE LIMITS ==="
input int  InpMaxTradesDay  = 2;   // Max trades per day
input int  InpMaxLossDay    = 2;   // Max losses per day

input group "=== NEWS FILTER ==="
input bool InpUseNewsFilter = true;   // Enable news filter
input int  InpNewsBefore    = 15;     // Minutes before news to pause
input int  InpNewsAfter     = 15;     // Minutes after news to pause

input group "=== MISC ==="
input ulong InpMagicNumber = 404404;  // Magic number
input ulong InpSlippage    = 10;      // Max slippage (points)
input bool  InpPrintLogs   = true;    // Print debug logs

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

// EMA handles
int hEMA20_H1  = INVALID_HANDLE;
int hEMA50_H1  = INVALID_HANDLE;
int hEMA20_M15 = INVALID_HANDLE;

// Buffers
double bEMA20_H1[],  bEMA50_H1[];
double bEMA20_M15[];

// Daily counters (reset each new day)
datetime gLastDay     = 0;
int      gTradesToday = 0;
int      gLossesToday = 0;

// Bar trackers
datetime gLastBarM5  = 0;
datetime gLastBarM15 = 0;
datetime gLastBarH1  = 0;

// Breakeven / trail tracking per ticket
struct TradeState
  {
   ulong  ticket;
   bool   beHit;
   bool   trailActive;
  };
TradeState gState;

// News event cache
struct NewsEvent
  {
   datetime time;
   bool     used;
  };
NewsEvent gNewsEvents[];
datetime  gLastNewsFetch = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   hEMA20_H1  = iMA(_Symbol, PERIOD_H1,  InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50_H1  = iMA(_Symbol, PERIOD_H1,  InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hEMA20_M15 = iMA(_Symbol, PERIOD_M15, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);

   if(hEMA20_H1 == INVALID_HANDLE || hEMA50_H1 == INVALID_HANDLE ||
      hEMA20_M15 == INVALID_HANDLE)
     {
      Print("ERROR: EMA handle creation failed");
      return INIT_FAILED;
     }

   ArraySetAsSeries(bEMA20_H1,  true);
   ArraySetAsSeries(bEMA50_H1,  true);
   ArraySetAsSeries(bEMA20_M15, true);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Init trade state
   gState.ticket      = 0;
   gState.beHit       = false;
   gState.trailActive = false;

   Print("TrendPullback EA initialized | ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEMA20_H1  != INVALID_HANDLE) IndicatorRelease(hEMA20_H1);
   if(hEMA50_H1  != INVALID_HANDLE) IndicatorRelease(hEMA50_H1);
   if(hEMA20_M15 != INVALID_HANDLE) IndicatorRelease(hEMA20_M15);
  }

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Reset daily counters on new day
   ResetDailyCounters();

   // Manage open position (BE + trail) on every tick
   ManageOpenPosition();

   // Only evaluate new entries on new M5 bar
   datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5 == gLastBarM5) return;
   gLastBarM5 = currentM5;

   // Skip if daily limits hit
   if(gTradesToday >= InpMaxTradesDay)
     {
      if(InpPrintLogs) Print("Max trades/day reached: ", gTradesToday);
      return;
     }
   if(gLossesToday >= InpMaxLossDay)
     {
      if(InpPrintLogs) Print("Max losses/day reached: ", gLossesToday);
      return;
     }

   // Skip if a position is already open on this symbol
   if(HasOpenPosition()) return;

   // Session filter
   if(!IsInSession())
     {
      if(InpPrintLogs) Print("Outside session hours");
      return;
     }

   // Spread filter
   if(!SpreadOK()) return;

   // News filter
   if(InpUseNewsFilter && IsNearNews())
     {
      if(InpPrintLogs) Print("News filter: skipping trade");
      return;
     }

   // Load EMA buffers
   if(!LoadBuffers()) return;

   // Evaluate signal
   int signal = GetSignal();
   if(signal ==  1) OpenBuy();
   if(signal == -1) OpenSell();
  }

//+------------------------------------------------------------------+
//| LOAD EMA BUFFERS                                                 |
//+------------------------------------------------------------------+
bool LoadBuffers()
  {
   if(CopyBuffer(hEMA20_H1,  0, 0, 4, bEMA20_H1)  < 4) return false;
   if(CopyBuffer(hEMA50_H1,  0, 0, 4, bEMA50_H1)  < 4) return false;
   if(CopyBuffer(hEMA20_M15, 0, 0, 4, bEMA20_M15) < 4) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| SIGNAL EVALUATION                                                |
//|                                                                  |
//| BUY:                                                             |
//|  Layer 1 (H1) : close[H1,1] > EMA20_H1 > EMA50_H1              |
//|  Layer 2 (M15): close[M15,1] > EMA20_M15 (pullback above EMA)   |
//|  Layer 3 (M5) : Bullish engulfing on bar 1 (last closed)         |
//|                                                                  |
//| SELL:                                                            |
//|  Layer 1 (H1) : close[H1,1] < EMA20_H1 < EMA50_H1              |
//|  Layer 2 (M15): close[M15,1] < EMA20_M15                        |
//|  Layer 3 (M5) : Bearish engulfing on bar 1                       |
//+------------------------------------------------------------------+
int GetSignal()
  {
   // --- H1 trend ---
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   double ema20h1 = bEMA20_H1[1];
   double ema50h1 = bEMA50_H1[1];

   bool h1Bull = (h1Close > ema20h1) && (ema20h1 > ema50h1);
   bool h1Bear = (h1Close < ema20h1) && (ema20h1 < ema50h1);

   if(!h1Bull && !h1Bear)
     {
      if(InpPrintLogs) Print("H1 no clear trend - skip");
      return 0;
     }

   // --- M15 pullback ---
   double m15Close = iClose(_Symbol, PERIOD_M15, 1);
   double ema20m15 = bEMA20_M15[1];

   bool m15Bull = (m15Close > ema20m15);
   bool m15Bear = (m15Close < ema20m15);

   // --- M5 engulfing ---
   // Bar 1 = last fully closed candle, Bar 2 = the one before it
   double m5_curr_open  = iOpen (_Symbol, PERIOD_M5, 1);
   double m5_curr_close = iClose(_Symbol, PERIOD_M5, 1);
   double m5_prev_open  = iOpen (_Symbol, PERIOD_M5, 2);
   double m5_prev_close = iClose(_Symbol, PERIOD_M5, 2);

   // Bullish engulfing:
   //   Current: close > open (green)
   //   Previous: close < open (red)
   //   Current close > previous open (fully engulfs)
   //   Current open < previous close (body wraps prior body)
   bool bullEngulf = (m5_curr_close > m5_curr_open)  &&
                     (m5_prev_close < m5_prev_open)   &&
                     (m5_curr_close > m5_prev_open)   &&
                     (m5_curr_open  < m5_prev_close);

   // Bearish engulfing (mirror)
   bool bearEngulf = (m5_curr_close < m5_curr_open)  &&
                     (m5_prev_close > m5_prev_open)   &&
                     (m5_curr_close < m5_prev_open)   &&
                     (m5_curr_open  > m5_prev_close);

   if(InpPrintLogs)
      Print("H1Bull:", h1Bull, " H1Bear:", h1Bear,
            " M15Bull:", m15Bull, " M15Bear:", m15Bear,
            " BullEngulf:", bullEngulf, " BearEngulf:", bearEngulf);

   // All 3 layers must align
   if(h1Bull && m15Bull && bullEngulf) return  1;
   if(h1Bear && m15Bear && bearEngulf) return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| CALCULATE SL IN PRICE DISTANCE                                   |
//+------------------------------------------------------------------+
double CalcSL_Distance()
  {
   // Clamp SL pips between min and max
   int slPips = InpFixedSL;
   slPips = (int)MathMax(InpMinSL_Pips, MathMin(InpMaxSL_Pips, slPips));

   // Convert pips to price distance
   // For JPY pairs: 1 pip = 0.01; for others: 1 pip = 0.0001
   // On 5-digit brokers _Point = 0.00001 → 1 pip = 10 * _Point
   double pipSize = GetPipSize();
   return slPips * pipSize;
  }

//+------------------------------------------------------------------+
//| GET PIP SIZE FOR THIS SYMBOL                                     |
//+------------------------------------------------------------------+
double GetPipSize()
  {
   // digits 3 or 5 → standard (0.0001 or 0.00001)
   // digits 2 or 4 → JPY style  (0.01 or 0.001)
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(d == 5 || d == 3) return 10.0 * _Point;
   if(d == 4 || d == 2) return 10.0 * _Point;
   return 10.0 * _Point; // safe fallback
  }

//+------------------------------------------------------------------+
//| CALCULATE LOT SIZE BASED ON RISK %                               |
//+------------------------------------------------------------------+
double CalcLots(double slDistance)
  {
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * InpRiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pntVal   = (tickSz > 0.0) ? (tickVal / tickSz * _Point) : 0.0;
   if(pntVal <= 0.0 || slDistance <= 0.0) return NormLots(0.01);

   double slPts = slDistance / _Point;
   double lots  = riskAmt / (slPts * pntVal);
   return NormLots(lots);
  }

//+------------------------------------------------------------------+
//| NORMALIZE LOTS                                                   |
//+------------------------------------------------------------------+
double NormLots(double lots)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0.0) return mn;
   lots = MathRound(lots / st) * st;
   return MathMax(mn, MathMin(mx, lots));
  }

//+------------------------------------------------------------------+
//| OPEN BUY                                                         |
//+------------------------------------------------------------------+
void OpenBuy()
  {
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slDist  = CalcSL_Distance();
   double sl      = NormalizeDouble(ask - slDist, _Digits);
   double tp      = NormalizeDouble(ask + slDist * InpRR_Multiple, _Digits);
   double lots    = CalcLots(slDist);

   if(InpPrintLogs)
      Print("OPEN BUY | Ask:", ask, " SL:", sl, " TP:", tp, " Lots:", lots);

   if(trade.Buy(lots, _Symbol, ask, sl, tp, "TrendPB BUY"))
     {
      gTradesToday++;
      gState.ticket      = trade.ResultOrder();
      gState.beHit       = false;
      gState.trailActive = false;
      Print("BUY opened. Trades today: ", gTradesToday);
     }
   else
      Print("BUY error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| OPEN SELL                                                        |
//+------------------------------------------------------------------+
void OpenSell()
  {
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = CalcSL_Distance();
   double sl     = NormalizeDouble(bid + slDist, _Digits);
   double tp     = NormalizeDouble(bid - slDist * InpRR_Multiple, _Digits);
   double lots   = CalcLots(slDist);

   if(InpPrintLogs)
      Print("OPEN SELL | Bid:", bid, " SL:", sl, " TP:", tp, " Lots:", lots);

   if(trade.Sell(lots, _Symbol, bid, sl, tp, "TrendPB SELL"))
     {
      gTradesToday++;
      gState.ticket      = trade.ResultOrder();
      gState.beHit       = false;
      gState.trailActive = false;
      Print("SELL opened. Trades today: ", gTradesToday);
     }
   else
      Print("SELL error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITION: BREAKEVEN + TRAILING STOP                 |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!PositionSelect(_Symbol)) return;
   if(posInfo.Magic() != InpMagicNumber) return;

   double pipSize    = GetPipSize();
   double openPrice  = posInfo.PriceOpen();
   double curSL      = posInfo.StopLoss();
   double curTP      = posInfo.TakeProfit();
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)posInfo.PositionType();

   double beDistance    = InpBE_Pips    * pipSize;
   double trailActivate = InpTrailActivate * pipSize;
   double trailDist     = InpTrailPips  * pipSize;

   if(posType == POSITION_TYPE_BUY)
     {
      double profit = bid - openPrice;

      // Breakeven: move SL to entry when profit >= BE distance
      if(!gState.beHit && profit >= beDistance)
        {
         double newSL = NormalizeDouble(openPrice + 1 * _Point, _Digits);
         if(newSL > curSL)
           {
            trade.PositionModify(_Symbol, newSL, curTP);
            gState.beHit = true;
            if(InpPrintLogs) Print("BUY breakeven set at ", newSL);
           }
        }

      // Trail: activate when profit >= trail activate distance
      if(profit >= trailActivate)
        {
         gState.trailActive = true;
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > curSL && newSL < bid)
           {
            trade.PositionModify(_Symbol, newSL, curTP);
            if(InpPrintLogs) Print("BUY trail: SL moved to ", newSL);
           }
        }
     }
   else if(posType == POSITION_TYPE_SELL)
     {
      double profit = openPrice - ask;

      // Breakeven
      if(!gState.beHit && profit >= beDistance)
        {
         double newSL = NormalizeDouble(openPrice - 1 * _Point, _Digits);
         if(newSL < curSL)
           {
            trade.PositionModify(_Symbol, newSL, curTP);
            gState.beHit = true;
            if(InpPrintLogs) Print("SELL breakeven set at ", newSL);
           }
        }

      // Trail
      if(profit >= trailActivate)
        {
         gState.trailActive = true;
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < curSL && newSL > ask)
           {
            trade.PositionModify(_Symbol, newSL, curTP);
            if(InpPrintLogs) Print("SELL trail: SL moved to ", newSL);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| RESET DAILY COUNTERS ON NEW DAY                                  |
//+------------------------------------------------------------------+
void ResetDailyCounters()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   if(todayStart != gLastDay)
     {
      gLastDay      = todayStart;
      gTradesToday  = 0;
      gLossesToday  = 0;
      if(InpPrintLogs) Print("New day — counters reset");
     }
  }

//+------------------------------------------------------------------+
//| TRACK CLOSED TRADE LOSSES VIA OnTradeTransaction                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   // Detect when a deal is executed (position closed)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      ulong dealTicket = trans.deal;
      if(dealTicket == 0) return;

      if(HistoryDealSelect(dealTicket))
        {
         long   magic   = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         double profit  = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         long   entry   = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

         // Only count closing deals (DEAL_ENTRY_OUT) for our magic number
         if(magic == (long)InpMagicNumber && entry == DEAL_ENTRY_OUT)
           {
            if(profit < 0.0)
              {
               gLossesToday++;
               if(InpPrintLogs)
                  Print("Loss recorded. Losses today: ", gLossesToday,
                        " | P&L: ", profit);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| CHECK IF A POSITION IS OPEN FOR THIS SYMBOL + MAGIC             |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| SESSION FILTER (GMT-based)                                       |
//+------------------------------------------------------------------+
bool IsInSession()
  {
   // Convert server time to GMT (assumes server = GMT; adjust if needed)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   bool london  = (h >= InpLondonStart  && h < InpLondonEnd);
   bool overlap = (h >= InpOverlapStart && h < InpOverlapEnd);
   return (london || overlap);
  }

//+------------------------------------------------------------------+
//| SPREAD FILTER (pair-specific)                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   double spreadPips = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / GetPipSize() * 10.0;

   double maxSpread = InpSpreadDefault;
   string sym = _Symbol;

   if(StringFind(sym, "EURUSD") >= 0) maxSpread = InpSpreadEURUSD;
   else if(StringFind(sym, "GBPUSD") >= 0) maxSpread = InpSpreadGBPUSD;
   else if(StringFind(sym, "USDJPY") >= 0) maxSpread = InpSpreadUSDJPY;

   // Raw spread in points / 10 gives pips (5-digit broker)
   double rawSpreadPips = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;

   if(rawSpreadPips > maxSpread)
     {
      if(InpPrintLogs)
         Print("Spread too high: ", rawSpreadPips, " pips > ", maxSpread);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| NEWS FILTER                                                      |
//| Reads MT5 calendar events for the current symbol's currencies    |
//| and blocks trading within InpNewsBefore/After minutes            |
//+------------------------------------------------------------------+
bool IsNearNews()
  {
   if(!InpUseNewsFilter) return false;

   datetime now = TimeCurrent();

   // Fetch calendar events once per hour
   if(now - gLastNewsFetch > 3600 || ArraySize(gNewsEvents) == 0)
     {
      FetchNewsEvents();
      gLastNewsFetch = now;
     }

   int bufBefore = InpNewsBefore * 60;
   int bufAfter  = InpNewsAfter  * 60;

   for(int i = 0; i < ArraySize(gNewsEvents); i++)
     {
      datetime nt = gNewsEvents[i].time;
      if(now >= nt - bufBefore && now <= nt + bufAfter)
        {
         if(InpPrintLogs)
            Print("News event at ", TimeToString(nt), " — trading paused");
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| FETCH NEWS EVENTS FROM MT5 ECONOMIC CALENDAR                    |
//+------------------------------------------------------------------+
void FetchNewsEvents()
  {
   ArrayResize(gNewsEvents, 0);

   // Get currency codes from symbol
   string base  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   datetime from = TimeCurrent();
   datetime to   = from + 86400; // next 24 hours

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, NULL, NULL);
   if(count <= 0) return;

   for(int i = 0; i < count; i++)
     {
      MqlCalendarEvent evInfo;
      if(!CalendarEventById(values[i].event_id, evInfo)) continue;

      // Only block HIGH importance events
      if(evInfo.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      // Only if the event currency matches our pair
      MqlCalendarCountry country;
      if(!CalendarCountryById(evInfo.country_id, country)) continue;

      string evCurrency = country.currency;
      if(evCurrency != base && evCurrency != quote) continue;

      // Add to our event list
      int sz = ArraySize(gNewsEvents);
      ArrayResize(gNewsEvents, sz + 1);
      gNewsEvents[sz].time = values[i].time;
      gNewsEvents[sz].used = false;
     }

   if(InpPrintLogs)
      Print("News events loaded: ", ArraySize(gNewsEvents),
            " high-impact events in next 24h");
  }

//+------------------------------------------------------------------+
//| END                                                              |
//+------------------------------------------------------------------+
