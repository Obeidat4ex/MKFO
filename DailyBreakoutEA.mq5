//+------------------------------------------------------------------+
//|                                              DailyBreakoutEA.mq5 |
//|                        Daily Breakout Strategy EA for MT5       |
//|                                                                  |
//|  This Expert Advisor implements a simple daily breakout strategy. |
//|  At the start of each trading day (server time), it calculates   |
//|  the high, low and ATR of the previous day.  It then places a    |
//|  Buy Stop at the previous day's high and a Sell Stop at the      |
//|  previous day's low.  Each order uses an ATR‑based stop‑loss and  |
//|  an optional ATR‑based take‑profit.  The EA ensures only one     |
//|  trade is active at a time and cancels the unused pending order  |
//|  when the other triggers.  All positions are closed at the start  |
//|  of the next day before placing new orders.                       |
//|                                                                  |
//|  Inputs:                                                          |
//|    InpAtrPeriod     – ATR period for volatility calculation.       |
//|    InpStopMult      – Stop‑loss distance as multiples of ATR.      |
//|    InpTargetMult    – Take‑profit distance as multiples of ATR.    |
//|                        Set to 0 to disable a fixed take‑profit.    |
//|    InpRiskPercent   – Risk percentage per trade if lot size is     |
//|                        auto‑calculated.                            |
//|    InpLots          – Fixed lot size (set to 0 for auto sizing).    |
//|    InpMagic         – Magic number to identify this EA's trades.    |
//|                                                                  |
//|  NOTE:  This EA is provided for educational purposes. Back‑test   |
//|  thoroughly and adjust parameters to suit your broker and risk    |
//|  tolerance before trading live.                                   |
//+------------------------------------------------------------------+

#property copyright   "OpenAI"
#property link        ""
#property version     "1.00"
#property description "Daily breakout strategy using ATR‑based stops"

#include <Trade/Trade.mqh>
#include <Trade/AccountInfo.mqh>

//--- input parameters
input int      InpAtrPeriod   = 14;      // ATR period (daily)
input double   InpStopMult    = 1.0;     // Stop‑loss distance in ATR multiples
input double   InpTargetMult  = 0.0;     // Take‑profit distance in ATR multiples (0 = no TP)
input double   InpRiskPercent = 1.0;     // Risk percentage per trade (0.1–5.0)
input double   InpLots        = 0.0;     // Fixed lot size (0 = auto size by risk)
input int      InpMagic       = 20251012; // Magic number for this EA

//--- global variables
CTrade      m_trade;
int         m_atrHandle = INVALID_HANDLE;
datetime    g_lastDay = 0;           // last processed day (server time, date only)
double      g_prevHigh = 0.0;
double      g_prevLow  = 0.0;
double      g_prevAtr  = 0.0;
ulong       g_buyStopTicket  = 0;
ulong       g_sellStopTicket = 0;

//--- function to calculate lot size based on risk
double CalculateLot(double stopDistance)
  {
   // If fixed lots specified, return that
   if(InpLots > 0.0)
      return InpLots;
   // Risk amount in account currency
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   // pip value per lot
   double tickValue;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, tickValue))
      return 0.0;
   // stopDistance is price distance (price difference). Convert to points
   double stopPoints = stopDistance / _Point;
   if(stopPoints <= 0.0)
      return 0.0;
   double lot = riskAmount / (stopPoints * tickValue);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   lot = MathFloor(lot / lotStep) * lotStep;
   return lot;
  }

//--- function to cancel all pending orders placed by this EA
void CancelPendingOrders()
  {
   int total = OrdersTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      // check only pending orders with this magic and symbol
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
        {
         m_trade.OrderDelete(ticket);
        }
     }
  // reset our stored ticket IDs since all pending orders are now removed
  g_buyStopTicket = 0;
  g_sellStopTicket = 0;
  }

//--- function to close all open positions of this EA
void CloseOpenPositions()
  {
   int total = PositionsTotal();
   for(int i=total-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      m_trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // create daily ATR handle
   m_atrHandle = iATR(_Symbol, PERIOD_D1, InpAtrPeriod);
   if(m_atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle: ", GetLastError());
      return INIT_FAILED;
     }
   // set expert magic number
   m_trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(m_atrHandle != INVALID_HANDLE) IndicatorRelease(m_atrHandle);
  }

//+------------------------------------------------------------------+
//| Trade transaction event handler                                  |
//| This event is called on every trade transaction (order placed,   |
//| modified, filled or removed). We use it to immediately cancel    |
//| any remaining pending orders after one of our stop orders is     |
//| executed. Without this, there is a small chance both the buy and |
//| sell stops could trigger if price gaps beyond both levels        |
//| between ticks.                                                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // We are interested in new deals (TRADE_TRANSACTION_DEAL_ADD) only
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      // Check if we now have an open position on this symbol with our magic number
      int posTotal = PositionsTotal();
      for(int i=0; i<posTotal; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         // Only consider positions on this symbol and with our magic
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         // Found a position opened by this EA. Cancel any remaining pending orders
         // and reset our stored ticket IDs so that the opposite order isn't referenced further.
         CancelPendingOrders();
         g_buyStopTicket = 0;
         g_sellStopTicket = 0;
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Trade event handler                                              |
//| This function is called after any trade activity (order placed,  |
//| position opened/closed, etc.). We use it to ensure that once a   |
//| position is open for this EA, all remaining pending orders are   |
//| cancelled immediately. This acts as a safety net in case the     |
//| OnTradeTransaction() handler above doesn't catch the event        |
//| promptly enough.                                                 |
//+------------------------------------------------------------------+
void OnTrade()
  {
   // If a position exists for our symbol and magic, cancel any pending orders
   int posTotal = PositionsTotal();
   for(int i=0; i<posTotal; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      // Found a position for this EA
      CancelPendingOrders();
      break;
     }

   // Additional logic: if one of our pending orders has been filled or cancelled,
   // delete the opposite pending order. We store order tickets in
   // g_buyStopTicket and g_sellStopTicket when placing orders. If OrderSelect()
   // returns false for one ticket, it means the order is no longer active
   // (triggered or cancelled). In that case, remove the other order to enforce
   // the one‑cancels‑the‑other (OCO) behaviour.
   // Check buy stop execution or removal
   if(g_buyStopTicket != 0)
     {
      if(!OrderSelect(g_buyStopTicket))
        {
         // buy stop no longer exists (filled or cancelled)
         if(g_sellStopTicket != 0)
           {
            if(OrderSelect(g_sellStopTicket))
              {
               m_trade.OrderDelete(g_sellStopTicket);
              }
            g_sellStopTicket = 0;
           }
         g_buyStopTicket = 0;
        }
     }
   // Check sell stop execution or removal
   if(g_sellStopTicket != 0)
     {
      if(!OrderSelect(g_sellStopTicket))
        {
         // sell stop no longer exists (filled or cancelled)
         if(g_buyStopTicket != 0)
           {
            if(OrderSelect(g_buyStopTicket))
              {
               m_trade.OrderDelete(g_buyStopTicket);
              }
            g_buyStopTicket = 0;
           }
         g_sellStopTicket = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//| Check if a new day has started                                   |
//+------------------------------------------------------------------+
bool IsNewDay(datetime currentTime)
  {
   // extract date part (year, month, day) into a date value
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   datetime day = StructToTime(dt) - dt.hour*3600 - dt.min*60 - dt.sec;
   if(day != g_lastDay)
     {
      g_lastDay = day;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime timeCurrent = TimeCurrent();
   // check for new day
   if(IsNewDay(timeCurrent))
     {
      // cancel any pending orders from previous day and close open positions
      CancelPendingOrders();
      CloseOpenPositions();
      // determine previous day's high, low
      double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
      double prevLow  = iLow(_Symbol,  PERIOD_D1, 1);
      // get previous day's ATR value via indicator buffer
      double atrVal[];
      ArraySetAsSeries(atrVal, true);
      if(CopyBuffer(m_atrHandle, 0, 1, 1, atrVal) <= 0)
        {
         Print("ATR CopyBuffer error: ", GetLastError());
         return;
        }
      double prevAtr = atrVal[0];
      // store global values
      g_prevHigh = prevHigh;
      g_prevLow  = prevLow;
      g_prevAtr  = prevAtr;
      // compute lot size based on stop distance (ATR)
      double stopDist = InpStopMult * prevAtr;
      double volume = CalculateLot(stopDist);
      if(volume <= 0.0)
        {
         Print("Lot calculation failed.");
         return;
        }
      // compute SL and TP for buy stop
      double buyPrice = prevHigh;
      double buySL    = buyPrice - stopDist;
      double buyTP    = (InpTargetMult > 0.0) ? buyPrice + InpTargetMult * prevAtr : 0.0;
      // compute SL and TP for sell stop
      double sellPrice = prevLow;
      double sellSL    = sellPrice + stopDist;
      double sellTP    = (InpTargetMult > 0.0) ? sellPrice - InpTargetMult * prevAtr : 0.0;
      // round prices to allowable digits
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      buyPrice  = NormalizeDouble(buyPrice, _Digits);
      buySL     = NormalizeDouble(buySL,    _Digits);
      buyTP     = NormalizeDouble(buyTP,    _Digits);
      sellPrice = NormalizeDouble(sellPrice,_Digits);
      sellSL    = NormalizeDouble(sellSL,   _Digits);
      sellTP    = NormalizeDouble(sellTP,   _Digits);
      // place pending orders
      if(prevHigh != 0.0 && prevLow != 0.0 && prevAtr > 0.0)
        {
         // buy stop
         // The BuyStop() method has optional parameters for order lifetime, expiration and comment.
         // We supply the default lifetime (ORDER_TIME_GTC) and zero expiration, followed by a comment.
         // Pass the current symbol explicitly to avoid issues with NULL conversion
         if(!m_trade.BuyStop(volume, buyPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "Daily breakout buy"))
           {
            Print("BuyStop order failed: ", m_trade.ResultComment());
           }
         else
           {
            g_buyStopTicket = m_trade.ResultOrder();
           }
         // sell stop
         if(!m_trade.SellStop(volume, sellPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "Daily breakout sell"))
           {
            Print("SellStop order failed: ", m_trade.ResultComment());
           }
         else
           {
            g_sellStopTicket = m_trade.ResultOrder();
           }
        }
     }
   // if there is an open position, cancel opposite pending order
   // and manage end‑of‑day closings
   // check open position
   bool hasPosition = false;
   int posTotal = PositionsTotal();
   for(int i=0; i<posTotal; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      hasPosition = true;
      // We have a position, so cancel any remaining pending orders and reset ticket IDs.
      CancelPendingOrders();
      // Our CancelPendingOrders function resets g_buyStopTicket and g_sellStopTicket automatically.
      break;
     }
  }
