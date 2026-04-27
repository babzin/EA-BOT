
#property copyright "PriceAction EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

input group "=== SWING S/R DETECTION ==="
input int    InpSwingLookback  = 50;   // Bars to scan for swing highs/lows
input int    InpSwingStrength  = 3;    // Bars each side to confirm swing point
input double InpZoneBuffer_ATR = 0.3;  // Zone thickness as ATR multiplier
input double InpZoneEntry_ATR  = 0.5;  // Price must be within X ATR of zone

input group "=== PATTERN SETTINGS ==="
input bool   InpUsePinBar      = true;  // Trade Pin Bars
input bool   InpUseEngulfing   = true;  // Trade Engulfing candles
input bool   InpUseInsideBar   = true;  // Trade Inside Bar breakouts
input double InpPinWickRatio   = 2.0;   // Pin bar: wick must be X times body
input double InpPatternMinATR  = 0.3;   // Pattern body must be > X × ATR

input group "=== TREND FILTER ==="
input int    InpEMA_Period     = 50;    // EMA period for trend filter (H4)
input int    InpSwingCount     = 3;     // Number of swings to define trend

input group "=== ATR SETTINGS ==="
input int    InpATR_Period     = 14;    // ATR period
input double InpATR_SL_Multi   = 1.0;  // ATR multiplier for SL buffer
input double InpRR_Ratio       = 2.0;  // Risk:Reward ratio

input group "=== RISK MANAGEMENT ==="
input double InpRiskPercent    = 1.0;   // Risk % per trade
input bool   InpScaleOut       = true;  // Close 50% at 1× risk (scale out)
input int    InpBE_Pips        = 0;     // Manual BE pips (0 = use 1× risk)
input int    InpMaxTradesDay   = 3;     // Max trades per day
input int    InpMaxLossDay     = 2;     // Max losses per day

input group "=== SESSION FILTER (GMT) ==="
input int    InpLondonOpen     = 7;    // London open hour GMT
input int    InpLondonClose    = 10;   // London close hour GMT
input int    InpNYOpen         = 12;   // NY overlap open GMT
input int    InpNYClose        = 16;   // NY overlap close GMT

input group "=== NEWS FILTER ==="
input bool   InpUseNews        = true;  // Enable news filter
input int    InpNewsBefore     = 15;    // Minutes before news
input int    InpNewsAfter      = 15;    // Minutes after news

input group "=== MISC ==="
input ulong  InpMagic          = 505505; // Magic number
input ulong  InpSlippage       = 10;     // Slippage (points)
input long   InpMaxSpread      = 30;     // Max spread (points)
input bool   InpLogs           = true;   // Print debug logs

//+------------------------------------------------------------------+
//| STRUCTS                                                          |
//+------------------------------------------------------------------+

struct SwingLevel
  {
   double price;
   bool   isHigh;  // true=resistance, false=support
   int    barIdx;
  };

struct OpenTrade
  {
   ulong  ticket;
   bool   beSet;
   bool   scaled;
   double initialSL;
   double initialRisk;
  };

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

int    hEMA_H4    = INVALID_HANDLE;
int    hATR_H1    = INVALID_HANDLE;
int    hATR_Daily = INVALID_HANDLE;

double bEMA_H4[];
double bATR_H1[];
double bATR_Daily[];

SwingLevel gSwings[];    // Detected swing levels
OpenTrade  gTrades[];    // Active trades managed by EA

datetime gLastBarH1   = 0;
datetime gLastDay     = 0;
int      gTradesToday = 0;
int      gLossesToday = 0;

// News cache
struct NewsEvt { datetime time; };
NewsEvt  gNews[];
datetime gNewsFetched = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   hEMA_H4    = iMA(_Symbol, PERIOD_H4, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hATR_H1    = iATR(_Symbol, PERIOD_H1, InpATR_Period);
   hATR_Daily = iATR(_Symbol, PERIOD_D1, InpATR_Period);

   if(hEMA_H4 == INVALID_HANDLE || hATR_H1 == INVALID_HANDLE ||
      hATR_Daily == INVALID_HANDLE)
     {
      Print("ERROR: Indicator handle failed");
      return INIT_FAILED;
     }

   ArraySetAsSeries(bEMA_H4,    true);
   ArraySetAsSeries(bATR_H1,    true);
   ArraySetAsSeries(bATR_Daily, true);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("PriceAction EA initialized | ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEMA_H4    != INVALID_HANDLE) IndicatorRelease(hEMA_H4);
   if(hATR_H1    != INVALID_HANDLE) IndicatorRelease(hATR_H1);
   if(hATR_Daily != INVALID_HANDLE) IndicatorRelease(hATR_Daily);
  }

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDay();
   ManageTrades();  // BE + scale + trail on every tick

   // Entry logic fires only on new H1 bar
   datetime barH1 = iTime(_Symbol, PERIOD_H1, 0);
   if(barH1 == gLastBarH1) return;
   gLastBarH1 = barH1;

   // Daily limits
   if(gTradesToday >= InpMaxTradesDay) return;
   if(gLossesToday >= InpMaxLossDay)   return;

   // Only 1 open position at a time for this EA
   if(HasPosition()) return;

   // Filters
   if(!IsSession())  return;
   if(!SpreadOK())   return;
   if(InpUseNews && IsNearNews()) return;

   // Load indicators
   if(!LoadBuffers()) return;

   // Detect current swing levels from H4
   DetectSwings();

   // Evaluate confluences and fire signal
   int sig = Evaluate();
   if(sig ==  1) ExecuteBuy();
   if(sig == -1) ExecuteSell();
  }

//+------------------------------------------------------------------+
//| LOAD INDICATOR BUFFERS                                           |
//+------------------------------------------------------------------+
bool LoadBuffers()
  {
   if(CopyBuffer(hEMA_H4,    0, 0, 5, bEMA_H4)    < 5) return false;
   if(CopyBuffer(hATR_H1,    0, 0, 5, bATR_H1)    < 5) return false;
   if(CopyBuffer(hATR_Daily, 0, 0, 5, bATR_Daily) < 5) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| DETECT SWING HIGHS AND LOWS ON H4                               |
//| A swing high = bar whose high is the highest among N bars either |
//| side. Swing low = bar whose low is the lowest among N bars.      |
//+------------------------------------------------------------------+
void DetectSwings()
  {
   ArrayResize(gSwings, 0);
   int strength = InpSwingStrength;
   int lookback = InpSwingLookback;

   for(int i = strength; i < lookback - strength; i++)
     {
      double hi = iHigh(_Symbol, PERIOD_H4, i);
      double lo = iLow (_Symbol, PERIOD_H4, i);
      bool isSwingHigh = true;
      bool isSwingLow  = true;

      for(int k = 1; k <= strength; k++)
        {
         if(iHigh(_Symbol, PERIOD_H4, i - k) >= hi) { isSwingHigh = false; }
         if(iHigh(_Symbol, PERIOD_H4, i + k) >= hi) { isSwingHigh = false; }
         if(iLow (_Symbol, PERIOD_H4, i - k) <= lo) { isSwingLow  = false; }
         if(iLow (_Symbol, PERIOD_H4, i + k) <= lo) { isSwingLow  = false; }
        }

      if(isSwingHigh)
        {
         int sz = ArraySize(gSwings);
         ArrayResize(gSwings, sz + 1);
         gSwings[sz].price  = hi;
         gSwings[sz].isHigh = true;
         gSwings[sz].barIdx = i;
        }
      if(isSwingLow)
        {
         int sz = ArraySize(gSwings);
         ArrayResize(gSwings, sz + 1);
         gSwings[sz].price  = lo;
         gSwings[sz].isHigh = false;
         gSwings[sz].barIdx = i;
        }
     }
  }

//+------------------------------------------------------------------+
//| DETERMINE DAILY BIAS FROM SWING STRUCTURE                        |
//| Compares the last N swing highs and lows on H4                   |
//| HH + HL = Bull. LH + LL = Bear. Otherwise = Ranging (no trade)  |
//+------------------------------------------------------------------+
int GetDailyBias()
  {
   // Separate highs and lows
   double highs[], lows[];
   ArrayResize(highs, 0);
   ArrayResize(lows,  0);

   // gSwings are in order from most recent (low barIdx = recent)
   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      if(gSwings[i].isHigh)
        {
         int sz = ArraySize(highs);
         ArrayResize(highs, sz + 1);
         highs[sz] = gSwings[i].price;
        }
      else
        {
         int sz = ArraySize(lows);
         ArrayResize(lows, sz + 1);
         lows[sz] = gSwings[i].price;
        }
     }

   int n = InpSwingCount;
   if(ArraySize(highs) < n || ArraySize(lows) < n) return 0;

   // Check last N highs: are they making higher highs?
   bool hhPattern = true, lhPattern = true;
   for(int i = 0; i < n - 1; i++)
     {
      if(highs[i] <= highs[i+1]) hhPattern = false; // recent < older = NOT HH
      if(highs[i] >= highs[i+1]) lhPattern = false;
     }

   // Check last N lows
   bool hlPattern = true, llPattern = true;
   for(int i = 0; i < n - 1; i++)
     {
      if(lows[i] <= lows[i+1]) hlPattern = false;
      if(lows[i] >= lows[i+1]) llPattern = false;
     }

   if(hhPattern && hlPattern) return  1;  // Uptrend
   if(lhPattern && llPattern) return -1;  // Downtrend
   return 0;                               // Ranging
  }

//+------------------------------------------------------------------+
//| CHECK IF CURRENT H1 PRICE IS AT A KEY SWING ZONE                |
//| Returns the zone price if within ATR proximity, else 0           |
//+------------------------------------------------------------------+
double PriceAtZone(int direction)
  {
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   double atr     = bATR_H1[1];
   double thresh  = InpZoneEntry_ATR * atr;

   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      double zonePrice = gSwings[i].price;
      double dist      = MathAbs(h1Close - zonePrice);

      if(dist > thresh) continue;

      // For buy: price at a SUPPORT zone (swing low)
      if(direction == 1 && !gSwings[i].isHigh) return zonePrice;
      // For sell: price at a RESISTANCE zone (swing high)
      if(direction == -1 && gSwings[i].isHigh) return zonePrice;
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
//| FIND NEXT SWING LEVEL IN A DIRECTION (for TP placement)         |
//+------------------------------------------------------------------+
double NextSwingLevel(int direction, double entryPrice)
  {
   double best = 0.0;

   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      double zp = gSwings[i].price;
      if(direction == 1 && zp > entryPrice && !gSwings[i].isHigh)
        {
         // Looking for next resistance above entry for BUY TP
         if(best == 0.0 || zp < best) best = zp;
        }
      if(direction == -1 && zp < entryPrice && gSwings[i].isHigh)
        {
         // Looking for next support below entry for SELL TP
         if(best == 0.0 || zp > best) best = zp;
        }
     }
   return best;
  }

//+------------------------------------------------------------------+
//| DETECT PIN BAR ON H1 (bar 1 = last closed)                      |
//| Bull pin: long lower wick, small body near top, wick > body×ratio|
//| Bear pin: long upper wick, small body near bottom                |
//+------------------------------------------------------------------+
int DetectPinBar()
  {
   if(!InpUsePinBar) return 0;

   double o = iOpen (_Symbol, PERIOD_H1, 1);
   double h = iHigh (_Symbol, PERIOD_H1, 1);
   double l = iLow  (_Symbol, PERIOD_H1, 1);
   double c = iClose(_Symbol, PERIOD_H1, 1);
   double atr = bATR_H1[1];

   double body      = MathAbs(c - o);
   double upperWick = h - MathMax(o, c);
   double lowerWick = MathMin(o, c) - l;
   double totalRange = h - l;

   // Pattern body must be meaningful
   if(body < InpPatternMinATR * atr) return 0;
   // Total range must be meaningful
   if(totalRange < atr * 0.5) return 0;

   // Bullish pin bar: lower wick dominates, body in upper third
   bool bullPin = (lowerWick >= body * InpPinWickRatio) &&
                  (upperWick <= body * 0.5) &&
                  (MathMin(o,c) > l + totalRange * 0.5);

   // Bearish pin bar: upper wick dominates, body in lower third
   bool bearPin = (upperWick >= body * InpPinWickRatio) &&
                  (lowerWick <= body * 0.5) &&
                  (MathMax(o,c) < l + totalRange * 0.5);

   if(bullPin) return  1;
   if(bearPin) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| DETECT ENGULFING BAR ON H1                                      |
//| Strict: body-to-body engulf (current body wraps previous body)   |
//+------------------------------------------------------------------+
int DetectEngulfing()
  {
   if(!InpUseEngulfing) return 0;

   double o1 = iOpen (_Symbol, PERIOD_H1, 1);
   double c1 = iClose(_Symbol, PERIOD_H1, 1);
   double o2 = iOpen (_Symbol, PERIOD_H1, 2);
   double c2 = iClose(_Symbol, PERIOD_H1, 2);
   double atr = bATR_H1[1];

   double body1 = MathAbs(c1 - o1);
   double body2 = MathAbs(c2 - o2);

   if(body1 < InpPatternMinATR * atr) return 0;
   if(body2 < InpPatternMinATR * atr * 0.3) return 0;

   // Bullish engulfing: bar2 red, bar1 green, bar1 body wraps bar2 body
   bool bullEngulf = (c2 < o2) && (c1 > o1) &&
                     (c1 > o2) && (o1 < c2);

   // Bearish engulfing: bar2 green, bar1 red, bar1 body wraps bar2 body
   bool bearEngulf = (c2 > o2) && (c1 < o1) &&
                     (c1 < o2) && (o1 > c2);

   if(bullEngulf) return  1;
   if(bearEngulf) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| DETECT INSIDE BAR ON H1 — returns direction of breakout         |
//| Inside bar: bar1 range entirely within bar2 range               |
//| Entry on breakout of inside bar high (bull) or low (bear)        |
//+------------------------------------------------------------------+
int DetectInsideBar()
  {
   if(!InpUseInsideBar) return 0;

   double h1 = iHigh(_Symbol, PERIOD_H1, 1);
   double l1 = iLow (_Symbol, PERIOD_H1, 1);
   double h2 = iHigh(_Symbol, PERIOD_H1, 2);
   double l2 = iLow (_Symbol, PERIOD_H1, 2);
   double c0 = iClose(_Symbol, PERIOD_H1, 0); // Current developing bar

   bool isInsideBar = (h1 < h2) && (l1 > l2);
   if(!isInsideBar) return 0;

   // Breakout direction determined by current price vs inside bar range
   if(c0 > h1) return  1;  // Bullish breakout above inside bar high
   if(c0 < l1) return -1;  // Bearish breakout below inside bar low
   return 0;
  }

//+------------------------------------------------------------------+
//| MAIN EVALUATION — ALL 8 CONFLUENCES                             |
//+------------------------------------------------------------------+
int Evaluate()
  {
   // 1. Daily/H4 Bias from swing structure
   int bias = GetDailyBias();
   if(bias == 0)
     {
      if(InpLogs) Print("No clear swing bias — ranging market, skip");
      return 0;
     }

   // 2. EMA50 on H4 must agree with bias
   double h4Close = iClose(_Symbol, PERIOD_H4, 1);
   double ema50   = bEMA_H4[1];
   bool emaAgrees = (bias ==  1 && h4Close > ema50) ||
                    (bias == -1 && h4Close < ema50);
   if(!emaAgrees)
     {
      if(InpLogs) Print("EMA50 H4 does not agree with bias — skip");
      return 0;
     }

   // 3. Price must be at a key swing zone
   double zonePrice = PriceAtZone(bias);
   if(zonePrice == 0.0)
     {
      if(InpLogs) Print("Price not at key S/R zone — skip");
      return 0;
     }

   // 4. Pattern detection — any qualifying pattern in the bias direction
   int patternDir = 0;

   int pinDir    = DetectPinBar();
   int engulfDir = DetectEngulfing();
   int ibDir     = DetectInsideBar();

   if(pinDir    == bias) patternDir = bias;
   if(engulfDir == bias) patternDir = bias;
   if(ibDir     == bias) patternDir = bias;

   if(patternDir == 0)
     {
      if(InpLogs) Print("No valid pattern in trend direction — skip");
      return 0;
     }

   // 5. Price not overextended (H1 close must be within 2 ATR of EMA50 H4)
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   double distFromEMA = MathAbs(h1Close - ema50);
   if(distFromEMA > bATR_Daily[1] * 2.5)
     {
      if(InpLogs) Print("Price overextended from EMA — skip");
      return 0;
     }

   if(InpLogs)
      Print("SIGNAL CONFIRMED | Bias:", bias, " Zone:", zonePrice,
            " Pin:", pinDir, " Engulf:", engulfDir, " IB:", ibDir);

   return bias;
  }

//+------------------------------------------------------------------+
//| CALCULATE LOT SIZE                                               |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
  {
   if(slDist <= 0.0) return NormLots(0.01);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk    = balance * InpRiskPercent / 100.0;
   double tv      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pv      = (ts > 0.0) ? (tv / ts * _Point) : 0.0;
   if(pv <= 0.0) return NormLots(0.01);
   return NormLots(risk / (slDist / _Point * pv));
  }

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
//| EXECUTE BUY                                                      |
//+------------------------------------------------------------------+
void ExecuteBuy()
  {
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr  = bATR_H1[1];
   double barL = iLow(_Symbol, PERIOD_H1, 1);

   // SL behind the pattern bar low + ATR buffer
   double sl = NormalizeDouble(barL - InpATR_SL_Multi * atr, _Digits);
   double slDist = ask - sl;
   if(slDist <= 0.0) return;

   // TP: next swing resistance or RR ratio, whichever is closer
   double tpSwing = NextSwingLevel(1, ask);
   double tpRR    = NormalizeDouble(ask + slDist * InpRR_Ratio, _Digits);
   double tp      = (tpSwing > ask && tpSwing < tpRR) ? tpSwing : tpRR;

   double lots = CalcLots(slDist);

   if(InpLogs)
      Print("BUY | Ask:", ask, " SL:", sl, " TP:", tp,
            " Lots:", lots, " ATR:", atr);

   if(trade.Buy(lots, _Symbol, ask, sl, tp, "PA BUY"))
     {
      gTradesToday++;
      int sz = ArraySize(gTrades);
      ArrayResize(gTrades, sz + 1);
      gTrades[sz].ticket      = trade.ResultOrder();
      gTrades[sz].beSet       = false;
      gTrades[sz].scaled      = false;
      gTrades[sz].initialSL   = sl;
      gTrades[sz].initialRisk = slDist;
     }
   else
      Print("BUY error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| EXECUTE SELL                                                     |
//+------------------------------------------------------------------+
void ExecuteSell()
  {
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr  = bATR_H1[1];
   double barH = iHigh(_Symbol, PERIOD_H1, 1);

   // SL behind pattern bar high + ATR buffer
   double sl = NormalizeDouble(barH + InpATR_SL_Multi * atr, _Digits);
   double slDist = sl - bid;
   if(slDist <= 0.0) return;

   double tpSwing = NextSwingLevel(-1, bid);
   double tpRR    = NormalizeDouble(bid - slDist * InpRR_Ratio, _Digits);
   double tp      = (tpSwing < bid && tpSwing > tpRR) ? tpSwing : tpRR;

   double lots = CalcLots(slDist);

   if(InpLogs)
      Print("SELL | Bid:", bid, " SL:", sl, " TP:", tp,
            " Lots:", lots, " ATR:", atr);

   if(trade.Sell(lots, _Symbol, bid, sl, tp, "PA SELL"))
     {
      gTradesToday++;
      int sz = ArraySize(gTrades);
      ArrayResize(gTrades, sz + 1);
      gTrades[sz].ticket      = trade.ResultOrder();
      gTrades[sz].beSet       = false;
      gTrades[sz].scaled      = false;
      gTrades[sz].initialSL   = sl;
      gTrades[sz].initialRisk = slDist;
     }
   else
      Print("SELL error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN TRADES: BREAKEVEN + SCALE OUT + TRAIL               |
//+------------------------------------------------------------------+
void ManageTrades()
  {
   for(int i = 0; i < ArraySize(gTrades); i++)
     {
      ulong ticket = gTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)posInfo.PositionType();
      double openP  = posInfo.PriceOpen();
      double curSL  = posInfo.StopLoss();
      double curTP  = posInfo.TakeProfit();
      double risk   = gTrades[i].initialRisk;
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lots   = posInfo.Volume();

      if(pt == POSITION_TYPE_BUY)
        {
         double profit = bid - openP;

         // Scale out 50% at 1× risk
         if(InpScaleOut && !gTrades[i].scaled && profit >= risk)
           {
            double halfLots = NormLots(lots * 0.5);
            if(halfLots >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
              {
               trade.PositionClosePartial(ticket, halfLots);
               gTrades[i].scaled = true;
               if(InpLogs) Print("BUY scaled out 50% at +", profit / _Point, " pts");
              }
           }

         // Breakeven at 1× risk
         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP + 2 * _Point, _Digits);
            if(newSL > curSL)
              {
               trade.PositionModify(ticket, newSL, curTP);
               gTrades[i].beSet = true;
               if(InpLogs) Print("BUY breakeven set: SL->", newSL);
              }
           }

         // Trail at 1.5× risk: trail by recent swing low
         if(profit >= risk * 1.5)
           {
            // Trail SL to 1.0× ATR below current bid
            double newSL = NormalizeDouble(bid - bATR_H1[0] * 1.0, _Digits);
            if(newSL > curSL && newSL < bid)
              {
               trade.PositionModify(ticket, newSL, curTP);
               if(InpLogs) Print("BUY trail: SL->", newSL);
              }
           }
        }

      else if(pt == POSITION_TYPE_SELL)
        {
         double profit = openP - ask;

         // Scale out 50% at 1× risk
         if(InpScaleOut && !gTrades[i].scaled && profit >= risk)
           {
            double halfLots = NormLots(lots * 0.5);
            if(halfLots >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
              {
               trade.PositionClosePartial(ticket, halfLots);
               gTrades[i].scaled = true;
               if(InpLogs) Print("SELL scaled out 50% at +", profit / _Point, " pts");
              }
           }

         // Breakeven
         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP - 2 * _Point, _Digits);
            if(newSL < curSL)
              {
               trade.PositionModify(ticket, newSL, curTP);
               gTrades[i].beSet = true;
               if(InpLogs) Print("SELL breakeven set: SL->", newSL);
              }
           }

         // Trail at 1.5× risk
         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(ask + bATR_H1[0] * 1.0, _Digits);
            if(newSL < curSL && newSL > ask)
              {
               trade.PositionModify(ticket, newSL, curTP);
               if(InpLogs) Print("SELL trail: SL->", newSL);
              }
           }
        }
     }

   // Clean up closed trades from array
   for(int i = ArraySize(gTrades) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(gTrades[i].ticket))
        {
         // Compact array
         for(int j = i; j < ArraySize(gTrades) - 1; j++)
            gTrades[j] = gTrades[j+1];
         ArrayResize(gTrades, ArraySize(gTrades) - 1);
        }
     }
  }

//+------------------------------------------------------------------+
//| TRACK LOSSES VIA DEAL HISTORY                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if(deal == 0) return;

   if(HistoryDealSelect(deal))
     {
      long   magic  = HistoryDealGetInteger(deal, DEAL_MAGIC);
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      long   entry  = HistoryDealGetInteger(deal, DEAL_ENTRY);

      if(magic == (long)InpMagic && entry == DEAL_ENTRY_OUT && profit < 0.0)
        {
         gLossesToday++;
         if(InpLogs) Print("Loss #", gLossesToday, " today | P&L: ", profit);
        }
     }
  }

//+------------------------------------------------------------------+
//| RESET DAILY COUNTERS ON NEW DAY                                  |
//+------------------------------------------------------------------+
void ResetDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   if(today != gLastDay)
     {
      gLastDay      = today;
      gTradesToday  = 0;
      gLossesToday  = 0;
      if(InpLogs) Print("New trading day — counters reset");
     }
  }

//+------------------------------------------------------------------+
//| CHECK FOR OPEN POSITION                                          |
//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            return true;
   return false;
  }

//+------------------------------------------------------------------+
//| SESSION FILTER (GMT)                                             |
//+------------------------------------------------------------------+
bool IsSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   return (h >= InpLondonOpen && h < InpLondonClose) ||
          (h >= InpNYOpen     && h < InpNYClose);
  }

//+------------------------------------------------------------------+
//| SPREAD FILTER                                                    |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > InpMaxSpread)
     {
      if(InpLogs) Print("Spread too high: ", sp);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| NEWS FILTER (MT5 Economic Calendar — HIGH impact only)          |
//+------------------------------------------------------------------+
bool IsNearNews()
  {
   datetime now = TimeCurrent();
   if(now - gNewsFetched > 3600 || ArraySize(gNews) == 0)
     {
      FetchNews();
      gNewsFetched = now;
     }
   int bufB = InpNewsBefore * 60;
   int bufA = InpNewsAfter  * 60;
   for(int i = 0; i < ArraySize(gNews); i++)
      if(now >= gNews[i].time - bufB && now <= gNews[i].time + bufA)
         return true;
   return false;
  }

void FetchNews()
  {
   ArrayResize(gNews, 0);
   string base  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   datetime from = TimeCurrent();
   datetime to   = from + 86400;

   MqlCalendarValue vals[];
   int cnt = CalendarValueHistory(vals, from, to, NULL, NULL);
   if(cnt <= 0) return;

   for(int i = 0; i < cnt; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      MqlCalendarCountry cc;
      if(!CalendarCountryById(ev.country_id, cc)) continue;
      if(cc.currency != base && cc.currency != quote) continue;
      int sz = ArraySize(gNews);
      ArrayResize(gNews, sz + 1);
      gNews[sz].time = vals[i].time;
     }

   if(InpLogs) Print("News loaded: ", ArraySize(gNews), " high-impact events");
  }

//+------------------------------------------------------------------+
//| END                                                              |
//+------------------------------------------------------------------+
