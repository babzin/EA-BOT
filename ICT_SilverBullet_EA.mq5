
#property copyright "ICT Silver Bullet EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

input group "=== HTF BIAS ==="
input ENUM_TIMEFRAMES InpBiasTF      = PERIOD_H4;  // HTF for bias detection
input int    InpSwingStrength        = 3;           // Bars each side for swing
input int    InpSwingLookback        = 80;          // Bars to scan for swings
input int    InpBiasSwingCount       = 3;           // Swings needed for bias

input group "=== SILVER BULLET KILLZONES (GMT offset from NY) ==="
// NY time = GMT - 5 (EST) or GMT - 4 (EDT summer)
// Default values are GMT times. Adjust InpGMT_Offset for your server.
input int    InpGMT_Offset           = 0;   // Server GMT offset (0 if server=GMT)
input bool   InpLondonKZ             = true; // Enable London Silver Bullet
input int    InpLondon_Start         = 8;    // London KZ start (GMT hour)
input int    InpLondon_End           = 9;    // London KZ end (GMT hour)
input bool   InpNYAM_KZ              = true; // Enable NY AM Silver Bullet
input int    InpNYAM_Start           = 15;   // NY AM KZ start (GMT hour)
input int    InpNYAM_End             = 16;   // NY AM KZ end (GMT hour)
input bool   InpNYPM_KZ              = true; // Enable NY PM Silver Bullet
input int    InpNYPM_Start           = 19;   // NY PM KZ start (GMT hour)
input int    InpNYPM_End             = 20;   // NY PM KZ end (GMT hour)

input group "=== LIQUIDITY LEVELS ==="
input bool   InpUsePDH_PDL           = true;  // Use Previous Day High/Low as DOL
input bool   InpUseSessionHL         = true;  // Use previous session high/low
input double InpSweep_Pct            = 0.05;  // Sweep buffer % beyond level
input int    InpSweep_Lookback       = 5;     // Bars to check for sweep

input group "=== DISPLACEMENT ==="
input double InpDisplace_ATR         = 1.5;   // Min displacement body size (× ATR)
input int    InpDisplace_Lookback    = 6;     // Bars to look back for displacement

input group "=== FVG SETTINGS ==="
input double InpFVG_MinSize_ATR      = 0.15;  // Min FVG size (× ATR)
input int    InpFVG_Lookback         = 8;     // Bars to scan for FVG
input double InpOTE_Level            = 0.50;  // OTE entry level in FVG (0.5 = 50%)

input group "=== ORDER BLOCK ==="
input double InpOB_MinBody_ATR       = 0.3;   // Min OB body size (× ATR)

input group "=== ATR ==="
input int    InpATR_Period           = 14;
input double InpATR_SL_Buffer        = 0.5;   // ATR buffer beyond OB for SL

input group "=== RISK MANAGEMENT ==="
input double InpRiskPct              = 1.0;   // Risk % per trade
input double InpRR_TP2               = 3.0;   // RR for final TP (ICT minimum 1:3)
input bool   InpPartialClose         = true;  // Close 50% at 1×R
input double InpDailyDD_Limit        = 5.0;   // Daily equity DD halt %
input int    InpMaxTradesDay         = 4;     // Max trades per day
input int    InpMaxTradesPerKZ       = 2;     // Max trades per killzone window
input int    InpMaxLossDay           = 2;     // Max losses per day
input int    InpConsecLossHalt       = 3;     // Halt after N consecutive losses

input group "=== NEWS FILTER ==="
input bool   InpUseNews              = true;
input int    InpNewsBefore           = 30;    // Minutes before news
input int    InpNewsAfter            = 30;    // Minutes after news

input group "=== MISC ==="
input ulong  InpMagic                = 707707;
input ulong  InpSlippage             = 10;
input long   InpMaxSpread            = 35;
input bool   InpLogs                 = true;

//+------------------------------------------------------------------+
//| STRUCTS                                                          |
//+------------------------------------------------------------------+

struct SwingPt
  {
   double   price;
   datetime barTime;
   int      barIdx;
   bool     isHigh;
  };

struct LiquidityLevel
  {
   double   price;
   bool     isBSL;      // true=Buy Side Liquidity (above), false=SSL (below)
   bool     swept;
   datetime formed;
  };

struct FVG_Zone
  {
   double   top;
   double   bottom;
   double   ote;        // 50% OTE entry
   bool     isBull;
   bool     filled;
   datetime formed;
   int      barIdx;
  };

struct OB_Zone
  {
   double   top;
   double   bottom;
   bool     isBull;
   bool     tested;
   datetime formed;
  };

struct ManagedTrade
  {
   ulong  ticket;
   bool   beSet;
   bool   scaled;
   double initialRisk;
   double sweepExtreme; // extreme of the sweep candle for SL validation
  };

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

int hATR_M5   = INVALID_HANDLE;
int hATR_H4   = INVALID_HANDLE;

double bATR_M5[], bATR_H4[];

SwingPt        gSwings[];
LiquidityLevel gLiqLevels[];
FVG_Zone       gFVGs[];
OB_Zone        gOBs[];
ManagedTrade   gTrades[];

// Session tracking
datetime gLastDay          = 0;
datetime gLastBarM5        = 0;
int      gTradesToday      = 0;
int      gLossesToday      = 0;
int      gConsecLoss       = 0;
double   gDayStartEquity   = 0;
int      gKZ_TradesThisWindow = 0;
datetime gCurrentKZEnd     = 0;

// Previous Day High/Low
double   gPDH = 0, gPDL = 0;

// News
struct NewsEvt { datetime time; };
NewsEvt  gNews[];
datetime gNewsFetched = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   hATR_M5 = iATR(_Symbol, PERIOD_M5, InpATR_Period);
   hATR_H4 = iATR(_Symbol, InpBiasTF, InpATR_Period);

   if(hATR_M5 == INVALID_HANDLE || hATR_H4 == INVALID_HANDLE)
     { Print("ERROR: ATR handle failed"); return INIT_FAILED; }

   ArraySetAsSeries(bATR_M5, true);
   ArraySetAsSeries(bATR_H4, true);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("ICT Silver Bullet EA initialized | ", _Symbol, " | GMT offset: ", InpGMT_Offset);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   if(hATR_H4 != INVALID_HANDLE) IndicatorRelease(hATR_H4);
  }

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDay();
   ManageTrades(); // BE + partial + trail on every tick

   // Entry evaluation fires on each new M5 bar
   datetime curM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(curM5 == gLastBarM5) return;
   gLastBarM5 = curM5;

   // ---- CIRCUIT BREAKERS ----
   if(gTradesToday  >= InpMaxTradesDay)    return;
   if(gLossesToday  >= InpMaxLossDay)      return;
   if(gConsecLoss   >= InpConsecLossHalt)  return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(gDayStartEquity > 0 &&
      (gDayStartEquity - equity) / gDayStartEquity * 100.0 >= InpDailyDD_Limit)
     { if(InpLogs) Print("Daily DD halt"); return; }

   // ---- PRE-CHECKS ----
   if(HasPosition())                       return;
   if(!SpreadOK())                         return;
   if(InpUseNews && IsNearNews())          return;
   if(!LoadBuffers())                      return;

   // ---- KILLZONE CHECK ----
   if(!IsInKillZone())
     { return; }

   // Reset per-KZ trade counter when window changes
   datetime kzEnd = GetCurrentKZEnd();
   if(kzEnd != gCurrentKZEnd)
     {
      gCurrentKZEnd        = kzEnd;
      gKZ_TradesThisWindow = 0;
     }
   if(gKZ_TradesThisWindow >= InpMaxTradesPerKZ) return;

   // ---- ICT WORKFLOW ----

   // Step 1: HTF Bias
   DetectHTFSwings();
   int bias = GetHTFBias();
   if(bias == 0) { if(InpLogs) Print("No HTF bias"); return; }

   // Step 2: Mark DOL levels (PDH/PDL + session extremes)
   UpdateDOL();

   // Step 3: Already inside KZ (verified above)

   // Step 4: Detect liquidity sweep within KZ
   LiquidityLevel sweptLevel;
   if(!DetectLiquiditySweep(bias, sweptLevel))
     { if(InpLogs) Print("No liquidity sweep"); return; }

   // Step 5: Detect displacement candle after sweep
   int displacementBar = -1;
   if(!DetectDisplacement(bias, displacementBar))
     { if(InpLogs) Print("No displacement candle"); return; }

   // Step 6: Find FVG within the displacement
   FVG_Zone fvg;
   if(!DetectFVG(bias, displacementBar, fvg))
     { if(InpLogs) Print("No FVG in displacement"); return; }

   // Step 7: Find Order Block for SL anchor
   OB_Zone ob;
   bool hasOB = DetectOrderBlock(bias, displacementBar, ob);

   // Step 8: Premium/Discount filter
   if(!PremiumDiscountFilter(bias))
     { if(InpLogs) Print("Not in premium/discount zone"); return; }

   if(InpLogs)
      Print("ICT SIGNAL | Bias:", bias,
            " Sweep:", sweptLevel.price,
            " FVG:", fvg.bottom, "-", fvg.top,
            " OTE:", fvg.ote,
            " OB:", hasOB ? "YES" : "NO");

   if(bias ==  1) ExecuteBuy(fvg, ob, hasOB, sweptLevel);
   if(bias == -1) ExecuteSell(fvg, ob, hasOB, sweptLevel);
  }

//+------------------------------------------------------------------+
//| LOAD BUFFERS                                                     |
//+------------------------------------------------------------------+
bool LoadBuffers()
  {
   if(CopyBuffer(hATR_M5, 0, 0, 10, bATR_M5) < 10) return false;
   if(CopyBuffer(hATR_H4, 0, 0, 5,  bATR_H4) < 5)  return false;
   return true;
  }

//+------------------------------------------------------------------+
//| DETECT HTF SWINGS                                                |
//+------------------------------------------------------------------+
void DetectHTFSwings()
  {
   ArrayResize(gSwings, 0);
   int s  = InpSwingStrength;
   int lb = InpSwingLookback;

   for(int i = s; i < lb - s; i++)
     {
      double hi = iHigh(_Symbol, InpBiasTF, i);
      double lo = iLow (_Symbol, InpBiasTF, i);
      bool isH = true, isL = true;

      for(int k = 1; k <= s; k++)
        {
         if(iHigh(_Symbol, InpBiasTF, i-k) >= hi ||
            iHigh(_Symbol, InpBiasTF, i+k) >= hi) isH = false;
         if(iLow (_Symbol, InpBiasTF, i-k) <= lo ||
            iLow (_Symbol, InpBiasTF, i+k) <= lo) isL = false;
        }

      if(isH)
        {
         int sz = ArraySize(gSwings); ArrayResize(gSwings, sz+1);
         gSwings[sz].price   = hi;
         gSwings[sz].barTime = iTime(_Symbol, InpBiasTF, i);
         gSwings[sz].barIdx  = i;
         gSwings[sz].isHigh  = true;
        }
      if(isL)
        {
         int sz = ArraySize(gSwings); ArrayResize(gSwings, sz+1);
         gSwings[sz].price   = lo;
         gSwings[sz].barTime = iTime(_Symbol, InpBiasTF, i);
         gSwings[sz].barIdx  = i;
         gSwings[sz].isHigh  = false;
        }
     }
  }

//+------------------------------------------------------------------+
//| GET HTF BIAS FROM SWING STRUCTURE                               |
//| 1=Bull (HH+HL), -1=Bear (LH+LL), 0=Ranging                     |
//+------------------------------------------------------------------+
int GetHTFBias()
  {
   double highs[], lows[];
   ArrayResize(highs, 0); ArrayResize(lows, 0);

   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      if(gSwings[i].isHigh)
        { int s = ArraySize(highs); ArrayResize(highs,s+1); highs[s]=gSwings[i].price; }
      else
        { int s = ArraySize(lows);  ArrayResize(lows, s+1); lows[s] =gSwings[i].price; }
     }

   int n = InpBiasSwingCount;
   if(ArraySize(highs) < n || ArraySize(lows) < n) return 0;

   bool hhOK=true, hlOK=true, lhOK=true, llOK=true;
   for(int i = 0; i < n-1; i++)
     {
      if(highs[i] <= highs[i+1]) hhOK = false;
      if(highs[i] >= highs[i+1]) lhOK = false;
      if(lows[i]  <= lows[i+1])  hlOK = false;
      if(lows[i]  >= lows[i+1])  llOK = false;
     }

   if(hhOK && hlOK) return  1;
   if(lhOK && llOK) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| UPDATE DRAW ON LIQUIDITY (PDH/PDL + session highs/lows)         |
//+------------------------------------------------------------------+
void UpdateDOL()
  {
   ArrayResize(gLiqLevels, 0);

   // Previous Day High/Low
   if(InpUsePDH_PDL)
     {
      gPDH = iHigh(_Symbol, PERIOD_D1, 1);
      gPDL = iLow (_Symbol, PERIOD_D1, 1);

      int sz = ArraySize(gLiqLevels);
      ArrayResize(gLiqLevels, sz+2);
      gLiqLevels[sz].price  = gPDH;
      gLiqLevels[sz].isBSL  = true;
      gLiqLevels[sz].swept  = false;
      gLiqLevels[sz].formed = iTime(_Symbol, PERIOD_D1, 1);
      sz++;
      gLiqLevels[sz].price  = gPDL;
      gLiqLevels[sz].isBSL  = false;
      gLiqLevels[sz].swept  = false;
      gLiqLevels[sz].formed = iTime(_Symbol, PERIOD_D1, 1);
     }

   // Session previous H/L (last 20 H1 bars for session range)
   if(InpUseSessionHL)
     {
      double sHigh = iHigh(_Symbol, PERIOD_H1, 1);
      double sLow  = iLow (_Symbol, PERIOD_H1, 1);
      for(int i = 1; i <= 20; i++)
        {
         sHigh = MathMax(sHigh, iHigh(_Symbol, PERIOD_H1, i));
         sLow  = MathMin(sLow,  iLow (_Symbol, PERIOD_H1, i));
        }
      int sz = ArraySize(gLiqLevels);
      ArrayResize(gLiqLevels, sz+2);
      gLiqLevels[sz].price  = sHigh;
      gLiqLevels[sz].isBSL  = true;
      gLiqLevels[sz].swept  = false;
      gLiqLevels[sz].formed = TimeCurrent();
      sz++;
      gLiqLevels[sz].price  = sLow;
      gLiqLevels[sz].isBSL  = false;
      gLiqLevels[sz].swept  = false;
      gLiqLevels[sz].formed = TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| DETECT LIQUIDITY SWEEP ON M5                                    |
//| For BULL: price spikes BELOW a SSL level then closes ABOVE it   |
//| For BEAR: price spikes ABOVE a BSL level then closes BELOW it   |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(int bias, LiquidityLevel &outLevel)
  {
   int lb = InpSweep_Lookback;

   for(int b = 1; b <= lb; b++)
     {
      double lo_b  = iLow  (_Symbol, PERIOD_M5, b);
      double hi_b  = iHigh (_Symbol, PERIOD_M5, b);
      double cl_b  = iClose(_Symbol, PERIOD_M5, b);

      for(int i = 0; i < ArraySize(gLiqLevels); i++)
        {
         if(gLiqLevels[i].swept) continue;
         double lvl = gLiqLevels[i].price;
         double buf = lvl * InpSweep_Pct / 100.0;

         if(bias == 1 && !gLiqLevels[i].isBSL)
           {
            // Bull sweep: wick below SSL (lo_b < lvl - buf) and close above SSL
            if(lo_b < lvl - buf && cl_b > lvl)
              {
               gLiqLevels[i].swept = true;
               outLevel = gLiqLevels[i];
               if(InpLogs) Print("Bull sweep detected at ", lvl, " bar:", b);
               return true;
              }
           }
         if(bias == -1 && gLiqLevels[i].isBSL)
           {
            // Bear sweep: wick above BSL (hi_b > lvl + buf) and close below BSL
            if(hi_b > lvl + buf && cl_b < lvl)
              {
               gLiqLevels[i].swept = true;
               outLevel = gLiqLevels[i];
               if(InpLogs) Print("Bear sweep detected at ", lvl, " bar:", b);
               return true;
              }
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| DETECT DISPLACEMENT CANDLE AFTER SWEEP                         |
//| Large body > InpDisplace_ATR × ATR, in the bias direction       |
//| Must be within InpDisplace_Lookback bars from current           |
//+------------------------------------------------------------------+
bool DetectDisplacement(int bias, int &outBar)
  {
   double atr = bATR_M5[1];
   int lb = InpDisplace_Lookback;

   for(int b = 1; b <= lb; b++)
     {
      double o = iOpen (_Symbol, PERIOD_M5, b);
      double c = iClose(_Symbol, PERIOD_M5, b);
      double body = MathAbs(c - o);

      if(body < InpDisplace_ATR * atr) continue;

      // Bull displacement: large green candle
      if(bias == 1 && c > o)
        { outBar = b; return true; }

      // Bear displacement: large red candle
      if(bias == -1 && c < o)
        { outBar = b; return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| DETECT FVG WITHIN DISPLACEMENT                                  |
//| Bullish FVG: high[bar+1] < low[bar-1] (gap between bar-1 & bar+1)|
//| Bearish FVG: low[bar+1] > high[bar-1]                           |
//| Entry at OTE level (50% of FVG by default)                      |
//+------------------------------------------------------------------+
bool DetectFVG(int bias, int disBar, FVG_Zone &outFVG)
  {
   double atr = bATR_M5[1];
   int lb = InpFVG_Lookback;

   // Scan bars around and after the displacement
   for(int b = 1; b <= lb; b++)
     {
      // FVG: candle at b is the middle candle
      // Candle b+1 = older, candle b-1 = newer
      if(b < 1 || b+1 >= lb + 5) continue;

      double hi_prev = iHigh(_Symbol, PERIOD_M5, b+1); // older bar (1st candle)
      double lo_prev = iLow (_Symbol, PERIOD_M5, b+1);
      double hi_next = iHigh(_Symbol, PERIOD_M5, b-1); // newer bar (3rd candle)
      double lo_next = iLow (_Symbol, PERIOD_M5, b-1);

      if(bias == 1)
        {
         // Bullish FVG: lo_next > hi_prev → gap between them
         if(lo_next > hi_prev)
           {
            double gapSize = lo_next - hi_prev;
            if(gapSize < InpFVG_MinSize_ATR * atr) continue;

            outFVG.bottom = hi_prev;
            outFVG.top    = lo_next;
            outFVG.ote    = hi_prev + (lo_next - hi_prev) * InpOTE_Level;
            outFVG.isBull = true;
            outFVG.filled = false;
            outFVG.formed = iTime(_Symbol, PERIOD_M5, b);
            outFVG.barIdx = b;
            return true;
           }
        }

      if(bias == -1)
        {
         // Bearish FVG: hi_next < lo_prev → gap between them
         if(hi_next < lo_prev)
           {
            double gapSize = lo_prev - hi_next;
            if(gapSize < InpFVG_MinSize_ATR * atr) continue;

            outFVG.top    = lo_prev;
            outFVG.bottom = hi_next;
            outFVG.ote    = lo_prev - (lo_prev - hi_next) * InpOTE_Level;
            outFVG.isBull = false;
            outFVG.filled = false;
            outFVG.formed = iTime(_Symbol, PERIOD_M5, b);
            outFVG.barIdx = b;
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| DETECT ORDER BLOCK (last opposing candle before displacement)   |
//+------------------------------------------------------------------+
bool DetectOrderBlock(int bias, int disBar, OB_Zone &outOB)
  {
   double atr = bATR_M5[1];

   // OB is the candle just before the displacement
   int obBar = disBar + 1;
   if(obBar > InpFVG_Lookback + 5) return false;

   double o = iOpen (_Symbol, PERIOD_M5, obBar);
   double c = iClose(_Symbol, PERIOD_M5, obBar);
   double h = iHigh (_Symbol, PERIOD_M5, obBar);
   double l = iLow  (_Symbol, PERIOD_M5, obBar);
   double body = MathAbs(c - o);

   if(body < InpOB_MinBody_ATR * atr) return false;

   // Bullish OB: last bearish candle before bull displacement
   if(bias == 1 && c < o)
     {
      outOB.top    = h;
      outOB.bottom = l;
      outOB.isBull = true;
      outOB.tested = false;
      outOB.formed = iTime(_Symbol, PERIOD_M5, obBar);
      return true;
     }

   // Bearish OB: last bullish candle before bear displacement
   if(bias == -1 && c > o)
     {
      outOB.top    = h;
      outOB.bottom = l;
      outOB.isBull = false;
      outOB.tested = false;
      outOB.formed = iTime(_Symbol, PERIOD_M5, obBar);
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| PREMIUM / DISCOUNT ZONE FILTER                                  |
//| Uses H4 swing range: midpoint = equilibrium                     |
//| Buy below mid (discount), Sell above mid (premium)              |
//+------------------------------------------------------------------+
bool PremiumDiscountFilter(int bias)
  {
   if(ArraySize(gSwings) < 2) return true;

   double nearHigh = 0, nearLow = 0;
   bool gh = false, gl = false;

   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      if(!gh && gSwings[i].isHigh)  { nearHigh = gSwings[i].price; gh = true; }
      if(!gl && !gSwings[i].isHigh) { nearLow  = gSwings[i].price; gl = true; }
      if(gh && gl) break;
     }

   if(!gh || !gl) return true;

   double mid     = (nearHigh + nearLow) / 2.0;
   double m5Close = iClose(_Symbol, PERIOD_M5, 1);

   if(bias ==  1) return (m5Close < mid); // Discount zone for longs
   if(bias == -1) return (m5Close > mid); // Premium zone for shorts
   return true;
  }

//+------------------------------------------------------------------+
//| CALCULATE LOTS                                                   |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
  {
   if(slDist <= 0.0) return NormLots(0.01);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk    = balance * InpRiskPct / 100.0;
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
//| Entry at FVG OTE (50% of gap), SL below sweep wick / OB bottom  |
//+------------------------------------------------------------------+
void ExecuteBuy(FVG_Zone &fvg, OB_Zone &ob, bool hasOB, LiquidityLevel &sweep)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr = bATR_M5[1];

   // Entry: at OTE of FVG (limit order simulated as market if price is at/near OTE)
   double entryPrice = ask;

   // SL: below OB bottom if available, else below sweep wick + buffer
   double sl;
   if(hasOB)
      sl = NormalizeDouble(ob.bottom - InpATR_SL_Buffer * atr, _Digits);
   else
      sl = NormalizeDouble(sweep.price - InpATR_SL_Buffer * atr * 2.0, _Digits);

   double slDist = entryPrice - sl;
   if(slDist <= 0.0) return;

   // TP: next BSL (PDH) or 3×R minimum (ICT rule)
   double tp3R   = NormalizeDouble(entryPrice + slDist * InpRR_TP2, _Digits);
   double tpPDH  = (gPDH > entryPrice) ? gPDH : 0.0;
   double tp     = (tpPDH > entryPrice && tpPDH < tp3R) ? tpPDH : tp3R;

   double lots = CalcLots(slDist);

   if(InpLogs)
      Print("BUY | Ask:", entryPrice, " FVG OTE:", fvg.ote,
            " SL:", sl, " TP:", tp, " Lots:", lots);

   if(trade.Buy(lots, _Symbol, entryPrice, sl, tp, "ICT SB BUY"))
     {
      gTradesToday++;
      gKZ_TradesThisWindow++;
      int sz = ArraySize(gTrades); ArrayResize(gTrades, sz+1);
      gTrades[sz].ticket       = trade.ResultOrder();
      gTrades[sz].beSet        = false;
      gTrades[sz].scaled       = false;
      gTrades[sz].initialRisk  = slDist;
      gTrades[sz].sweepExtreme = sweep.price;
     }
   else Print("BUY error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| EXECUTE SELL                                                     |
//+------------------------------------------------------------------+
void ExecuteSell(FVG_Zone &fvg, OB_Zone &ob, bool hasOB, LiquidityLevel &sweep)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = bATR_M5[1];

   double entryPrice = bid;

   double sl;
   if(hasOB)
      sl = NormalizeDouble(ob.top + InpATR_SL_Buffer * atr, _Digits);
   else
      sl = NormalizeDouble(sweep.price + InpATR_SL_Buffer * atr * 2.0, _Digits);

   double slDist = sl - entryPrice;
   if(slDist <= 0.0) return;

   double tp3R  = NormalizeDouble(entryPrice - slDist * InpRR_TP2, _Digits);
   double tpPDL = (gPDL < entryPrice) ? gPDL : 0.0;
   double tp    = (tpPDL < entryPrice && tpPDL > tp3R) ? tpPDL : tp3R;

   double lots = CalcLots(slDist);

   if(InpLogs)
      Print("SELL | Bid:", entryPrice, " FVG OTE:", fvg.ote,
            " SL:", sl, " TP:", tp, " Lots:", lots);

   if(trade.Sell(lots, _Symbol, entryPrice, sl, tp, "ICT SB SELL"))
     {
      gTradesToday++;
      gKZ_TradesThisWindow++;
      int sz = ArraySize(gTrades); ArrayResize(gTrades, sz+1);
      gTrades[sz].ticket       = trade.ResultOrder();
      gTrades[sz].beSet        = false;
      gTrades[sz].scaled       = false;
      gTrades[sz].initialRisk  = slDist;
      gTrades[sz].sweepExtreme = sweep.price;
     }
   else Print("SELL error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN TRADES: PARTIAL CLOSE + BE + ATR TRAIL             |
//+------------------------------------------------------------------+
void ManageTrades()
  {
   if(CopyBuffer(hATR_M5, 0, 0, 3, bATR_M5) < 3) return;

   for(int i = 0; i < ArraySize(gTrades); i++)
     {
      ulong ticket = gTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)posInfo.PositionType();
      double openP  = posInfo.PriceOpen();
      double curSL  = posInfo.StopLoss();
      double curTP  = posInfo.TakeProfit();
      double risk   = gTrades[i].initialRisk;
      double lots   = posInfo.Volume();
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double atr    = bATR_M5[0];

      if(pt == POSITION_TYPE_BUY)
        {
         double profit = bid - openP;

         // Partial close at 1×R
         if(InpPartialClose && !gTrades[i].scaled && profit >= risk)
           {
            double half = NormLots(lots * 0.5);
            if(half >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
              {
               trade.PositionClosePartial(ticket, half);
               gTrades[i].scaled = true;
               if(InpLogs) Print("BUY partial 50% at 1R");
              }
           }

         // Breakeven at 1×R
         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP + 1 * _Point, _Digits);
            if(newSL > curSL)
              { trade.PositionModify(ticket, newSL, curTP); gTrades[i].beSet = true; }
           }

         // ATR trail at 1.5×R
         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(bid - atr * 1.2, _Digits);
            if(newSL > curSL && newSL < bid)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }

      else if(pt == POSITION_TYPE_SELL)
        {
         double profit = openP - ask;

         if(InpPartialClose && !gTrades[i].scaled && profit >= risk)
           {
            double half = NormLots(lots * 0.5);
            if(half >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
              {
               trade.PositionClosePartial(ticket, half);
               gTrades[i].scaled = true;
               if(InpLogs) Print("SELL partial 50% at 1R");
              }
           }

         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP - 1 * _Point, _Digits);
            if(newSL < curSL)
              { trade.PositionModify(ticket, newSL, curTP); gTrades[i].beSet = true; }
           }

         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(ask + atr * 1.2, _Digits);
            if(newSL < curSL && newSL > ask)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }
     }

   // Compact array
   for(int i = ArraySize(gTrades) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(gTrades[i].ticket))
        {
         for(int j = i; j < ArraySize(gTrades)-1; j++) gTrades[j] = gTrades[j+1];
         ArrayResize(gTrades, ArraySize(gTrades)-1);
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

      if(magic == (long)InpMagic && entry == DEAL_ENTRY_OUT)
        {
         if(profit < 0.0)
           { gLossesToday++; gConsecLoss++; }
         else
           { gConsecLoss = 0; }
        }
     }
  }

//+------------------------------------------------------------------+
//| IS INSIDE A SILVER BULLET KILLZONE?                             |
//+------------------------------------------------------------------+
bool IsInKillZone()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour + InpGMT_Offset; // Adjust to server GMT
   // Normalise hour
   while(h < 0)  h += 24;
   while(h >= 24) h -= 24;

   if(InpLondonKZ && h >= InpLondon_Start && h < InpLondon_End) return true;
   if(InpNYAM_KZ  && h >= InpNYAM_Start   && h < InpNYAM_End)  return true;
   if(InpNYPM_KZ  && h >= InpNYPM_Start   && h < InpNYPM_End)  return true;
   return false;
  }

//+------------------------------------------------------------------+
//| GET CURRENT KZ END TIME (for per-window trade counter)          |
//+------------------------------------------------------------------+
datetime GetCurrentKZEnd()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour + InpGMT_Offset;
   while(h < 0)  h += 24;
   while(h >= 24) h -= 24;

   if(InpLondonKZ && h >= InpLondon_Start && h < InpLondon_End)
      return iTime(_Symbol, PERIOD_H1, 0) + (InpLondon_End - h) * 3600;
   if(InpNYAM_KZ && h >= InpNYAM_Start && h < InpNYAM_End)
      return iTime(_Symbol, PERIOD_H1, 0) + (InpNYAM_End - h) * 3600;
   if(InpNYPM_KZ && h >= InpNYPM_Start && h < InpNYPM_End)
      return iTime(_Symbol, PERIOD_H1, 0) + (InpNYPM_End - h) * 3600;
   return 0;
  }

//+------------------------------------------------------------------+
//| RESET DAILY COUNTERS                                             |
//+------------------------------------------------------------------+
void ResetDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                              dt.year, dt.mon, dt.day));
   if(today != gLastDay)
     {
      gLastDay            = today;
      gTradesToday        = 0;
      gLossesToday        = 0;
      gDayStartEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
      gKZ_TradesThisWindow= 0;
      if(InpLogs) Print("New day. Equity:", gDayStartEquity);
     }
  }

//+------------------------------------------------------------------+
//| SPREAD / POSITION / NEWS HELPERS                                 |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > InpMaxSpread) { if(InpLogs) Print("Spread:", sp); return false; }
   return true;
  }

bool HasPosition()
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            return true;
   return false;
  }

bool IsNearNews()
  {
   datetime now = TimeCurrent();
   if(now - gNewsFetched > 3600 || ArraySize(gNews) == 0)
     { FetchNews(); gNewsFetched = now; }
   int bufB = InpNewsBefore * 60, bufA = InpNewsAfter * 60;
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
   datetime from = TimeCurrent(), to = from + 86400;
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
      int sz = ArraySize(gNews); ArrayResize(gNews, sz+1);
      gNews[sz].time = vals[i].time;
     }
   if(InpLogs) Print("News:", ArraySize(gNews), " events loaded");
  }

//+------------------------------------------------------------------+
//| END                                                              |
//+------------------------------------------------------------------+
