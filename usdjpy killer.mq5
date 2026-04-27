
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.11"

#include <Trade/Trade.mqh>

CTrade           trade;
CPositionInfo    pos;
COrderInfo       ord;

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input double          RiskPercent        = 2;              // Risk in % per Trade
input ENUM_TIMEFRAMES Timeframe          = PERIOD_M15;     // Entry Timeframe

input int             Tppoints           = 500;            // Take Profit (10 points = 1 pip)
input int             SlPoints           = 200;            // Stop Loss (10 points = 1 pip)
input int             TslPoints          = 10;             // Trailing Stop Loss (points)
input int             TslTriggerPoints   = 15;             // Points in profit before trailing

input int             BarsN              = 5;              // Bars to identify high/low
input int             OrderDistPoints    = 100;            // Distance from price for pending order
input int             ExpirationBars     = 100;            // Bars before order expires

// Time filter
enum StartHour{inactive=0, _0100=1, _0200=2, _0300=3, _0400=4, _0500=5, _0600=6, _0700=7, _0800=8, _0900=9, _1000=10, _1100=11, _1200=12, _1300=13, _1400=14, _1500=15, _1600=16, _1700=17, _1800=18, _1900=19, _2000=20, _2100=21, _2200=22, _2300=23};
input StartHour       SHInput            = 0;              // Start Hour
enum EndHour{Inactive=0, _010=1, _020=2, _030=3, _040=4, _050=5, _060=6, _070=7, _080=8, _090=9, _100=10, _110=11, _120=12, _130=13, _140=14, _150=15, _160=16, _170=17, _180=18, _190=19, _200=20, _210=21, _220=22, _230=23};
input EndHour         EHInput            = 0;              // End Hour

// ---------- INDICATOR SELECTION ----------
enum ENUM_ENTRY_FILTER {
   FILTER_NONE,               // No filter (original breakout)
   FILTER_EMA200,             // EMA200 trend filter
   FILTER_MTF_EMA,            // Multi-Timeframe EMA
   FILTER_BREAKOUT_RETEST,    // Breakout + retest confirmation
   FILTER_SUPPORT_RESISTANCE  // Support & Resistance filter
};
input ENUM_ENTRY_FILTER EntryFilter = FILTER_EMA200;   // Choose indicator

// EMA parameters
input int              MAPeriod          = 200;          // Period for EMA200 or MTF EMA
input ENUM_TIMEFRAMES  MTF_EMA_TF        = PERIOD_H1;    // Higher timeframe for MTF EMA

// Support & Resistance parameters
input int              SR_LookbackBars   = 50;           // Bars to look back for S&R levels

// Session loss limiter
input bool             UseLossLimiter    = true;         // Stop trading after a loss per session

// Other
input int              InpMagic          = 298347;       // EA Magic Number
input string           TradeComment      = "No Stress";  // Comment

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
int    SMChoice, EMChoice;
double lastSessionLossEquity = 0;
bool   sessionBlocked = false;
int    mtf_handle_ema = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Forward declarations (to avoid implicit declaration warnings)    |
//+------------------------------------------------------------------+
void GetIndicatorSignal(bool &allowBuy, bool &allowSell);
double findLastSwingHigh();
double findLastSwingLow();
bool IsNewBar();
double findHigh();
double findLow();
double calclots(double slPoints);
void executeBuy(double entry);
void executeSell(double entry);
void CloseallOrders();
void TrailStop();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   SMChoice = SHInput;
   EMChoice = EHInput;
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   
   if(EntryFilter == FILTER_MTF_EMA) {
      mtf_handle_ema = iMA(_Symbol, MTF_EMA_TF, MAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(mtf_handle_ema == INVALID_HANDLE) {
         Print("Failed to create MTF EMA handle. Disabling filter.");
        
      }
   }
   
   lastSessionLossEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   sessionBlocked = false;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(mtf_handle_ema != INVALID_HANDLE) IndicatorRelease(mtf_handle_ema);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   TrailStop();
   if(!IsNewBar()) return;
   
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(now.hour == 0 && now.min == 0) {
      sessionBlocked = false;
      lastSessionLossEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   
   int Hournow = now.hour;
   if(Hournow < SMChoice) { CloseallOrders(); return; }
   if(Hournow > EMChoice && EMChoice != 0) { CloseallOrders(); return; }
   
   if(UseLossLimiter && sessionBlocked) return;
   
   int BuyTotal = 0, SellTotal = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ord.SelectByIndex(i);
      if(ord.Symbol() == _Symbol && ord.Magic() == InpMagic) {
         if(ord.OrderType() == ORDER_TYPE_BUY_STOP) BuyTotal++;
         if(ord.OrderType() == ORDER_TYPE_SELL_STOP) SellTotal++;
      }
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      pos.SelectByIndex(i);
      if(pos.Symbol() == _Symbol && pos.Magic() == InpMagic) {
         if(pos.PositionType() == POSITION_TYPE_BUY) BuyTotal++;
         if(pos.PositionType() == POSITION_TYPE_SELL) SellTotal++;
      }
   }
   
   bool allowBuy = false, allowSell = false;
   GetIndicatorSignal(allowBuy, allowSell);
   
   if(BuyTotal <= 0 && allowBuy) {
      double high = findHigh();
      if(high > 0) executeBuy(high);
   }
   if(SellTotal <= 0 && allowSell) {
      double low = findLow();
      if(low > 0) executeSell(low);
   }
}

//+------------------------------------------------------------------+
//| Get indicator signal based on selected filter                    |
//+------------------------------------------------------------------+
void GetIndicatorSignal(bool &allowBuy, bool &allowSell) {
   allowBuy = true;
   allowSell = true;
   
   switch(EntryFilter) {
      case FILTER_NONE:  break;
      
      case FILTER_EMA200: {
         double ema[1];
         if(CopyBuffer(iMA(_Symbol, Timeframe, MAPeriod, 0, MODE_EMA, PRICE_CLOSE), 0, 0, 1, ema) == 1) {
            double close0 = iClose(_Symbol, Timeframe, 0);
            allowBuy  = (close0 > ema[0]);
            allowSell = (close0 < ema[0]);
         }
         break;
      }
      
      case FILTER_MTF_EMA: {
         if(mtf_handle_ema != INVALID_HANDLE) {
            double mtf_ema[1];
            if(CopyBuffer(mtf_handle_ema, 0, 0, 1, mtf_ema) == 1) {
               double close_htf = iClose(_Symbol, MTF_EMA_TF, 0);
               allowBuy  = (close_htf > mtf_ema[0]);
               allowSell = (close_htf < mtf_ema[0]);
            }
         }
         break;
      }
      
      case FILTER_BREAKOUT_RETEST: {
         double high_prev = iHigh(_Symbol, Timeframe, 1);
         double low_prev  = iLow(_Symbol, Timeframe, 1);
         double close0 = iClose(_Symbol, Timeframe, 0);
         allowBuy  = (close0 > high_prev) && (SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= high_prev + OrderDistPoints * _Point);
         allowSell = (close0 < low_prev) && (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= low_prev - OrderDistPoints * _Point);
         break;
      }
      
      case FILTER_SUPPORT_RESISTANCE: {
         double lastResistance = findLastSwingHigh();
         double lastSupport    = findLastSwingLow();
         double entryBuy  = findHigh();
         double entrySell = findLow();
         if(lastResistance > 0 && entryBuy > 0)
            allowBuy = (entryBuy > lastResistance);
         else
            allowBuy = false;
         if(lastSupport > 0 && entrySell > 0)
            allowSell = (entrySell < lastSupport);
         else
            allowSell = false;
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Find last swing high (resistance)                                |
//+------------------------------------------------------------------+
double findLastSwingHigh() {
   for(int i = 1; i < SR_LookbackBars; i++) {
      double high = iHigh(_Symbol, Timeframe, i);
      if(i > BarsN && iHighest(_Symbol, Timeframe, MODE_HIGH, BarsN*2+1, i-BarsN) == i) {
         return high;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Find last swing low (support)                                    |
//+------------------------------------------------------------------+
double findLastSwingLow() {
   for(int i = 1; i < SR_LookbackBars; i++) {
      double low = iLow(_Symbol, Timeframe, i);
      if(i > BarsN && iLowest(_Symbol, Timeframe, MODE_LOW, BarsN*2+1, i-BarsN) == i) {
         return low;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Check for new bar                                                |
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
//| Find highest breakout level                                      |
//+------------------------------------------------------------------+
double findHigh() {
   double highestHigh = 0;
   for(int i = 0; i < 400; i++) {
      double high = iHigh(_Symbol, Timeframe, i);
      if(i > BarsN && iHighest(_Symbol, Timeframe, MODE_HIGH, BarsN*2+1, i-BarsN) == i) {
         if(high > highestHigh) return high;
      }
      highestHigh = MathMax(high, highestHigh);
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Find lowest breakout level                                       |
//+------------------------------------------------------------------+
double findLow() {
   double lowestLow = DBL_MAX;
   for(int i = 0; i < 400; i++) {
      double low = iLow(_Symbol, Timeframe, i);
      if(i > BarsN && iLowest(_Symbol, Timeframe, MODE_LOW, BarsN*2+1, i-BarsN) == i) {
         if(low < lowestLow) return low;
      }
      lowestLow = MathMin(low, lowestLow);
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double calclots(double slPoints) {
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
//| Execute Buy Stop order                                           |
//+------------------------------------------------------------------+
void executeBuy(double entry) {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask > entry - OrderDistPoints * _Point) return;
   double tp = entry + Tppoints * _Point;
   double sl = entry - SlPoints * _Point;
   double lots = (RiskPercent > 0) ? calclots(entry - sl) : 0.01;
   datetime expiration = iTime(_Symbol, Timeframe, 0) + ExpirationBars * PeriodSeconds(Timeframe);
   trade.BuyStop(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration);
}

//+------------------------------------------------------------------+
//| Execute Sell Stop order                                          |
//+------------------------------------------------------------------+
void executeSell(double entry) {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid < entry + OrderDistPoints * _Point) return;
   double tp = entry - Tppoints * _Point;
   double sl = entry + SlPoints * _Point;
   double lots = (RiskPercent > 0) ? calclots(sl - entry) : 0.01;
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
//| Trailing stop for open positions                                 |
//+------------------------------------------------------------------+
void TrailStop() {
   double sl = 0, tp = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(pos.SelectByIndex(i)) {
         ulong ticket = pos.Ticket();
         if(pos.Magic() == InpMagic && pos.Symbol() == _Symbol) {
            if(pos.PositionType() == POSITION_TYPE_BUY) {
               if(bid - pos.PriceOpen() > TslTriggerPoints * _Point) {
                  tp = pos.TakeProfit();
                  sl = bid - (TslPoints * _Point);
                  if(sl > pos.StopLoss() && sl != 0)
                     trade.PositionModify(ticket, sl, tp);
               }
            } else if(pos.PositionType() == POSITION_TYPE_SELL) {
               if(ask + (TslTriggerPoints * _Point) < pos.PriceOpen()) {
                  tp = pos.TakeProfit();
                  sl = ask + (TslPoints * _Point);
                  if(sl < pos.StopLoss() && sl != 0)
                     trade.PositionModify(ticket, sl, tp);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Track loss and block session                                     |
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