

#property copyright "LFT Precision EA"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//=============================
// Inputs
//=============================
input int      MagicNumber          = 123456;        // EA Magic Number
input double   RiskPercent          = 1.0;           // Risk per trade (%)
input int      MaxTradesPerDay      = 2;
input int      MaxLossesPerDay      = 2;
input double   RR_Multiple          = 2.0;           // Risk:Reward ratio

input int      FastEMA              = 20;
input int      SlowEMA              = 50;

input int      MinSL_Pips           = 10;
input int      MaxSL_Pips           = 25;

input double   MaxSpread_EURUSD     = 1.5;
input double   MaxSpread_GBPUSD     = 2.0;
input double   MaxSpread_USDJPY     = 1.8;

input bool     UseBreakEven         = true;
input bool     UseTrailing          = true;
input bool     OnePositionPerSymbol = true;

input int      LondonStartHour      = 7;
input int      LondonEndHour        = 10;
input int      OverlapStartHour     = 12;
input int      OverlapEndHour       = 16;

//=============================
// Globals
//=============================
datetime lastBarTime_M5 = 0;
int      tradesToday = 0;
int      lossesToday = 0;
int      currentDay = -1;

// Indicator handles
int      h1FastEMAHandle, h1SlowEMAHandle;
int      m15EMAHandle;

// Store initial risk for the open position (per symbol, but we keep simple for single symbol)
double   g_initialRiskPips = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetAsyncMode(false);

   // Create indicator handles
   h1FastEMAHandle = iMA(_Symbol, PERIOD_H1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h1SlowEMAHandle = iMA(_Symbol, PERIOD_H1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   m15EMAHandle    = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);

   if(h1FastEMAHandle == INVALID_HANDLE || h1SlowEMAHandle == INVALID_HANDLE ||
      m15EMAHandle == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   ResetDailyStats();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(h1FastEMAHandle);
   IndicatorRelease(h1SlowEMAHandle);
   IndicatorRelease(m15EMAHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetIfNewDay();

   // Manage open positions first
   ManageOpenPositions();

   // New bar on M5 only for entry logic
   if(!IsNewBar(PERIOD_M5))
      return;

   // Daily limits
   if(tradesToday >= MaxTradesPerDay) return;
   if(lossesToday >= MaxLossesPerDay) return;

   // Session and spread filters
   if(!IsTradingSession()) return;
   if(!SpreadOK()) return;

   // One position per symbol check (using magic number)
   if(OnePositionPerSymbol && HasPosition())
      return;

   // Get H1 bias (trend)
   int bias = GetH1Bias();
   if(bias == 0) return;

   // Signal confirmation
   if(bias == 1 && BuySignal())
      OpenTrade(ORDER_TYPE_BUY);
   else if(bias == -1 && SellSignal())
      OpenTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| H1 Bias (EMA alignment)                                          |
//+------------------------------------------------------------------+
int GetH1Bias()
{
   double emaFast[1], emaSlow[1], closeH1;
   if(CopyBuffer(h1FastEMAHandle, 0, 0, 1, emaFast) != 1) return 0;
   if(CopyBuffer(h1SlowEMAHandle, 0, 0, 1, emaSlow) != 1) return 0;
   closeH1 = iClose(_Symbol, PERIOD_H1, 0);

   if(closeH1 > emaFast[0] && emaFast[0] > emaSlow[0])
      return 1;
   if(closeH1 < emaFast[0] && emaFast[0] < emaSlow[0])
      return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Buy Signal (M15 pullback + M5 bullish engulfing)                 |
//+------------------------------------------------------------------+
bool BuySignal()
{
   double m15Close = iClose(_Symbol, PERIOD_M15, 1);
   double m15EMA[1];
   if(CopyBuffer(m15EMAHandle, 0, 1, 1, m15EMA) != 1) return false;

   // Price must be above M15 EMA (pullback condition)
   if(m15Close < m15EMA[0])
      return false;

   // M5 bullish engulfing
   double o1 = iOpen(_Symbol, PERIOD_M5, 1);
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double o2 = iOpen(_Symbol, PERIOD_M5, 2);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);

   if(c1 > o1 && c2 < o2 && c1 > o2 && o1 < c2)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Sell Signal (M15 pullback + M5 bearish engulfing)                |
//+------------------------------------------------------------------+
bool SellSignal()
{
   double m15Close = iClose(_Symbol, PERIOD_M15, 1);
   double m15EMA[1];
   if(CopyBuffer(m15EMAHandle, 0, 1, 1, m15EMA) != 1) return false;

   if(m15Close > m15EMA[0])
      return false;

   double o1 = iOpen(_Symbol, PERIOD_M5, 1);
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double o2 = iOpen(_Symbol, PERIOD_M5, 2);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);

   if(c1 < o1 && c2 > o2 && c1 < o2 && o1 > c2)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Open a trade                                                     |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pip = PipValue();

   // Dynamic stop loss based on recent volatility (simplified – use ATR or fixed)
   // For this EA we use a fixed stop of 15 pips, then clamp to min/max inputs.
   double slPips = 15.0;
   slPips = MathMax(MinSL_Pips, MathMin(MaxSL_Pips, slPips));

   // Store initial risk for later management
   g_initialRiskPips = slPips;

   double sl=0, tp=0, price=0, lot=0;

   if(type == ORDER_TYPE_BUY)
   {
      price = ask;
      sl = price - slPips * pip;
      tp = price + (slPips * RR_Multiple) * pip;
      lot = CalcLots(slPips);
      if(trade.Buy(lot, _Symbol, price, sl, tp, "LFT Buy"))
         tradesToday++;
   }
   else
   {
      price = bid;
      sl = price + slPips * pip;
      tp = price - (slPips * RR_Multiple) * pip;
      lot = CalcLots(slPips);
      if(trade.Sell(lot, _Symbol, price, sl, tp, "LFT Sell"))
         tradesToday++;
   }

   if(lot > 0)
      Print("Trade opened: ", EnumToString(type), " Lot=", lot, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
//| Lot size calculation (risk based)                                |
//+------------------------------------------------------------------+
double CalcLots(double slPips)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * RiskPercent / 100.0;

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pip = PipValue();

   double valuePerLot = (pip / tickSz) * tickVal;
   if(valuePerLot <= 0) return 0;

   double lots = riskAmt / (slPips * valuePerLot);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / step) * step;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Manage open positions (breakeven & trailing)                     |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!HasPosition()) return;

   ulong ticket = PositionGetTicket(0); // there is only one position for this symbol (OnePositionPerSymbol)
   if(ticket == 0) return;

   double pip = PipValue();
   long type = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double currentPrice = (type == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitPips = (type == POSITION_TYPE_BUY) ?
                       (currentPrice - openPrice) / pip :
                       (openPrice - currentPrice) / pip;

   // Break Even: move SL to entry when profit >= initial risk
   if(UseBreakEven && profitPips >= g_initialRiskPips)
   {
      double newSL = openPrice;
      if(type == POSITION_TYPE_BUY && currentSL < newSL)
         trade.PositionModify(ticket, newSL, currentTP);
      if(type == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))
         trade.PositionModify(ticket, newSL, currentTP);
   }

   // Trailing: when profit >= 1.5 * initial risk, trail by 10 pips
   if(UseTrailing && profitPips >= g_initialRiskPips * 1.5)
   {
      double newSL;
      if(type == POSITION_TYPE_BUY)
      {
         newSL = currentPrice - 10 * pip;
         if(newSL > currentSL)
            trade.PositionModify(ticket, newSL, currentTP);
      }
      else
      {
         newSL = currentPrice + 10 * pip;
         if(newSL < currentSL || currentSL == 0)
            trade.PositionModify(ticket, newSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if a position exists for this EA on the current symbol     |
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Session filter (London open + London-NY overlap)                 |
//+------------------------------------------------------------------+
bool IsTradingSession()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int hour = t.hour;

   bool london = (hour >= LondonStartHour && hour < LondonEndHour);
   bool overlap = (hour >= OverlapStartHour && hour < OverlapEndHour);
   return (london || overlap);
}

//+------------------------------------------------------------------+
//| Spread filter (general + pair‑specific overrides)                |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   double spreadPips = spreadPts / 10.0;

   // Pair‑specific limits (if any)
   if(_Symbol == "EURUSD" && spreadPips > MaxSpread_EURUSD) return false;
   if(_Symbol == "GBPUSD" && spreadPips > MaxSpread_GBPUSD) return false;
   if(_Symbol == "USDJPY" && spreadPips > MaxSpread_USDJPY) return false;

   // General limit for other pairs (optional)
   // if(spreadPips > 2.0) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Pip value (for 5‑digit brokers)                                  |
//+------------------------------------------------------------------+
double PipValue()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(StringFind(_Symbol, "JPY") >= 0)
      return point * 100;   // 0.001 for JPY pairs -> 0.01? Actually for 5-digit JPY, 1 pip = 0.01, point = 0.001
   else
      return point * 10;    // 0.00001 -> 0.0001 pip
   // Alternative simpler: return point * 10 for all? But JPY needs 100.
   // This is correct.
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf)
{
   static datetime lastTime = 0;
   datetime current = iTime(_Symbol, tf, 0);
   if(current != lastTime)
   {
      lastTime = current;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Daily reset (trades & losses counters)                           |
//+------------------------------------------------------------------+
void ResetIfNewDay()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day != currentDay)
   {
      currentDay = t.day;
      tradesToday = 0;
      lossesToday = 0;
      g_initialRiskPips = 0;   // reset stored risk
   }
}

void ResetDailyStats()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   currentDay = t.day;
   tradesToday = 0;
   lossesToday = 0;
   g_initialRiskPips = 0;
}

//+------------------------------------------------------------------+
//| Track closed losses (filtered by magic number)                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(deal == 0) return;

      // Get deal magic number
      long dealMagic = HistoryDealGetInteger(deal, DEAL_MAGIC);
      if(dealMagic != MagicNumber) return;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(profit < 0)
         lossesToday++;
   }
}
//+------------------------------------------------------------------+