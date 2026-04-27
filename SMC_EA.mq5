

#property copyright "SMC EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+

input group "=== MARKET STRUCTURE ==="
input int    InpSwingStrength  = 3;    // Bars each side to confirm swing
input int    InpSwingLookback  = 60;   // Bars to scan for swings on H4
input int    InpStructureCount = 3;    // Swing count needed to confirm trend

input group "=== ORDER BLOCK SETTINGS ==="
input int    InpOB_Lookback    = 40;   // Bars to scan for Order Blocks
input double InpOB_MinBody_ATR = 0.3;  // OB candle body min size (× ATR)
input double InpOB_Impulse_ATR = 1.5;  // Impulse move after OB (× ATR)

input group "=== FVG SETTINGS ==="
input int    InpFVG_Lookback   = 30;   // Bars to scan for FVGs
input double InpFVG_MinSize_ATR= 0.2;  // Min FVG size (× ATR)

input group "=== LIQUIDITY SWEEP ==="
input double InpSweep_Buffer   = 0.1;  // Sweep spike % beyond swing (0.1%)
input int    InpSweep_Lookback = 10;   // Bars to look back for sweep

input group "=== ZONE PROXIMITY ==="
input double InpZone_ATR       = 0.6;  // Price must be within X × ATR of zone

input group "=== ATR ==="
input int    InpATR_Period     = 14;
input double InpATR_SL         = 1.0;  // ATR buffer beyond OB/FVG for SL
input double InpRR_TP2         = 2.5;  // RR for final TP

input group "=== RISK MANAGEMENT ==="
input double InpRiskPct        = 1.0;  // Risk % per trade
input bool   InpPartialClose   = true; // Close 50% at 1× risk
input double InpDailyDDLimit   = 5.0;  // Daily drawdown halt (%)
input int    InpMaxTradesDay   = 3;    // Max trades per day
input int    InpMaxLossDay     = 2;    // Max losses per day
input int    InpConsecLossHalt = 3;    // Pause after N consecutive losses

input group "=== KILL ZONES (GMT) ==="
input int    InpLondonOpen     = 7;
input int    InpLondonClose    = 10;
input int    InpNYOpen         = 12;
input int    InpNYClose        = 16;

input group "=== VOLUME FILTER ==="
input bool   InpUseVolume      = true;
input int    InpVolMA_Period   = 20;
input double InpVolMultiplier  = 1.5;  // Volume must be > X × average

input group "=== NEWS FILTER ==="
input bool   InpUseNews        = true;
input int    InpNewsBefore     = 30;   // Minutes before news
input int    InpNewsAfter      = 30;   // Minutes after news

input group "=== MISC ==="
input ulong  InpMagic          = 606606;
input ulong  InpSlippage       = 10;
input long   InpMaxSpread      = 30;
input bool   InpLogs           = true;

//+------------------------------------------------------------------+
//| STRUCTS                                                          |
//+------------------------------------------------------------------+

struct SwingPoint
  {
   double   price;
   datetime time;
   int      barIdx;
   bool     isHigh;
  };

struct Zone  // Represents an OB or FVG
  {
   double   top;
   double   bottom;
   double   mid;
   bool     isBull;     // true=support/buy zone, false=resistance/sell zone
   bool     isFVG;      // true=FVG, false=OB
   bool     tested;
   datetime formed;
  };

struct ManagedTrade
  {
   ulong  ticket;
   bool   beSet;
   bool   scaled;
   double initialRisk;
   double initialSL;
  };

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+

int hATR_H4   = INVALID_HANDLE;
int hATR_H1   = INVALID_HANDLE;
int hVolMA_H1 = INVALID_HANDLE;

double bATR_H4[], bATR_H1[];
double bVolMA[];

SwingPoint gSwings[];     // H4 swings
Zone       gZones[];      // Active OB/FVG zones
ManagedTrade gTrades[];   // Open trade state

datetime gLastH1Bar   = 0;
datetime gLastDay     = 0;
int      gTradesToday = 0;
int      gLossesToday = 0;
int      gConsecLoss  = 0;
double   gDayStartEq  = 0;

struct NewsEvt { datetime time; };
NewsEvt  gNews[];
datetime gNewsFetched = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   hATR_H4   = iATR(_Symbol, PERIOD_H4, InpATR_Period);
   hATR_H1   = iATR(_Symbol, PERIOD_H1, InpATR_Period);
   hVolMA_H1 = iMA(_Symbol, PERIOD_H1, InpVolMA_Period, 0, MODE_SMA, VOLUME_TICK);

   if(hATR_H4 == INVALID_HANDLE || hATR_H1 == INVALID_HANDLE ||
      hVolMA_H1 == INVALID_HANDLE)
     { Print("ERROR: Handle creation failed"); return INIT_FAILED; }

   ArraySetAsSeries(bATR_H4,  true);
   ArraySetAsSeries(bATR_H1,  true);
   ArraySetAsSeries(bVolMA,   true);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("SMC EA initialized | ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hATR_H4   != INVALID_HANDLE) IndicatorRelease(hATR_H4);
   if(hATR_H1   != INVALID_HANDLE) IndicatorRelease(hATR_H1);
   if(hVolMA_H1 != INVALID_HANDLE) IndicatorRelease(hVolMA_H1);
  }

//+------------------------------------------------------------------+
//| TICK                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDay();
   ManageTrades();

   // Entry logic fires on new H1 bar only
   datetime curH1 = iTime(_Symbol, PERIOD_H1, 0);
   if(curH1 == gLastH1Bar) return;
   gLastH1Bar = curH1;

   // Risk circuit breakers
   if(gTradesToday >= InpMaxTradesDay) return;
   if(gLossesToday >= InpMaxLossDay)   return;
   if(gConsecLoss  >= InpConsecLossHalt)
     {
      if(InpLogs) Print("Consecutive loss halt — pausing");
      return;
     }

   // Daily drawdown halt
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(gDayStartEq > 0 && (gDayStartEq - equity) / gDayStartEq * 100.0 >= InpDailyDDLimit)
     {
      if(InpLogs) Print("Daily drawdown limit hit — halted for today");
      return;
     }

   if(HasPosition()) return;
   if(!IsKillZone()) return;
   if(!SpreadOK())   return;
   if(InpUseNews && IsNearNews()) return;
   if(!LoadBuffers()) return;

   // Full SMC workflow
   DetectH4Swings();
   int bias = GetBias();
   if(bias == 0) { if(InpLogs) Print("No clear H4 bias — skip"); return; }

   DetectZones(bias);
   if(ArraySize(gZones) == 0) { if(InpLogs) Print("No active zones — skip"); return; }

   Zone activeZone;
   if(!GetBestZone(bias, activeZone))
     { if(InpLogs) Print("No zone in proximity — skip"); return; }

   if(!LiquiditySweepDetected(bias))
     { if(InpLogs) Print("No liquidity sweep — skip"); return; }

   if(!H1CHoCH_Confirmed(bias))
     { if(InpLogs) Print("No H1 CHoCH — skip"); return; }

   if(!PremiumDiscountOK(bias))
     { if(InpLogs) Print("Not in premium/discount zone — skip"); return; }

   if(InpUseVolume && !VolumeOK())
     { if(InpLogs) Print("Volume insufficient — skip"); return; }

   if(InpLogs) Print("SMC SIGNAL CONFIRMED | Bias:", bias,
                     " Zone:", activeZone.isFVG ? "FVG" : "OB",
                     " Top:", activeZone.top, " Bot:", activeZone.bottom);

   if(bias ==  1) ExecuteBuy(activeZone);
   if(bias == -1) ExecuteSell(activeZone);
  }

//+------------------------------------------------------------------+
//| LOAD INDICATOR BUFFERS                                           |
//+------------------------------------------------------------------+
bool LoadBuffers()
  {
   if(CopyBuffer(hATR_H4,   0, 0, 5, bATR_H4)  < 5) return false;
   if(CopyBuffer(hATR_H1,   0, 0, 5, bATR_H1)  < 5) return false;
   if(CopyBuffer(hVolMA_H1, 0, 0, 5, bVolMA)   < 5) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| DETECT H4 SWING HIGHS AND LOWS                                   |
//+------------------------------------------------------------------+
void DetectH4Swings()
  {
   ArrayResize(gSwings, 0);
   int s = InpSwingStrength;
   int lb = InpSwingLookback;

   for(int i = s; i < lb - s; i++)
     {
      double hi = iHigh(_Symbol, PERIOD_H4, i);
      double lo = iLow (_Symbol, PERIOD_H4, i);
      bool isHigh = true, isLow = true;

      for(int k = 1; k <= s; k++)
        {
         if(iHigh(_Symbol, PERIOD_H4, i-k) >= hi ||
            iHigh(_Symbol, PERIOD_H4, i+k) >= hi) isHigh = false;
         if(iLow(_Symbol,  PERIOD_H4, i-k) <= lo ||
            iLow(_Symbol,  PERIOD_H4, i+k) <= lo) isLow  = false;
        }

      if(isHigh)
        {
         int sz = ArraySize(gSwings);
         ArrayResize(gSwings, sz + 1);
         gSwings[sz].price  = hi;
         gSwings[sz].time   = iTime(_Symbol, PERIOD_H4, i);
         gSwings[sz].barIdx = i;
         gSwings[sz].isHigh = true;
        }
      if(isLow)
        {
         int sz = ArraySize(gSwings);
         ArrayResize(gSwings, sz + 1);
         gSwings[sz].price  = lo;
         gSwings[sz].time   = iTime(_Symbol, PERIOD_H4, i);
         gSwings[sz].barIdx = i;
         gSwings[sz].isHigh = false;
        }
     }
  }

//+------------------------------------------------------------------+
//| DETERMINE H4 BIAS FROM SWING STRUCTURE                          |
//| Returns: 1=Bull, -1=Bear, 0=Ranging                             |
//+------------------------------------------------------------------+
int GetBias()
  {
   double highs[], lows[];
   ArrayResize(highs, 0);
   ArrayResize(lows,  0);

   // Separate and collect recent highs/lows (index 0 = most recent)
   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      if(gSwings[i].isHigh)
        {
         int sz = ArraySize(highs); ArrayResize(highs, sz+1);
         highs[sz] = gSwings[i].price;
        }
      else
        {
         int sz = ArraySize(lows); ArrayResize(lows, sz+1);
         lows[sz] = gSwings[i].price;
        }
     }

   int n = InpStructureCount;
   if(ArraySize(highs) < n || ArraySize(lows) < n) return 0;

   bool hhOk = true, hlOk = true;
   bool lhOk = true, llOk = true;

   for(int i = 0; i < n - 1; i++)
     {
      // Recent highs[0] should be > highs[1] for HH (most recent first)
      if(highs[i] <= highs[i+1]) hhOk = false;
      if(highs[i] >= highs[i+1]) lhOk = false;
      if(lows[i]  <= lows[i+1])  hlOk = false;
      if(lows[i]  >= lows[i+1])  llOk = false;
     }

   if(hhOk && hlOk) return  1;
   if(lhOk && llOk) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| DETECT ORDER BLOCKS AND FVGS ON H4                              |
//| Fills gZones[] with valid untested zones in the bias direction   |
//+------------------------------------------------------------------+
void DetectZones(int bias)
  {
   ArrayResize(gZones, 0);
   double atr = bATR_H4[1];

   // --- ORDER BLOCK DETECTION ---
   // Bullish OB: last bearish candle before a strong bullish impulse
   // Bearish OB: last bullish candle before a strong bearish impulse
   for(int i = 2; i < InpOB_Lookback; i++)
     {
      double o_i  = iOpen (_Symbol, PERIOD_H4, i);
      double c_i  = iClose(_Symbol, PERIOD_H4, i);
      double h_i  = iHigh (_Symbol, PERIOD_H4, i);
      double l_i  = iLow  (_Symbol, PERIOD_H4, i);
      double body  = MathAbs(c_i - o_i);

      // Impulse candle is the one right after OB (index i-1)
      double o_imp  = iOpen (_Symbol, PERIOD_H4, i-1);
      double c_imp  = iClose(_Symbol, PERIOD_H4, i-1);
      double range_imp = MathAbs(c_imp - o_imp);

      if(body < InpOB_MinBody_ATR * atr) continue;
      if(range_imp < InpOB_Impulse_ATR * atr) continue;

      // Bullish OB: i is bearish, i-1 is a strong bullish impulse
      if(bias == 1 && c_i < o_i && c_imp > o_imp)
        {
         // OB zone = body of the bearish candle (l_i to h_i)
         Zone z;
         z.top     = h_i;
         z.bottom  = l_i;
         z.mid     = (h_i + l_i) / 2.0;
         z.isBull  = true;
         z.isFVG   = false;
         z.tested  = false;
         z.formed  = iTime(_Symbol, PERIOD_H4, i);
         int sz = ArraySize(gZones); ArrayResize(gZones, sz+1);
         gZones[sz] = z;
        }

      // Bearish OB: i is bullish, i-1 is a strong bearish impulse
      if(bias == -1 && c_i > o_i && c_imp < o_imp)
        {
         Zone z;
         z.top     = h_i;
         z.bottom  = l_i;
         z.mid     = (h_i + l_i) / 2.0;
         z.isBull  = false;
         z.isFVG   = false;
         z.tested  = false;
         z.formed  = iTime(_Symbol, PERIOD_H4, i);
         int sz = ArraySize(gZones); ArrayResize(gZones, sz+1);
         gZones[sz] = z;
        }
     }

   // --- FVG DETECTION ---
   // Bullish FVG: candle[i].high < candle[i+2].low (gap between them)
   // Bearish FVG: candle[i].low  > candle[i+2].high
   for(int i = 1; i < InpFVG_Lookback - 1; i++)
     {
      double hi1  = iHigh(_Symbol, PERIOD_H4, i+1); // older candle
      double lo1  = iLow (_Symbol, PERIOD_H4, i+1);
      double hi3  = iHigh(_Symbol, PERIOD_H4, i-1); // newer candle
      double lo3  = iLow (_Symbol, PERIOD_H4, i-1);

      // Bullish FVG: gap exists between hi[i+1] and lo[i-1]
      if(bias == 1 && lo3 > hi1)
        {
         double gapSize = lo3 - hi1;
         if(gapSize < InpFVG_MinSize_ATR * atr) continue;
         Zone z;
         z.top     = lo3;
         z.bottom  = hi1;
         z.mid     = (lo3 + hi1) / 2.0;
         z.isBull  = true;
         z.isFVG   = true;
         z.tested  = false;
         z.formed  = iTime(_Symbol, PERIOD_H4, i);
         int sz = ArraySize(gZones); ArrayResize(gZones, sz+1);
         gZones[sz] = z;
        }

      // Bearish FVG: lo[i+1] > hi[i-1]
      if(bias == -1 && lo1 > hi3)
        {
         double gapSize = lo1 - hi3;
         if(gapSize < InpFVG_MinSize_ATR * atr) continue;
         Zone z;
         z.top     = lo1;
         z.bottom  = hi3;
         z.mid     = (lo1 + hi3) / 2.0;
         z.isBull  = false;
         z.isFVG   = true;
         z.tested  = false;
         z.formed  = iTime(_Symbol, PERIOD_H4, i);
         int sz = ArraySize(gZones); ArrayResize(gZones, sz+1);
         gZones[sz] = z;
        }
     }
  }

//+------------------------------------------------------------------+
//| GET THE BEST (MOST RECENT) ZONE NEAR CURRENT PRICE              |
//+------------------------------------------------------------------+
bool GetBestZone(int bias, Zone &outZone)
  {
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   double atr     = bATR_H1[1];
   double thresh  = InpZone_ATR * atr;

   // Find most recent zone near price
   datetime bestTime = 0;
   bool found = false;

   for(int i = 0; i < ArraySize(gZones); i++)
     {
      if(gZones[i].tested) continue;

      bool inZone = false;
      if(bias == 1)
         inZone = (h1Close >= gZones[i].bottom - thresh &&
                   h1Close <= gZones[i].top    + thresh);
      else
         inZone = (h1Close <= gZones[i].top    + thresh &&
                   h1Close >= gZones[i].bottom - thresh);

      if(!inZone) continue;

      if(!found || gZones[i].formed > bestTime)
        {
         bestTime = gZones[i].formed;
         outZone  = gZones[i];
         found    = true;
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
//| DETECT LIQUIDITY SWEEP ON H1                                    |
//| Price spikes beyond a recent swing extreme then closes inside    |
//+------------------------------------------------------------------+
bool LiquiditySweepDetected(int bias)
  {
   int lb = InpSweep_Lookback + 2;

   // Find the most recent swing high/low in lookback window
   double swingRef = 0.0;

   if(bias == 1) // Looking for sweep below swing low (bull setup)
     {
      swingRef = iLow(_Symbol, PERIOD_H1, 2); // recent low
      for(int i = 2; i < lb; i++)
         swingRef = MathMin(swingRef, iLow(_Symbol, PERIOD_H1, i));

      // Bar 1 (last closed): wick went below swingRef then closed above
      double lo1 = iLow(_Symbol,  PERIOD_H1, 1);
      double cl1 = iClose(_Symbol, PERIOD_H1, 1);
      double sweepThresh = swingRef * (1.0 - InpSweep_Buffer / 100.0);

      return (lo1 <= sweepThresh && cl1 > swingRef);
     }
   else // Sweep above swing high (bear setup)
     {
      swingRef = iHigh(_Symbol, PERIOD_H1, 2);
      for(int i = 2; i < lb; i++)
         swingRef = MathMax(swingRef, iHigh(_Symbol, PERIOD_H1, i));

      double hi1 = iHigh(_Symbol,  PERIOD_H1, 1);
      double cl1 = iClose(_Symbol, PERIOD_H1, 1);
      double sweepThresh = swingRef * (1.0 + InpSweep_Buffer / 100.0);

      return (hi1 >= sweepThresh && cl1 < swingRef);
     }
  }

//+------------------------------------------------------------------+
//| DETECT H1 CHoCH (CHANGE OF CHARACTER)                          |
//| After liquidity sweep, require structure break in bias direction  |
//| Bull CHoCH: close > recent swing high on H1 (in downswing)      |
//| Bear CHoCH: close < recent swing low on H1 (in upswing)         |
//+------------------------------------------------------------------+
bool H1CHoCH_Confirmed(int bias)
  {
   double cl1 = iClose(_Symbol, PERIOD_H1, 1);
   int    lb  = 10;

   if(bias == 1)
     {
      // Find the most recent H1 swing high
      double swHigh = iHigh(_Symbol, PERIOD_H1, 2);
      for(int i = 2; i < lb; i++)
         swHigh = MathMax(swHigh, iHigh(_Symbol, PERIOD_H1, i));
      // CHoCH = price closed above that swing high
      return (cl1 > swHigh);
     }
   else
     {
      double swLow = iLow(_Symbol, PERIOD_H1, 2);
      for(int i = 2; i < lb; i++)
         swLow = MathMin(swLow, iLow(_Symbol, PERIOD_H1, i));
      return (cl1 < swLow);
     }
  }

//+------------------------------------------------------------------+
//| PREMIUM / DISCOUNT ZONE FILTER                                  |
//| Buy only in Discount (price < 50% of bullish swing range)        |
//| Sell only in Premium (price > 50% of bearish swing range)        |
//+------------------------------------------------------------------+
bool PremiumDiscountOK(int bias)
  {
   if(ArraySize(gSwings) < 2) return true; // No data, allow

   double h1Close = iClose(_Symbol, PERIOD_H1, 1);

   // Find most recent swing high and low from gSwings
   double nearHigh = 0, nearLow = 0;
   bool gotHigh = false, gotLow = false;

   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      if(!gotHigh && gSwings[i].isHigh)
        { nearHigh = gSwings[i].price; gotHigh = true; }
      if(!gotLow && !gSwings[i].isHigh)
        { nearLow  = gSwings[i].price; gotLow  = true; }
      if(gotHigh && gotLow) break;
     }

   if(!gotHigh || !gotLow) return true;

   double midPoint = (nearHigh + nearLow) / 2.0;

   if(bias == 1)  return (h1Close < midPoint); // Discount zone
   if(bias == -1) return (h1Close > midPoint); // Premium zone
   return true;
  }

//+------------------------------------------------------------------+
//| VOLUME CONFIRMATION ON H1                                       |
//+------------------------------------------------------------------+
bool VolumeOK()
  {
   long   vol1    = iTickVolume(_Symbol, PERIOD_H1, 1);
   double volAvg  = bVolMA[1];
   return ((double)vol1 >= volAvg * InpVolMultiplier);
  }

//+------------------------------------------------------------------+
//| CALCULATE LOT SIZE                                               |
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
//+------------------------------------------------------------------+
void ExecuteBuy(Zone &z)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr = bATR_H1[1];

   // SL just below the OB/FVG bottom + ATR buffer
   double sl = NormalizeDouble(z.bottom - InpATR_SL * atr, _Digits);
   double slDist = ask - sl;
   if(slDist <= 0.0) return;

   // TP2 = RR ratio or next swing high
   double tp2RR   = NormalizeDouble(ask + slDist * InpRR_TP2, _Digits);
   double tp2Swing = NextSwingLevel(1, ask);
   double tp       = (tp2Swing > ask && tp2Swing < tp2RR) ? tp2Swing : tp2RR;

   double lots = CalcLots(slDist);

   if(InpLogs) Print("BUY | Ask:", ask, " SL:", sl, " TP:", tp, " Lots:", lots);

   if(trade.Buy(lots, _Symbol, ask, sl, tp, "SMC BUY"))
     {
      gTradesToday++;
      int sz = ArraySize(gTrades); ArrayResize(gTrades, sz+1);
      gTrades[sz].ticket      = trade.ResultOrder();
      gTrades[sz].beSet       = false;
      gTrades[sz].scaled      = false;
      gTrades[sz].initialRisk = slDist;
      gTrades[sz].initialSL   = sl;
     }
   else Print("BUY error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| EXECUTE SELL                                                     |
//+------------------------------------------------------------------+
void ExecuteSell(Zone &z)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = bATR_H1[1];

   // SL above OB/FVG top + ATR buffer
   double sl = NormalizeDouble(z.top + InpATR_SL * atr, _Digits);
   double slDist = sl - bid;
   if(slDist <= 0.0) return;

   double tp2RR    = NormalizeDouble(bid - slDist * InpRR_TP2, _Digits);
   double tp2Swing = NextSwingLevel(-1, bid);
   double tp       = (tp2Swing < bid && tp2Swing > tp2RR) ? tp2Swing : tp2RR;

   double lots = CalcLots(slDist);

   if(InpLogs) Print("SELL | Bid:", bid, " SL:", sl, " TP:", tp, " Lots:", lots);

   if(trade.Sell(lots, _Symbol, bid, sl, tp, "SMC SELL"))
     {
      gTradesToday++;
      int sz = ArraySize(gTrades); ArrayResize(gTrades, sz+1);
      gTrades[sz].ticket      = trade.ResultOrder();
      gTrades[sz].beSet       = false;
      gTrades[sz].scaled      = false;
      gTrades[sz].initialRisk = slDist;
      gTrades[sz].initialSL   = sl;
     }
   else Print("SELL error: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| FIND NEXT SWING LEVEL FOR TP PLACEMENT                          |
//+------------------------------------------------------------------+
double NextSwingLevel(int direction, double entryPrice)
  {
   double best = 0.0;
   for(int i = 0; i < ArraySize(gSwings); i++)
     {
      double sp = gSwings[i].price;
      if(direction == 1 && sp > entryPrice && gSwings[i].isHigh)
        { if(best == 0.0 || sp < best) best = sp; }
      if(direction == -1 && sp < entryPrice && !gSwings[i].isHigh)
        { if(best == 0.0 || sp > best) best = sp; }
     }
   return best;
  }

//+------------------------------------------------------------------+
//| MANAGE OPEN TRADES: BE + PARTIAL CLOSE + ATR TRAIL              |
//+------------------------------------------------------------------+
void ManageTrades()
  {
   for(int i = 0; i < ArraySize(gTrades); i++)
     {
      ulong ticket = gTrades[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      ENUM_POSITION_TYPE pt  = (ENUM_POSITION_TYPE)posInfo.PositionType();
      double openP   = posInfo.PriceOpen();
      double curSL   = posInfo.StopLoss();
      double curTP   = posInfo.TakeProfit();
      double risk    = gTrades[i].initialRisk;
      double lots    = posInfo.Volume();
      double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double atr     = bATR_H1[0];

      if(pt == POSITION_TYPE_BUY)
        {
         double profit = bid - openP;

         // Partial close at 1× risk
         if(InpPartialClose && !gTrades[i].scaled && profit >= risk)
           {
            double half = NormLots(lots * 0.5);
            if(half >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
              {
               trade.PositionClosePartial(ticket, half);
               gTrades[i].scaled = true;
               if(InpLogs) Print("BUY partial 50% close at 1R");
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
               if(InpLogs) Print("BUY breakeven: SL->", newSL);
              }
           }

         // ATR trail at 1.5× risk
         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(bid - atr * 1.0, _Digits);
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
               if(InpLogs) Print("SELL partial 50% close at 1R");
              }
           }

         if(!gTrades[i].beSet && profit >= risk)
           {
            double newSL = NormalizeDouble(openP - 2 * _Point, _Digits);
            if(newSL < curSL)
              {
               trade.PositionModify(ticket, newSL, curTP);
               gTrades[i].beSet = true;
               if(InpLogs) Print("SELL breakeven: SL->", newSL);
              }
           }

         if(profit >= risk * 1.5)
           {
            double newSL = NormalizeDouble(ask + atr * 1.0, _Digits);
            if(newSL < curSL && newSL > ask)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }
     }

   // Clean up closed positions from array
   for(int i = ArraySize(gTrades) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(gTrades[i].ticket))
        {
         for(int j = i; j < ArraySize(gTrades) - 1; j++)
            gTrades[j] = gTrades[j+1];
         ArrayResize(gTrades, ArraySize(gTrades) - 1);
        }
  }

//+------------------------------------------------------------------+
//| TRACK LOSSES AND CONSECUTIVE LOSS STREAK                        |
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
           {
            gLossesToday++;
            gConsecLoss++;
            if(InpLogs) Print("Loss #", gLossesToday, " Consec:", gConsecLoss,
                              " P&L:", profit);
           }
         else
           {
            gConsecLoss = 0; // reset streak on win
           }
        }
     }
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
      gLastDay      = today;
      gTradesToday  = 0;
      gLossesToday  = 0;
      gDayStartEq   = AccountInfoDouble(ACCOUNT_EQUITY);
      if(InpLogs) Print("New day — counters reset. Start equity: ", gDayStartEq);
     }
  }

//+------------------------------------------------------------------+
//| KILL ZONE SESSION FILTER (GMT)                                  |
//+------------------------------------------------------------------+
bool IsKillZone()
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
   if(sp > InpMaxSpread) { if(InpLogs) Print("Spread: ", sp); return false; }
   return true;
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
//| NEWS FILTER (MT5 Economic Calendar — HIGH impact only)          |
//+------------------------------------------------------------------+
bool IsNearNews()
  {
   datetime now = TimeCurrent();
   if(now - gNewsFetched > 3600 || ArraySize(gNews) == 0)
     { FetchNews(); gNewsFetched = now; }
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
      int sz = ArraySize(gNews); ArrayResize(gNews, sz+1);
      gNews[sz].time = vals[i].time;
     }
   if(InpLogs) Print("News: ", ArraySize(gNews), " high-impact events loaded");
  }

//+------------------------------------------------------------------+
//| END                                                              |
//+------------------------------------------------------------------+
