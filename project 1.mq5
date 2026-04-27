

#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.02"

#include <Trade/Trade.mqh>

CTrade           trade;
CPositionInfo    pos;
COrderInfo       ord;

//+------------------------------------------------------------------+
//| Inputs (Bearish Optimised)                                       |
//+------------------------------------------------------------------+
input double          RiskPercent        = 1.0;            // Risk % per trade (if FixedLot=0)
input double          FixedLotSize       = 0.0;            // Fixed lot size (0 = use RiskPercent)
input ENUM_TIMEFRAMES Timeframe          = PERIOD_M5;      // Main timeframe (M5)

// --- Take profit & stop loss ---
input int             Tppoints           = 300;            // Take Profit (30 pips)
input int             SlPoints           = 150;            // Stop Loss (15 pips)
input int             TslPoints          = 20;             // Trailing Stop (points)
input int             TslTriggerPoints   = 30;             // Points profit before trailing

// --- Breakout detection ---
input int             BarsN              = 5;              // Bars to identify swing high/low
input int             OrderDistPoints    = 50;             // Distance from price for pending order
input int             ExpirationBars     = 50;             // Bars before order expires

// --- Bearish confluences ---
input bool            UseTrendFilter     = true;           // Require price below EMA50
input int             EMAPeriod          = 50;             // EMA period for trend
input bool            UseMomentumFilter  = true;           // Require bearish momentum (MACD)
input bool            UseResistanceFilter= true;           // Require price near recent swing high
input int             ResistanceLookback = 20;             // Bars to look for swing high
input bool            UseVolumeSpike     = true;           // Require tick volume spike
input double          VolumeMultiplier   = 1.5;            // Volume > average * multiplier

// --- Session filter ---
enum StartHour{inactive=0, _0100=1, _0200=2, _0300=3, _0400=4, _0500=5, _0600=6, _0700=7, _0800=8, _0900=9, _1000=10, _1100=11, _1200=12, _1300=13, _1400=14, _1500=15, _1600=16, _1700=17, _1800=18, _1900=19, _2000=20, _2100=21, _2200=22, _2300=23};
input StartHour       SHInput            = 8;              // Start Hour (London open)
enum EndHour{Inactive=0, _010=1, _020=2, _030=3, _040=4, _050=5, _060=6, _070=7, _080=8, _090=9, _100=10, _110=11, _120=12, _130=13, _140=14, _150=15, _160=16, _170=17, _180=18, _190=19, _200=20, _210=21, _220=22, _230=23};
input EndHour         EHInput            = 16;             // End Hour (NY close)

// --- Risk management ---
input bool            UseLossLimiter     = true;           // Stop trading after a loss per session

// --- Other ---
input int             InpMagic           = 298347;         // EA Magic Number
input string          TradeComment       = "BearStrike";   // Comment

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
int    SMChoice, EMChoice;
double lastSessionLossEquity = 0;
bool   sessionBlocked = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   SMChoice = SHInput;
   EMChoice = EHInput;
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   
   lastSessionLossEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   sessionBlocked = false;
   
   Print("BearStrike GBPUSDx initialized | Only SELL trades | M5");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   TrailStop();
   if(!IsNewBar()) return;
   
   // Reset session loss limiter at midnight
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(now.hour == 0 && now.min == 0) {
      sessionBlocked = false;
      lastSessionLossEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   
   // Time filter
   int Hournow = now.hour;
   if(Hournow < SMChoice) { CloseallOrders(); return; }
   if(Hournow > EMChoice && EMChoice != 0) { CloseallOrders(); return; }
   
   // Loss limiter
   if(UseLossLimiter && sessionBlocked) return;
   
   // Count existing sell positions & pending sell orders
   int SellTotal = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ord.SelectByIndex(i);
      if(ord.Symbol() == _Symbol && ord.Magic() == InpMagic) {
         if(ord.OrderType() == ORDER_TYPE_SELL_STOP) SellTotal++;
      }
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      pos.SelectByIndex(i);
      if(pos.Symbol() == _Symbol && pos.Magic() == InpMagic) {
         if(pos.PositionType() == POSITION_TYPE_SELL) SellTotal++;
      }
   }
   
   if(SellTotal > 0) return;
   
   // --- Bearish confluences ---
   if(!IsBearishTrend()) return;
   if(UseMomentumFilter && !IsBearishMomentum()) return;
   if(UseResistanceFilter && !IsNearResistance()) return;
   if(UseVolumeSpike && !IsVolumeSpike()) return;
   
   double entryPrice = findSwingHighForSell();
   if(entryPrice <= 0) return;
   
   executeSell(entryPrice);
}

//+------------------------------------------------------------------+
//| Check bearish trend: price below EMA50                           |
//+------------------------------------------------------------------+
bool IsBearishTrend() {
   if(!UseTrendFilter) return true;
   double ema[1];
   int ema_handle = iMA(_Symbol, Timeframe, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(ema_handle == INVALID_HANDLE) return false;
   if(CopyBuffer(ema_handle, 0, 0, 1, ema) != 1) { IndicatorRelease(ema_handle); return false; }
   IndicatorRelease(ema_handle);
   double close0 = iClose(_Symbol, Timeframe, 0);
   return (close0 < ema[0]);
}

//+------------------------------------------------------------------+
//| Bearish momentum: MACD < 0 and MACD < signal                     |
//+------------------------------------------------------------------+
bool IsBearishMomentum() {
   int macd_handle = iMACD(_Symbol, Timeframe, 12, 26, 9, PRICE_CLOSE);
   if(macd_handle == INVALID_HANDLE) return false;
   double macd_main[1], macd_signal[1];
   if(CopyBuffer(macd_handle, 0, 0, 1, macd_main) != 1) { IndicatorRelease(macd_handle); return false; }
   if(CopyBuffer(macd_handle, 1, 0, 1, macd_signal) != 1) { IndicatorRelease(macd_handle); return false; }
   IndicatorRelease(macd_handle);
   return (macd_main[0] < 0 && macd_main[0] < macd_signal[0]);
}

//+------------------------------------------------------------------+
//| Price near recent swing high (resistance)                        |
//+------------------------------------------------------------------+
bool IsNearResistance() {
   double highest = 0;
   for(int i = 2; i <= ResistanceLookback; i++) {
      double high = iHigh(_Symbol, Timeframe, i);
      if(high > highest) highest = high;
   }
   if(highest == 0) return false;
   double currentHigh = iHigh(_Symbol, Timeframe, 1);
   double distance = MathAbs(currentHigh - highest) / _Point;
   return (distance <= 15);
}

//+------------------------------------------------------------------+
//| Tick volume spike                                                |
//+------------------------------------------------------------------+
bool IsVolumeSpike() {
   long currentVolume = ((long)(_Symbol));   // fixed typo
   long avgVolume = 0;
   for(int i = 1; i <= 10; i++) {
      avgVolume += iVolume(_Symbol, Timeframe, i);
   }
   avgVolume /= 10;
   if(avgVolume == 0) return false;
   return (currentVolume > avgVolume * VolumeMultiplier);
}

//+------------------------------------------------------------------+
//| Find swing high with bearish candle confirmation (manual method) |
//+------------------------------------------------------------------+
double findSwingHighForSell() {
   for(int i = 2; i < 400; i++) {
      if(i <= BarsN) continue;
      double high = iHigh(_Symbol, Timeframe, i);
      // Check if it's a swing high: higher than left and right neighbors
      bool isSwingHigh = true;
      for(int j = 1; j <= BarsN; j++) {
         if(iHigh(_Symbol, Timeframe, i-j) > high) { isSwingHigh = false; break; }
         if(iHigh(_Symbol, Timeframe, i+j) > high) { isSwingHigh = false; break; }
      }
      if(isSwingHigh) {
         double open = iOpen(_Symbol, Timeframe, i);
         double close = iClose(_Symbol, Timeframe, i);
         bool bearishCandle = (close < open);
         double body = MathAbs(close - open);
         double upperWick = high - MathMax(open, close);
         bool longUpperWick = (upperWick > body * 2);
         if(bearishCandle && longUpperWick) {
            return high;
         }
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar() {
   static datetime previousTime = 0;
   datetime currentTime = iTime(_Symbol, Timeframe, 0);
   if(previousTime != currentTime) {
      previousTime = currentTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Lot size calculation (fixed or risk based)                       |
//+------------------------------------------------------------------+
double calclots(double slPoints) {
   if(FixedLotSize > 0.0) {
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0) lotStep = 0.01;
      double lot = MathFloor(FixedLotSize / lotStep) * lotStep;
      lot = MathMax(minLot, MathMin(maxLot, lot));
      return NormalizeDouble(lot, 2);
   }
   
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100;
   double ticksize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickvalue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double moneyPerLotstep = slPoints / ticksize * tickvalue * lotstep;
   double lots = MathFloor(risk / moneyPerLotstep) * lotstep;
   double minvolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxvolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volumelimit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(volumelimit != 0) lots = MathMin(lots, volumelimit);
   if(maxvolume != 0) lots = MathMin(lots, maxvolume);
   if(minvolume != 0) lots = MathMax(lots, minvolume);
   lots = NormalizeDouble(lots, 2);
   return lots;
}

//+------------------------------------------------------------------+
//| Execute Sell Stop order                                          |
//+------------------------------------------------------------------+
void executeSell(double entry) {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid < entry + OrderDistPoints * _Point) return;
   double tp = entry - Tppoints * _Point;
   double sl = entry + SlPoints * _Point;
   double lots = (RiskPercent > 0 || FixedLotSize > 0) ? calclots(sl - entry) : 0.01;
   datetime expiration = iTime(_Symbol, Timeframe, 0) + ExpirationBars * PeriodSeconds(Timeframe);
   trade.SellStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration);
}

//+------------------------------------------------------------------+
//| Close all pending orders                                         |
//+------------------------------------------------------------------+
void CloseallOrders() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ord.SelectByIndex(i);
      ulong ticket = ord.Ticket();
      if(ord.Symbol() == _Symbol && ord.Magic() == InpMagic)
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| Trailing stop for sell positions                                 |
//+------------------------------------------------------------------+
void TrailStop() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(pos.SelectByIndex(i)) {
         ulong ticket = pos.Ticket();
         if(pos.Magic() == InpMagic && pos.Symbol() == _Symbol) {
            if(pos.PositionType() == POSITION_TYPE_SELL) {
               if(ask + (TslTriggerPoints * _Point) < pos.PriceOpen()) {
                  double newSL = ask + (TslPoints * _Point);
                  if(newSL < pos.StopLoss() && newSL != 0)
                     trade.PositionModify(ticket, newSL, pos.TakeProfit());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Loss limiter                                                     |
//+------------------------------------------------------------------+
void OnTrade() {
   if(!UseLossLimiter) return;
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity < lastSessionLossEquity) {
      sessionBlocked = true;
      Print("Session blocked due to loss. Equity decreased from ", lastSessionLossEquity, " to ", currentEquity);
   }
   lastSessionLossEquity = currentEquity;
}
//+------------------------------------------------------------------+