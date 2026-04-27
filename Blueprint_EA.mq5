

#property copyright "Blueprint EA"
#property version   "1.00"
#property strict
#property description "Full Blueprint EA — Multi-TF Trend + Key Level + Volume + Pattern"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

input group "=== IDENTIFICATION ==="
input ulong  InpMagic          = 919919;  // Magic number
input ulong  InpSlippage       = 10;      // Slippage in points

input group "=== EMA PERIODS ==="
input int    InpEMA20          = 20;      // EMA 20 period
input int    InpEMA50          = 50;      // EMA 50 period
input int    InpEMA200         = 200;     // EMA 200 period

input group "=== ADX ==="
input int    InpADX_Period     = 14;      // ADX period
input double InpADX_Threshold  = 25.0;   // ADX minimum for strong trend

input group "=== ATR ==="
input int    InpATR_Period     = 14;      // ATR period
input double InpATR_SL_Buffer  = 0.5;    // ATR buffer added to pattern SL
input double InpTrail_ATR      = 0.5;    // Trail distance (× ATR)

input group "=== KEY LEVEL DETECTION ==="
input int    InpSwingLookback  = 100;     // Bars for swing high/low detection
input int    InpSwingStrength  = 3;       // Bars each side to confirm swing
input double InpLevelBuffer_ATR= 0.3;    // Zone buffer around level (× ATR)
input bool   InpUseRoundNumbers= true;   // Detect round number levels
input double InpRoundStep      = 0.0050; // Round number step (0.005 for FX)
input bool   InpUsePDHL        = true;   // Use Previous Day High/Low

input group "=== VOLUME ==="
input int    InpVolMA_Period   = 20;      // Volume MA period
input double InpVolMultiplier  = 1.5;    // Volume spike threshold (× average)

input group "=== CANDLESTICK PATTERNS ==="
input bool   InpUsePinBar      = true;   // Trade Pin Bars
input bool   InpUseEngulfing   = true;   // Trade Engulfing candles
input bool   InpUseInsideBar   = true;   // Trade Inside Bar breakouts
input double InpPinWickRatio   = 2.0;    // Pin bar: wick ≥ X × body
input double InpMinBodyATR     = 0.15;   // Minimum pattern body (× ATR)

input group "=== CONFLUENCE ==="
input int    InpMinConfluence  = 3;      // Minimum confluence score (3-6)
input double InpEMA_ZonePct    = 0.1;    // % of price to be "near" EMA

input group "=== STOP LOSS / TAKE PROFIT ==="
input double InpMinSL_Points   = 100;    // Minimum SL distance (points)
input double InpMaxSL_Points   = 500;    // Maximum SL distance (points)
input double InpTP1_R          = 1.5;    // TP1 risk:reward
input double InpTP2_R          = 2.5;    // TP2 risk:reward

input group "=== RISK MANAGEMENT ==="
input double InpRiskPct        = 1.0;    // Risk % per trade
input int    InpMaxTradesDay   = 2;      // Max trades per day
input int    InpMaxLossDay     = 2;      // Max losses per day
input double InpDailyDD_Pct    = 5.0;   // Daily equity drawdown halt (%)
input int    InpConsecLossHalt = 3;      // Pause after N consecutive losses

input group "=== SESSION FILTER (GMT) ==="
input int    InpLondonStart    = 7;      // London open (GMT)
input int    InpLondonEnd      = 10;     // London close (GMT)
input int    InpNYStart        = 12;     // NY overlap open (GMT)
input int    InpNYEnd          = 16;     // NY overlap close (GMT)

input group "=== NEWS FILTER ==="
input bool   InpUseNewsFilter  = true;   // Enable news blackout
input int    InpNewsBefore     = 30;     // Minutes before news
input int    InpNewsAfter      = 30;     // Minutes after news

input group "=== SPREAD FILTER ==="
input double InpMaxSpreadPips  = 2.0;    // Max allowed spread in pips

//+------------------------------------------------------------------+
//| STRUCTS                                                          |
//+------------------------------------------------------------------+

// Tracks each open trade for BE and trailing management
struct ManagedTrade
  {
   ulong  ticket;
   bool   beSet;        // Breakeven triggered
   bool   tp1Hit;       // First partial close done
   double initialRisk;  // SL distance in price at entry
   double entryPrice;
   int    direction;    // 1=buy, -1=sell
  };

// Key price level (swing / round / PDH-PDL)
struct KeyLevel
  {
   double price;
   bool   isResistance; // true=above(resistance), false=below(support)
  };

// Simple news event
struct NewsEvent
  {
   datetime time;
  };

//+------------------------------------------------------------------+
//| INDICATOR HANDLES — all created once in OnInit                  |
//+------------------------------------------------------------------+

// Daily timeframe
int hEMA50_D   = INVALID_HANDLE;
int hEMA200_D  = INVALID_HANDLE;

// H4 timeframe
int hEMA50_H4  = INVALID_HANDLE;
int hEMA200_H4 = INVALID_HANDLE;

// H1 timeframe (structure + ADX)
int hEMA20_H1  = INVALID_HANDLE;
int hEMA50_H1  = INVALID_HANDLE;
int hADX_H1    = INVALID_HANDLE;

// M15 timeframe (entry)
int hEMA20_M15 = INVALID_HANDLE;
int hEMA50_M15 = INVALID_HANDLE;
int hATR_M15   = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| INDICATOR BUFFERS                                               |
//+------------------------------------------------------------------+
double bEMA50_D[],  bEMA200_D[];
double bEMA50_H4[], bEMA200_H4[];
double bEMA20_H1[], bEMA50_H1[];
double bADX_H1[], bDIPlus_H1[], bDIMinus_H1[];
double bEMA20_M15[], bEMA50_M15[];
double bATR_M15[];

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                    |
//+------------------------------------------------------------------+
ManagedTrade gTrades[];
KeyLevel     gLevels[];

datetime gLastBarM15    = 0;
datetime gLastDay       = 0;
int      gTradesToday   = 0;
int      gLossesToday   = 0;
int      gConsecLoss    = 0;
double   gDayStartEq    = 0;
bool     gDayHalted     = false;

// Previous Day High/Low
double   gPDH = 0, gPDL = 0;

// News cache
NewsEvent gNews[];
datetime  gNewsFetched  = 0;

// Dashboard state
string   gLastSignal    = "None";
string   gTrendBias     = "Undetermined";
string   gVolumeStatus  = "Normal";
string   gPatternFound  = "None";
double   gNearestLevel  = 0;

//+------------------------------------------------------------------+
//| PIP/POINT SIZE HELPERS                                          |
//+------------------------------------------------------------------+
double PipSize()
  {
   // 5-digit broker: 1 pip = 10 points
   return 10.0 * _Point;
  }

double PointsToPrice(double points) { return points * _Point; }

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Create all indicator handles (Blueprint Section 15) ---

   // Daily EMA 50 & 200
   hEMA50_D  = iMA(_Symbol, PERIOD_D1, InpEMA50,  0, MODE_EMA, PRICE_CLOSE);
   hEMA200_D = iMA(_Symbol, PERIOD_D1, InpEMA200, 0, MODE_EMA, PRICE_CLOSE);

   // H4 EMA 50 & 200
   hEMA50_H4  = iMA(_Symbol, PERIOD_H4, InpEMA50,  0, MODE_EMA, PRICE_CLOSE);
   hEMA200_H4 = iMA(_Symbol, PERIOD_H4, InpEMA200, 0, MODE_EMA, PRICE_CLOSE);

   // H1 EMA 20, 50 and ADX
   hEMA20_H1 = iMA(_Symbol, PERIOD_H1, InpEMA20, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50_H1 = iMA(_Symbol, PERIOD_H1, InpEMA50, 0, MODE_EMA, PRICE_CLOSE);
   hADX_H1   = iADX(_Symbol, PERIOD_H1, InpADX_Period);

   // M15 EMA 20, 50 and ATR
   hEMA20_M15 = iMA(_Symbol, PERIOD_M15, InpEMA20, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50_M15 = iMA(_Symbol, PERIOD_M15, InpEMA50, 0, MODE_EMA, PRICE_CLOSE);
   hATR_M15   = iATR(_Symbol, PERIOD_M15, InpATR_Period);

   // Validate all handles
   if(hEMA50_D   == INVALID_HANDLE || hEMA200_D  == INVALID_HANDLE ||
      hEMA50_H4  == INVALID_HANDLE || hEMA200_H4 == INVALID_HANDLE ||
      hEMA20_H1  == INVALID_HANDLE || hEMA50_H1  == INVALID_HANDLE ||
      hADX_H1    == INVALID_HANDLE || hEMA20_M15 == INVALID_HANDLE ||
      hEMA50_M15 == INVALID_HANDLE || hATR_M15   == INVALID_HANDLE)
     {
      Print("ERROR: One or more indicator handles failed to create.");
      return INIT_FAILED;
     }

   // Set all arrays as series (index 0 = most recent bar)
   ArraySetAsSeries(bEMA50_D,    true);
   ArraySetAsSeries(bEMA200_D,   true);
   ArraySetAsSeries(bEMA50_H4,   true);
   ArraySetAsSeries(bEMA200_H4,  true);
   ArraySetAsSeries(bEMA20_H1,   true);
   ArraySetAsSeries(bEMA50_H1,   true);
   ArraySetAsSeries(bADX_H1,     true);
   ArraySetAsSeries(bDIPlus_H1,  true);
   ArraySetAsSeries(bDIMinus_H1, true);
   ArraySetAsSeries(bEMA20_M15,  true);
   ArraySetAsSeries(bEMA50_M15,  true);
   ArraySetAsSeries(bATR_M15,    true);

   // Configure CTrade
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Initialise daily tracking
   gDayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("Blueprint EA initialised | ", _Symbol, " | ", EnumToString(_Period));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| DEINIT — Release all handles (Blueprint Section 16)             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEMA50_D   != INVALID_HANDLE) IndicatorRelease(hEMA50_D);
   if(hEMA200_D  != INVALID_HANDLE) IndicatorRelease(hEMA200_D);
   if(hEMA50_H4  != INVALID_HANDLE) IndicatorRelease(hEMA50_H4);
   if(hEMA200_H4 != INVALID_HANDLE) IndicatorRelease(hEMA200_H4);
   if(hEMA20_H1  != INVALID_HANDLE) IndicatorRelease(hEMA20_H1);
   if(hEMA50_H1  != INVALID_HANDLE) IndicatorRelease(hEMA50_H1);
   if(hADX_H1    != INVALID_HANDLE) IndicatorRelease(hADX_H1);
   if(hEMA20_M15 != INVALID_HANDLE) IndicatorRelease(hEMA20_M15);
   if(hEMA50_M15 != INVALID_HANDLE) IndicatorRelease(hEMA50_M15);
   if(hATR_M15   != INVALID_HANDLE) IndicatorRelease(hATR_M15);
   Comment(""); // Clear dashboard
  }

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Always manage open trades (BE + partial + trail) on every tick
   ResetDay();
   ManageTrades();
   DrawDashboard();

   // Entry logic fires only on new M15 bar close
   datetime curM15 = iTime(_Symbol, PERIOD_M15, 0);
   if(curM15 == gLastBarM15) return;
   gLastBarM15 = curM15;

   // Circuit breakers (Blueprint Section 12)
   if(gDayHalted)                         return;
   if(gTradesToday  >= InpMaxTradesDay)   return;
   if(gLossesToday  >= InpMaxLossDay)     return;
   if(gConsecLoss   >= InpConsecLossHalt) return;

   // Only 1 position per symbol (Blueprint Section 14)
   if(HasPosition()) return;

   // Session filter (Blueprint Section 13)
   if(!IsInSession()) return;

   // Spread filter (Blueprint Section 13)
   if(!SpreadOK()) return;

   // News filter (Blueprint Section 13)
   if(InpUseNewsFilter && IsNearNews()) return;

   // Load all indicator buffers
   if(!LoadBuffers()) return;

   // Detect key levels from H1 (Blueprint Section 4)
   DetectKeyLevels();

   // Update PDH/PDL (Blueprint Section 4)
   if(InpUsePDHL)
     {
      gPDH = iHigh(_Symbol, PERIOD_D1, 1);
      gPDL = iLow (_Symbol, PERIOD_D1, 1);
     }

   // Step 1: Determine HTF bias (Blueprint Section 3)
   int bias = GetHTFBias();
   gTrendBias = (bias ==  1) ? "BULLISH ↑" :
                (bias == -1) ? "BEARISH ↓" : "RANGING —";
   if(bias == 0) return; // No clear bias

   // Step 2: Evaluate confluence score (Blueprint Section 7)
   int buyScore = 0, sellScore = 0;
   EvaluateConfluence(bias, buyScore, sellScore);

   // Step 3: Fire entry if score meets minimum (Blueprint Section 7)
   if(bias ==  1 && buyScore  >= InpMinConfluence) ExecuteEntry( 1);
   if(bias == -1 && sellScore >= InpMinConfluence) ExecuteEntry(-1);
  }

//+------------------------------------------------------------------+
//| LOAD ALL INDICATOR BUFFERS                                      |
//+------------------------------------------------------------------+
bool LoadBuffers()
  {
   // Daily
   if(CopyBuffer(hEMA50_D,  0, 0, 3, bEMA50_D)  < 3) return false;
   if(CopyBuffer(hEMA200_D, 0, 0, 3, bEMA200_D) < 3) return false;

   // H4
   if(CopyBuffer(hEMA50_H4,  0, 0, 3, bEMA50_H4)  < 3) return false;
   if(CopyBuffer(hEMA200_H4, 0, 0, 3, bEMA200_H4) < 3) return false;

   // H1
   if(CopyBuffer(hEMA20_H1, 0, 0, 3, bEMA20_H1)   < 3) return false;
   if(CopyBuffer(hEMA50_H1, 0, 0, 3, bEMA50_H1)   < 3) return false;
   if(CopyBuffer(hADX_H1,   0, 0, 3, bADX_H1)     < 3) return false;
   if(CopyBuffer(hADX_H1,   1, 0, 3, bDIPlus_H1)  < 3) return false;
   if(CopyBuffer(hADX_H1,   2, 0, 3, bDIMinus_H1) < 3) return false;

   // M15
   if(CopyBuffer(hEMA20_M15, 0, 0, 3, bEMA20_M15) < 3) return false;
   if(CopyBuffer(hEMA50_M15, 0, 0, 3, bEMA50_M15) < 3) return false;
   if(CopyBuffer(hATR_M15,   0, 0, 3, bATR_M15)   < 3) return false;

   return true;
  }

//+------------------------------------------------------------------+
//| HTF BIAS — Daily + H4 EMA alignment (Blueprint Section 3)      |
//| Returns: 1=Bullish, -1=Bearish, 0=Undetermined                 |
//+------------------------------------------------------------------+
int GetHTFBias()
  {
   double closeD  = iClose(_Symbol, PERIOD_D1, 1);
   double closeH4 = iClose(_Symbol, PERIOD_H4, 1);

   // Blueprint: Uptrend = price > EMA50 AND EMA200 on BOTH Daily and H4
   bool dailyBull = (closeD  > bEMA50_D[1]  && closeD  > bEMA200_D[1]  &&
                     bEMA50_D[1]  > bEMA200_D[1]);
   bool dailyBear = (closeD  < bEMA50_D[1]  && closeD  < bEMA200_D[1]  &&
                     bEMA50_D[1]  < bEMA200_D[1]);

   bool h4Bull    = (closeH4 > bEMA50_H4[1] && closeH4 > bEMA200_H4[1] &&
                     bEMA50_H4[1] > bEMA200_H4[1]);
   bool h4Bear    = (closeH4 < bEMA50_H4[1] && closeH4 < bEMA200_H4[1] &&
                     bEMA50_H4[1] < bEMA200_H4[1]);

   // Require BOTH timeframes to agree for a clean bias
   if(dailyBull && h4Bull) return  1;
   if(dailyBear && h4Bear) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| KEY LEVEL DETECTION on H1 (Blueprint Section 4)                |
//| Detects swing highs/lows, round numbers, and PDH/PDL            |
//+------------------------------------------------------------------+
void DetectKeyLevels()
  {
   ArrayResize(gLevels, 0);
   int s  = InpSwingStrength;
   int lb = InpSwingLookback;

   // --- Swing Highs (Resistance) and Lows (Support) ---
   for(int i = s; i < lb - s; i++)
     {
      double hi = iHigh(_Symbol, PERIOD_H1, i);
      double lo = iLow (_Symbol, PERIOD_H1, i);
      bool isSwingHigh = true, isSwingLow = true;

      for(int k = 1; k <= s; k++)
        {
         if(iHigh(_Symbol, PERIOD_H1, i-k) >= hi ||
            iHigh(_Symbol, PERIOD_H1, i+k) >= hi) isSwingHigh = false;
         if(iLow (_Symbol, PERIOD_H1, i-k) <= lo ||
            iLow (_Symbol, PERIOD_H1, i+k) <= lo) isSwingLow  = false;
        }

      if(isSwingHigh) AddKeyLevel(hi, true);
      if(isSwingLow)  AddKeyLevel(lo, false);
     }

   // --- Previous Day High / Low ---
   if(InpUsePDHL)
     {
      AddKeyLevel(gPDH, true);   // PDH = resistance
      AddKeyLevel(gPDL, false);  // PDL = support
     }

   // --- Round Numbers (Blueprint Section 4) ---
   if(InpUseRoundNumbers && InpRoundStep > 0)
     {
      double mid   = (iHigh(_Symbol, PERIOD_D1, 0) + iLow(_Symbol, PERIOD_D1, 0)) / 2.0;
      double lower = MathFloor(mid / InpRoundStep) * InpRoundStep - InpRoundStep * 3;
      double upper = lower + InpRoundStep * 8;

      for(double lvl = lower; lvl <= upper; lvl += InpRoundStep)
        {
         double rounded = NormalizeDouble(lvl, _Digits);
         bool isRes = (rounded > mid);
         AddKeyLevel(rounded, isRes);
        }
     }
  }

//+------------------------------------------------------------------+
//| ADD A KEY LEVEL (avoids duplicates within ATR zone)             |
//+------------------------------------------------------------------+
void AddKeyLevel(double price, bool isResistance)
  {
   if(price <= 0) return;
   double atr = (ArraySize(bATR_M15) > 1) ? bATR_M15[1] : _Point * 100;
   double zone = atr * InpLevelBuffer_ATR;

   for(int i = 0; i < ArraySize(gLevels); i++)
      if(MathAbs(gLevels[i].price - price) < zone) return; // Duplicate

   int sz = ArraySize(gLevels);
   ArrayResize(gLevels, sz + 1);
   gLevels[sz].price        = price;
   gLevels[sz].isResistance = isResistance;
  }

//+------------------------------------------------------------------+
//| CHECK IF PRICE IS NEAR A KEY LEVEL (Blueprint Section 4)       |
//| Returns the closest level price, or 0.0 if not near any        |
//+------------------------------------------------------------------+
double PriceNearKeyLevel(int direction)
  {
   double price = iClose(_Symbol, PERIOD_M15, 1);
   double atr   = bATR_M15[1];
   double zone  = atr * InpLevelBuffer_ATR;
   double best  = 0.0;
   double bestDist = zone + 1;

   for(int i = 0; i < ArraySize(gLevels); i++)
     {
      double dist = MathAbs(price - gLevels[i].price);
      if(dist > zone) continue;

      // For buy: look for support levels (below or near price)
      // For sell: look for resistance levels (above or near price)
      bool relevant = (direction ==  1 && !gLevels[i].isResistance) ||
                      (direction == -1 &&  gLevels[i].isResistance);
      if(!relevant) continue;

      if(dist < bestDist) { bestDist = dist; best = gLevels[i].price; }
     }

   return best;
  }

//+------------------------------------------------------------------+
//| VOLUME SPIKE CHECK on M15 (Blueprint Section 5)                |
//| Returns true if bar[1] volume > InpVolMultiplier × 20-bar avg  |
//+------------------------------------------------------------------+
bool IsVolumeSpike()
  {
   // Collect volume data from M15
   long volArr[];
   ArraySetAsSeries(volArr, true);
   int copied = CopyTickVolume(_Symbol, PERIOD_M15, 0,
                               InpVolMA_Period + 2, volArr);
   if(copied < InpVolMA_Period + 2) return false;

   // Calculate 20-bar average (bars 2 to 21)
   double sum = 0;
   for(int i = 2; i < InpVolMA_Period + 2; i++)
      sum += (double)volArr[i];
   double avg = sum / InpVolMA_Period;

   bool spike = ((double)volArr[1] >= avg * InpVolMultiplier);
   gVolumeStatus = spike ? "SPIKE ✔" : "Normal";
   return spike;
  }

//+------------------------------------------------------------------+
//| CANDLESTICK PATTERN DETECTION on M15 (Blueprint Section 6)     |
//| Returns: 1=Bullish pattern, -1=Bearish pattern, 0=None         |
//+------------------------------------------------------------------+
int DetectPattern()
  {
   double o1 = iOpen (_Symbol, PERIOD_M15, 1); // Last closed bar
   double h1 = iHigh (_Symbol, PERIOD_M15, 1);
   double l1 = iLow  (_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double o2 = iOpen (_Symbol, PERIOD_M15, 2); // Bar before
   double h2 = iHigh (_Symbol, PERIOD_M15, 2);
   double l2 = iLow  (_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);
   double atr = bATR_M15[1];
   double minBody = InpMinBodyATR * atr;

   // --- ENGULFING (Blueprint Section 6) ---
   if(InpUseEngulfing)
     {
      double body1 = MathAbs(c1 - o1);
      double body2 = MathAbs(c2 - o2);
      if(body1 > minBody && body2 > 0)
        {
         // Bullish: current bar low < prev low, close > prev high
         bool bullEngulf = (l1 < l2 && c1 > h2 && c1 > o1 && c2 < o2);
         // Bearish: current bar high > prev high, close < prev low
         bool bearEngulf = (h1 > h2 && c1 < l2 && c1 < o1 && c2 > o2);

         if(bullEngulf) { gPatternFound = "Bull Engulf"; return  1; }
         if(bearEngulf) { gPatternFound = "Bear Engulf"; return -1; }
        }
     }

   // --- PIN BAR (Blueprint Section 6) ---
   if(InpUsePinBar)
     {
      double body      = MathAbs(c1 - o1);
      double upperWick = h1 - MathMax(o1, c1);
      double lowerWick = MathMin(o1, c1) - l1;
      double range     = h1 - l1;

      if(body > minBody && range > 0)
        {
         // Bullish pin: long lower wick (≥ 2× body), small upper wick, body near top
         bool bullPin = (lowerWick >= body * InpPinWickRatio) &&
                        (upperWick <= body) &&
                        (MathMin(o1,c1) > l1 + range * 0.5);

         // Bearish pin: long upper wick (≥ 2× body), small lower wick, body near bottom
         bool bearPin = (upperWick >= body * InpPinWickRatio) &&
                        (lowerWick <= body) &&
                        (MathMax(o1,c1) < l1 + range * 0.5);

         if(bullPin) { gPatternFound = "Bull Pin"; return  1; }
         if(bearPin) { gPatternFound = "Bear Pin"; return -1; }
        }
     }

   // --- INSIDE BAR (Blueprint Section 6) ---
   if(InpUseInsideBar)
     {
      bool isInside = (h1 < h2 && l1 > l2); // Current bar inside previous bar
      if(isInside)
        {
         // Breakout direction: use developing bar (bar 0) vs inside bar extremes
         double c0 = iClose(_Symbol, PERIOD_M15, 0);
         if(c0 > h1) { gPatternFound = "IB Break Up"; return  1; }
         if(c0 < l1) { gPatternFound = "IB Break Dn"; return -1; }
        }
     }

   gPatternFound = "None";
   return 0;
  }

//+------------------------------------------------------------------+
//| CHECK PRICE NEAR EMA (Blueprint Section 7e)                    |
//| Returns true if M15 close is within InpEMA_ZonePct of EMA      |
//+------------------------------------------------------------------+
bool PriceNearEMA(int direction)
  {
   double price  = iClose(_Symbol, PERIOD_M15, 1);
   double ema20  = bEMA20_M15[1];
   double ema50  = bEMA50_M15[1];
   double zone20 = ema20 * InpEMA_ZonePct / 100.0;
   double zone50 = ema50 * InpEMA_ZonePct / 100.0;

   bool nearEMA20 = MathAbs(price - ema20) <= zone20;
   bool nearEMA50 = MathAbs(price - ema50) <= zone50;

   if(!(nearEMA20 || nearEMA50)) return false;

   // Also confirm price is approaching from the correct side
   if(direction ==  1) return (price >= ema20 - zone20 || price >= ema50 - zone50);
   if(direction == -1) return (price <= ema20 + zone20 || price <= ema50 + zone50);
   return false;
  }

//+------------------------------------------------------------------+
//| CONFLUENCE EVALUATION (Blueprint Section 7)                    |
//| Scores 6 factors for both buy and sell direction                |
//+------------------------------------------------------------------+
void EvaluateConfluence(int bias, int &buyScore, int &sellScore)
  {
   buyScore  = 0;
   sellScore = 0;

   double m15Close = iClose(_Symbol, PERIOD_M15, 1);

   // --- a) Trend alignment ---
   if(bias ==  1) buyScore++;
   if(bias == -1) sellScore++;

   // --- b) Price at key level ---
   double nearBuyLevel  = PriceNearKeyLevel( 1);
   double nearSellLevel = PriceNearKeyLevel(-1);
   if(nearBuyLevel  > 0) { buyScore++;  gNearestLevel = nearBuyLevel;  }
   if(nearSellLevel > 0) { sellScore++; gNearestLevel = nearSellLevel; }

   // --- c) Volume spike ---
   bool volSpike = IsVolumeSpike();
   if(volSpike) { buyScore++; sellScore++; }

   // --- d) Candlestick pattern ---
   int pattern = DetectPattern();
   if(pattern ==  1) buyScore++;
   if(pattern == -1) sellScore++;

   // --- e) Price at EMA20 or EMA50 ---
   if(PriceNearEMA( 1)) buyScore++;
   if(PriceNearEMA(-1)) sellScore++;

   // --- f) ADX > 25 on H1 (optional, still scored) ---
   bool adxStrong = (bADX_H1[1] > InpADX_Threshold);
   if(adxStrong && bDIPlus_H1[1]  > bDIMinus_H1[1]) buyScore++;
   if(adxStrong && bDIMinus_H1[1] > bDIPlus_H1[1])  sellScore++;

   // Update dashboard
   gLastSignal = StringFormat("B:%d S:%d (need %d)", buyScore, sellScore,
                              InpMinConfluence);
  }

//+------------------------------------------------------------------+
//| LOT SIZE CALCULATION (Blueprint Section 12)                    |
//| Risk% of balance, adjusted for SL distance                     |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
  {
   if(slDist <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk    = balance * InpRiskPct / 100.0;
   double tv      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pv      = (ts > 0) ? tv / ts * _Point : 0.0;
   if(pv <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = risk / (slDist / _Point * pv);

   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) return mn;
   lots = MathRound(lots / st) * st;
   return MathMax(mn, MathMin(mx, lots));
  }

//+------------------------------------------------------------------+
//| EXECUTE ENTRY (Blueprint Sections 8–10)                        |
//| Market order with hard SL + TP1 (TP2 managed via trailing)     |
//+------------------------------------------------------------------+
void ExecuteEntry(int direction)
  {
   double atr   = bATR_M15[1];
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // SL: behind the pattern bar low/high + ATR buffer (Blueprint Section 9)
   double patBarLow  = iLow (_Symbol, PERIOD_M15, 1);
   double patBarHigh = iHigh(_Symbol, PERIOD_M15, 1);

   double sl, slDist;

   if(direction == 1) // Buy
     {
      sl     = NormalizeDouble(patBarLow - InpATR_SL_Buffer * atr, _Digits);
      slDist = ask - sl;
     }
   else // Sell
     {
      sl     = NormalizeDouble(patBarHigh + InpATR_SL_Buffer * atr, _Digits);
      slDist = sl - bid;
     }

   // Clamp SL to min/max (Blueprint Section 9)
   double minSL = InpMinSL_Points * _Point;
   double maxSL = InpMaxSL_Points * _Point;
   slDist = MathMax(minSL, MathMin(maxSL, slDist));

   if(direction ==  1) sl = NormalizeDouble(ask - slDist, _Digits);
   if(direction == -1) sl = NormalizeDouble(bid + slDist, _Digits);

   // TP1 = 1.5 × risk (Blueprint Section 10)
   double tp1;
   if(direction ==  1) tp1 = NormalizeDouble(ask + slDist * InpTP1_R, _Digits);
   else                tp1 = NormalizeDouble(bid - slDist * InpTP1_R, _Digits);

   double lots = CalcLots(slDist);

   // Record managed trade state
   ManagedTrade mt;
   mt.beSet       = false;
   mt.tp1Hit      = false;
   mt.initialRisk = slDist;
   mt.direction   = direction;

   bool ok = false;
   if(direction == 1)
     {
      mt.entryPrice = ask;
      ok = trade.Buy(lots, _Symbol, ask, sl, tp1, "BP BUY");
     }
   else
     {
      mt.entryPrice = bid;
      ok = trade.Sell(lots, _Symbol, bid, sl, tp1, "BP SELL");
     }

   if(ok)
     {
      mt.ticket = trade.ResultOrder();
      int sz = ArraySize(gTrades);
      ArrayResize(gTrades, sz + 1);
      gTrades[sz] = mt;
      gTradesToday++;
      gLastSignal = (direction == 1) ? "BUY FIRED ✔" : "SELL FIRED ✔";
      Print("Entry | Dir:", direction, " SL:", sl, " TP1:", tp1,
            " Lots:", lots, " Risk:", DoubleToString(slDist/_Point,1), " pts");
     }
   else
     {
      Print("Entry failed: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN TRADES: PARTIAL CLOSE + BREAKEVEN + TRAIL          |
//| (Blueprint Sections 10–11)                                      |
//+------------------------------------------------------------------+
void ManageTrades()
  {
   // Refresh ATR for trailing
   if(CopyBuffer(hATR_M15, 0, 0, 3, bATR_M15) < 3) return;
   double atr = bATR_M15[0];

   for(int i = 0; i < ArraySize(gTrades); i++)
     {
      ulong ticket = gTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      ENUM_POSITION_TYPE pt      = (ENUM_POSITION_TYPE)posInfo.PositionType();
      double             openP   = posInfo.PriceOpen();
      double             curSL   = posInfo.StopLoss();
      double             curTP   = posInfo.TakeProfit();
      double             risk    = gTrades[i].initialRisk;
      double             lots    = posInfo.Volume();
      double             bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double             ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double             minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if(pt == POSITION_TYPE_BUY)
        {
         double profit = bid - openP;

         // PARTIAL CLOSE: 50% at TP1 = 1.5 × risk (Blueprint Section 10)
         if(!gTrades[i].tp1Hit && profit >= risk * InpTP1_R)
           {
            double half = NormLots(lots * 0.5);
            if(half >= minLot)
              {
               trade.PositionClosePartial(ticket, half);
               gTrades[i].tp1Hit = true;
               Print("BUY partial 50% at TP1");
              }
           }

         // BREAKEVEN: after 1× risk profit (Blueprint Section 11)
         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP + 2 * _Point, _Digits);
            if(newSL > curSL)
              {
               trade.PositionModify(ticket, newSL, curTP);
               gTrades[i].beSet = true;
               Print("BUY breakeven set: ", newSL);
              }
           }

         // TRAILING: after 1.5× risk, trail by 0.5 × ATR (Blueprint Section 11)
         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(bid - InpTrail_ATR * atr, _Digits);
            if(newSL > curSL && newSL < bid)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }

      else if(pt == POSITION_TYPE_SELL)
        {
         double profit = openP - ask;

         if(!gTrades[i].tp1Hit && profit >= risk * InpTP1_R)
           {
            double half = NormLots(lots * 0.5);
            if(half >= minLot)
              {
               trade.PositionClosePartial(ticket, half);
               gTrades[i].tp1Hit = true;
               Print("SELL partial 50% at TP1");
              }
           }

         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP - 2 * _Point, _Digits);
            if(newSL < curSL)
              {
               trade.PositionModify(ticket, newSL, curTP);
               gTrades[i].beSet = true;
               Print("SELL breakeven set: ", newSL);
              }
           }

         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(ask + InpTrail_ATR * atr, _Digits);
            if(newSL < curSL && newSL > ask)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }
     }

   // Remove closed trades from array
   for(int i = ArraySize(gTrades) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(gTrades[i].ticket))
        {
         for(int j = i; j < ArraySize(gTrades) - 1; j++)
            gTrades[j] = gTrades[j + 1];
         ArrayResize(gTrades, ArraySize(gTrades) - 1);
        }
     }
  }

//+------------------------------------------------------------------+
//| NORMALIZE LOT SIZE                                              |
//+------------------------------------------------------------------+
double NormLots(double lots)
  {
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0) return mn;
   lots = MathRound(lots / st) * st;
   return MathMax(mn, MathMin(mx, lots));
  }

//+------------------------------------------------------------------+
//| TRACK LOSSES VIA OnTradeTransaction (Blueprint Section 16)     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal = trans.deal;
   if(deal == 0) return;
   if(!HistoryDealSelect(deal)) return;

   long   magic  = HistoryDealGetInteger(deal, DEAL_MAGIC);
   long   entry  = HistoryDealGetInteger(deal, DEAL_ENTRY);
   double profit = HistoryDealGetDouble(deal,  DEAL_PROFIT)
                 + HistoryDealGetDouble(deal,  DEAL_COMMISSION)
                 + HistoryDealGetDouble(deal,  DEAL_SWAP);

   if(magic != (long)InpMagic)  return;
   if(entry != DEAL_ENTRY_OUT)  return;

   if(profit < 0.0)
     {
      gLossesToday++;
      gConsecLoss++;
      Print("Loss recorded. Today:", gLossesToday, " Consec:", gConsecLoss);
     }
   else
     {
      gConsecLoss = 0; // Reset streak on any win
     }
  }

//+------------------------------------------------------------------+
//| RESET DAILY COUNTERS                                            |
//+------------------------------------------------------------------+
void ResetDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                              dt.year, dt.mon, dt.day));
   if(today == gLastDay) return;

   gLastDay      = today;
   gTradesToday  = 0;
   gLossesToday  = 0;
   gDayHalted    = false;
   gConsecLoss   = 0;
   gDayStartEq   = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("New trading day. Start equity:", gDayStartEq);

   // Update PDH/PDL at start of each new day
   if(InpUsePDHL)
     {
      gPDH = iHigh(_Symbol, PERIOD_D1, 1);
      gPDL = iLow (_Symbol, PERIOD_D1, 1);
     }

   // Check daily equity drawdown (Blueprint Section 12)
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct   = (gDayStartEq > 0)
                    ? (gDayStartEq - equity) / gDayStartEq * 100.0
                    : 0.0;
   if(ddPct >= InpDailyDD_Pct)
     {
      gDayHalted = true;
      Print("⚠ DAILY DD LIMIT HIT (", DoubleToString(ddPct,2), "%). Halted.");
     }
  }

//+------------------------------------------------------------------+
//| CHECK DAILY EQUITY DRAWDOWN (called every tick)                |
//+------------------------------------------------------------------+
void CheckDailyDD()
  {
   if(gDayHalted) return;
   if(gDayStartEq <= 0) return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct  = (gDayStartEq - equity) / gDayStartEq * 100.0;
   if(ddPct >= InpDailyDD_Pct)
     {
      gDayHalted = true;
      Print("⚠ DAILY DD LIMIT HIT (", DoubleToString(ddPct,2), "%). Halted.");
     }
  }

//+------------------------------------------------------------------+
//| SESSION FILTER (Blueprint Section 13)                          |
//+------------------------------------------------------------------+
bool IsInSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool london  = (h >= InpLondonStart && h < InpLondonEnd);
   bool nyOpen  = (h >= InpNYStart     && h < InpNYEnd);
   return (london || nyOpen);
  }

//+------------------------------------------------------------------+
//| SPREAD FILTER (Blueprint Section 13)                           |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   double spreadPips = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / PipSize() * 10.0;
   // Simpler: spread in points / 10 = pips (5-digit broker)
   double rawPips = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;
   if(rawPips > InpMaxSpreadPips)
     {
      Print("Spread too high: ", DoubleToString(rawPips, 1), " pips");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| POSITION CHECK                                                  |
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
//| NEWS FILTER — MT5 Economic Calendar (Blueprint Section 13)     |
//+------------------------------------------------------------------+
bool IsNearNews()
  {
   datetime now = TimeCurrent();
   if(now - gNewsFetched > 3600 || ArraySize(gNews) == 0)
     {
      FetchNewsEvents();
      gNewsFetched = now;
     }

   int bufB = InpNewsBefore * 60;
   int bufA = InpNewsAfter  * 60;

   for(int i = 0; i < ArraySize(gNews); i++)
      if(now >= gNews[i].time - bufB && now <= gNews[i].time + bufA)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| FETCH NEWS FROM MT5 CALENDAR                                   |
//+------------------------------------------------------------------+
void FetchNewsEvents()
  {
   ArrayResize(gNews, 0);

   string base  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   datetime from = TimeCurrent();
   datetime to   = from + 86400; // Next 24 hours

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

      // Block USD, EUR, and GBP events (Blueprint Section 13)
      if(cc.currency != base   && cc.currency != quote  &&
         cc.currency != "USD"  && cc.currency != "EUR"  &&
         cc.currency != "GBP") continue;

      int sz = ArraySize(gNews);
      ArrayResize(gNews, sz + 1);
      gNews[sz].time = vals[i].time;
     }

   Print("News loaded: ", ArraySize(gNews), " high-impact events next 24h");
  }

//+------------------------------------------------------------------+
//| ON-CHART DASHBOARD via Comment() (Blueprint Section — Dashboard)|
//+------------------------------------------------------------------+
void DrawDashboard()
  {
   CheckDailyDD(); // Keep DD check on every tick

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayDD     = (gDayStartEq > 0)
                      ? (gDayStartEq - equity) / gDayStartEq * 100.0
                      : 0.0;

   string statusStr = gDayHalted                        ? "⛔ HALTED (DD)"  :
                      (gConsecLoss >= InpConsecLossHalt) ? "⚠ CONSEC PAUSE" :
                      (gLossesToday >= InpMaxLossDay)    ? "⚠ LOSS LIMIT"   :
                      (gTradesToday >= InpMaxTradesDay)  ? "⚠ TRADE LIMIT"  :
                      IsInSession()                      ? "✔ ACTIVE"       :
                                                           "— CLOSED —";

   string volModes  = gVolumeStatus;
   string levStr    = (gNearestLevel > 0)
                      ? DoubleToString(gNearestLevel, _Digits)
                      : "None detected";

   string spread    = DoubleToString(
                         (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0, 1);

   string dash =
      "╔══════════════ BLUEPRINT EA ══════════════╗\n"
      "║ Symbol  : " + _Symbol + "                     \n"
      "║ Status  : " + statusStr + "               \n"
      "╠══════════════════════════════════════════╣\n"
      "║ HTF Bias: " + gTrendBias + "              \n"
      "║ Volume  : " + volModes + "                \n"
      "║ Pattern : " + gPatternFound + "           \n"
      "║ Lvl Near: " + levStr + "                  \n"
      "╠══════════════════════════════════════════╣\n"
      "║ Signal  : " + gLastSignal + "             \n"
      "║ Spread  : " + spread + " pips             \n"
      "╠══════════════════════════════════════════╣\n"
      "║ Trades/d: " + IntegerToString(gTradesToday) +
                " / " + IntegerToString(InpMaxTradesDay) + "           \n"
      "║ Losses/d: " + IntegerToString(gLossesToday)  +
                " / " + IntegerToString(InpMaxLossDay)  + "           \n"
      "║ ConsecL : " + IntegerToString(gConsecLoss)   +
                " / " + IntegerToString(InpConsecLossHalt) + "        \n"
      "║ Day DD  : " + DoubleToString(dayDD, 2)  + "% / " +
                       DoubleToString(InpDailyDD_Pct, 1) + "%\n"
      "║ Equity  : " + DoubleToString(equity, 2) + "      \n"
      "╚══════════════════════════════════════════╝";

   Comment(dash);
  }

//+------------------------------------------------------------------+
//| END                                                              |
//+------------------------------------------------------------------+
