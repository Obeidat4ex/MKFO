//+------------------------------------------------------------------+
//|                                              SessionMA_Alignment_EA.mq5 |
//|                          A simple Expert Advisor for MT5         |
//|                                                                  |
//|  This EA implements a session‑filtered moving‑average strategy.   |
//|  It waits for a specific hour (default 8:00) near the end of the |
//|  Asian session and checks the alignment of multiple EMAs:        |
//|  EMA9 > EMA21 > EMA50 > EMA100 > EMA200 for a long bias, or     |
//|  the inverse for a short bias.  If the conditions are satisfied  |
//|  and no position is currently open, the EA opens a trade at the  |
//|  next bar's open price.  It calculates the position size based   |
//|  on the specified risk percentage and a stop loss derived from   |
//|  the ATR indicator.  Trades are closed when price crosses back   |
//|  through the EMA21 or when an opposite alignment occurs.         |
//|                                                                  |
//|  NOTE: This EA is provided for educational purposes only. It     |
//|  includes minimal risk management and does not guarantee profits.|
//+------------------------------------------------------------------+
#property copyright "OpenAI"
#property version   "1.00"
#property description "Session‑filtered EMA alignment trading strategy"

#include <Trade/Trade.mqh>
// Additional headers for account and position information
#include <Trade/AccountInfo.mqh>
#include <Trade/PositionInfo.mqh>

//--- input parameters
//+------------------------------------------------------------------+
//| Session and timezone parameters                                   |
//| InpSessionHourGMT  – hour (0‑23) in GMT when the Asian session     |
//|                          typically ends and the strategy should   |
//|                          evaluate alignment (e.g., 8 for 08:00 GMT)|
//| InpServerGMTOffset – offset of your broker's server time from GMT |
//|                          (e.g., +3 hours = 3, -5 hours = -5).      |
//| The EA converts the GMT hour to server time by adding the offset   |
//| and taking modulo 24.  The result is used as the actual hour for  |
//| entry evaluation.                                                 |
//+------------------------------------------------------------------+
input int    InpSessionHourGMT  = 8;       // Session hour in GMT (0‑23)
input int    InpServerGMTOffset = 0;       // Broker server time offset from GMT
// The computed entry hour on server time is (InpSessionHourGMT + InpServerGMTOffset) mod 24
input int    InpEmaFast1      = 9;       // Fastest EMA period
input int    InpEmaFast2      = 21;      // Second fast EMA period
input int    InpEmaMid1       = 50;      // Mid EMA period
input int    InpEmaMid2       = 100;     // Second mid EMA period
input int    InpEmaSlow       = 200;     // Slow EMA period
input int    InpAtrPeriod     = 14;      // ATR period for stop loss sizing
input double InpAtrSLMult     = 2.0;     // ATR multiplier for stop loss distance
input double InpTrailingMult   = 2.0;     // ATR multiplier for trailing stop (0 = no trailing)
input double InpTrailStart     = 1.0;     // ATR multiple the price must move in favor before trailing starts
input double InpRiskPercent   = 0.5;     // Risk percentage per trade (0.1–5.0)
input double InpLots          = 0.0;     // Fixed lot size (0 = auto size by risk)

//--- global variables
CTrade        m_trade;                   // trade object for executing orders
//--- expert magic number used to identify positions
int           g_magic = 123456;
int           m_handleEmaFast1;          // indicator handles
int           m_handleEmaFast2;
int           m_handleEmaMid1;
int           m_handleEmaMid2;
int           m_handleEmaSlow;
int           m_handleAtr;

//--- variables for trailing stop logic
bool          g_inPosition = false;      // indicates if there is an active position
int           g_positionTypeMark = 0;    // stores the type of the active position (BUY/SELL)
double        g_highWatermark = 0.0;     // highest price reached since position entry (for BUY)
double        g_lowWatermark  = 0.0;     // lowest price reached since position entry (for SELL)
double        g_entryPrice    = 0.0;     // entry price of the current position

datetime      m_lastBarTime = 0;         // track last processed bar

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- create indicator handles
   m_handleEmaFast1 = iMA(_Symbol, PERIOD_CURRENT, InpEmaFast1, 0, MODE_EMA, PRICE_CLOSE);
   m_handleEmaFast2 = iMA(_Symbol, PERIOD_CURRENT, InpEmaFast2, 0, MODE_EMA, PRICE_CLOSE);
   m_handleEmaMid1  = iMA(_Symbol, PERIOD_CURRENT, InpEmaMid1, 0, MODE_EMA, PRICE_CLOSE);
   m_handleEmaMid2  = iMA(_Symbol, PERIOD_CURRENT, InpEmaMid2, 0, MODE_EMA, PRICE_CLOSE);
   m_handleEmaSlow  = iMA(_Symbol, PERIOD_CURRENT, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   m_handleAtr      = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   //--- check handles
   if(m_handleEmaFast1==INVALID_HANDLE || m_handleEmaFast2==INVALID_HANDLE ||
      m_handleEmaMid1==INVALID_HANDLE  || m_handleEmaMid2==INVALID_HANDLE  ||
      m_handleEmaSlow==INVALID_HANDLE  || m_handleAtr==INVALID_HANDLE)
     {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
     }
   //--- set up trading object
   //--- set a unique magic number for this EA
   m_trade.SetExpertMagicNumber(g_magic);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- release indicator handles
   if(m_handleEmaFast1!=INVALID_HANDLE) IndicatorRelease(m_handleEmaFast1);
   if(m_handleEmaFast2!=INVALID_HANDLE) IndicatorRelease(m_handleEmaFast2);
   if(m_handleEmaMid1!=INVALID_HANDLE)  IndicatorRelease(m_handleEmaMid1);
   if(m_handleEmaMid2!=INVALID_HANDLE)  IndicatorRelease(m_handleEmaMid2);
   if(m_handleEmaSlow!=INVALID_HANDLE)  IndicatorRelease(m_handleEmaSlow);
   if(m_handleAtr!=INVALID_HANDLE)      IndicatorRelease(m_handleAtr);
  }

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percent and ATR stop distance    |
//+------------------------------------------------------------------+
double CalculateLot(double entryPrice, double stopPrice)
  {
   //--- if fixed lots specified, return that
   if(InpLots > 0.0)
      return InpLots;
   //--- compute distance to stop in points
   double stopDistancePoints = MathAbs(entryPrice - stopPrice) / _Point;
   if(stopDistancePoints <= 0.0)
      return 0.0;
   //--- amount risked in account currency
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   //--- tick value (value of one point in account currency per lot)
   double tickValue;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, tickValue))
     {
      Print("Failed to get tick value. Error:", GetLastError());
      return 0.0;
     }
   //--- compute lot size
   double lot = riskAmount / (stopDistancePoints * tickValue);
   //--- round down to allowed step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   // round lot to nearest step
   lot = MathFloor(lot / lotStep) * lotStep;
   return lot;
  }

//+------------------------------------------------------------------+
//| Check EMA alignment for long or short                            |
//+------------------------------------------------------------------+
int CheckAlignment(double emaFast1, double emaFast2, double emaMid1, double emaMid2, double emaSlow, double price)
  {
   // return 1 for bullish alignment, -1 for bearish, 0 otherwise
   if( emaFast1 > emaFast2 && emaFast2 > emaMid1 && emaMid1 > emaMid2 && emaMid2 > emaSlow && price > emaSlow )
      return 1;
   if( emaFast1 < emaFast2 && emaFast2 < emaMid1 && emaMid1 < emaMid2 && emaMid2 < emaSlow && price < emaSlow )
      return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- process only on new bar
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == m_lastBarTime)
      return;
   m_lastBarTime = currentBar;
   //--- get current hour of server time using TimeToStruct
   MqlDateTime dt;
   TimeToStruct(currentBar, dt);
   int hour = dt.hour;
   //--- compute the desired entry hour on server time
   int entryHour = (InpSessionHourGMT + InpServerGMTOffset) % 24;
   if(entryHour < 0)
      entryHour += 24;
   //--- copy indicator values of previous closed bar (index 1) to base decisions on completed bar
   double emaFast1[1], emaFast2[1], emaMid1[1], emaMid2[1], emaSlow[1];
   double atr[1];
   if( CopyBuffer(m_handleEmaFast1, 0, 1, 1, emaFast1) < 0 ||
       CopyBuffer(m_handleEmaFast2, 0, 1, 1, emaFast2) < 0 ||
       CopyBuffer(m_handleEmaMid1,  0, 1, 1, emaMid1) < 0 ||
       CopyBuffer(m_handleEmaMid2,  0, 1, 1, emaMid2) < 0 ||
       CopyBuffer(m_handleEmaSlow,  0, 1, 1, emaSlow) < 0 ||
       CopyBuffer(m_handleAtr,      0, 1, 1, atr) < 0 )
     {
      Print("Failed to copy indicator data. Error:", GetLastError());
      return;
     }
   double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   // store the ATR value of the previous bar for trailing stop calculation
   double atrValueTrailing = atr[0];
   //--- count open positions for this EA on this symbol
   int posTotal = PositionsTotal();
   bool hasLong  = false;
   bool hasShort = false;
   //--- iterate positions to find positions belonging to this EA
   for(int i=0; i<posTotal; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
         hasLong = true;
      else if(type == POSITION_TYPE_SELL)
         hasShort = true;
     }

   //--- update watermarks and track the active position
   if(hasLong || hasShort)
     {
      // If this is the first bar with an open position, initialize watermarks
      if(!g_inPosition)
        {
         g_inPosition = true;
         g_highWatermark = 0.0;
         g_lowWatermark  = 0.0;
         // determine the active position type and entry price
         for(int i=0; i<posTotal; i++)
           {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            int type = (int)PositionGetInteger(POSITION_TYPE);
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            if(type == POSITION_TYPE_BUY)
              {
               g_positionTypeMark = POSITION_TYPE_BUY;
               g_entryPrice = entryPrice;
               g_highWatermark = entryPrice;
               break;
              }
            else if(type == POSITION_TYPE_SELL)
              {
               g_positionTypeMark = POSITION_TYPE_SELL;
               g_entryPrice = entryPrice;
               g_lowWatermark = entryPrice;
               break;
              }
           }
        }
      else
        {
         // update high/low watermark on each new bar based on previous bar's high/low
         if(g_positionTypeMark == POSITION_TYPE_BUY)
           {
            double barHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
            if(barHigh > g_highWatermark)
               g_highWatermark = barHigh;
           }
         else if(g_positionTypeMark == POSITION_TYPE_SELL)
           {
            double barLow = iLow(_Symbol, PERIOD_CURRENT, 1);
            if(barLow < g_lowWatermark)
               g_lowWatermark = barLow;
           }
        }
     }
   else
     {
      // No positions: reset watermark state
      g_inPosition = false;
      g_entryPrice = 0.0;
     }
   //--- if there is an open position, check for exit conditions and trailing stops
   if(hasLong || hasShort)
     {
      // Exit logic: close long positions if price closes below the fast EMA (emaFast2)
      if(hasLong && lastClose < emaFast2[0])
        {
         for(int i=posTotal-1; i>=0; i--)
           {
            ulong ticket=PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetInteger(POSITION_MAGIC)!=g_magic) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
              m_trade.PositionClose(ticket);
           }
        }
      // Exit logic: close short positions if price closes above the fast EMA (emaFast2)
      if(hasShort && lastClose > emaFast2[0])
        {
         for(int i=posTotal-1; i>=0; i--)
           {
            ulong ticket=PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetInteger(POSITION_MAGIC)!=g_magic) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
              m_trade.PositionClose(ticket);
           }
        }
      // Trailing stop logic: adjust stop levels based on ATR and price extremes
      // Only trail when price has moved at least InpTrailStart * ATR from the entry price in favor of the trade.
      if(InpTrailingMult > 0.0)
        {
         for(int i=posTotal-1; i>=0; i--)
           {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            double currentSL = PositionGetDouble(POSITION_SL);
            // Determine if trailing should start based on entry price and watermark
            if(g_positionTypeMark == POSITION_TYPE_BUY)
              {
               // calculate how far price has moved from entry in favor of the trade
               double moveFromEntry = g_highWatermark - g_entryPrice;
               // start trailing only when the move is at least InpTrailStart * ATR
               if(moveFromEntry >= atrValueTrailing * InpTrailStart)
                 {
                  double newStop = g_highWatermark - atrValueTrailing * InpTrailingMult;
                  // move stop only if it is higher than existing stop (or stop not set)
                  if(currentSL == 0.0 || currentSL < newStop)
                     m_trade.PositionModify(ticket, newStop, 0.0);
                 }
              }
            else if(g_positionTypeMark == POSITION_TYPE_SELL)
              {
               double moveFromEntry = g_entryPrice - g_lowWatermark;
               if(moveFromEntry >= atrValueTrailing * InpTrailStart)
                 {
                  double newStop = g_lowWatermark + atrValueTrailing * InpTrailingMult;
                  // move stop only if it is lower than existing stop (or stop not set)
                  if(currentSL == 0.0 || currentSL > newStop)
                     m_trade.PositionModify(ticket, newStop, 0.0);
                 }
              }
           }
        }
      } // end of hasLong/hasShort block
   //--- if no open positions, check entry logic at the computed entryHour
   if(!hasLong && !hasShort && hour == entryHour)
     {
      //--- determine alignment direction
      int signal = CheckAlignment(emaFast1[0], emaFast2[0], emaMid1[0], emaMid2[0], emaSlow[0], lastClose);
      if(signal != 0)
        {
         //--- compute entry price and stop loss price using ATR
         double entryPrice;
         double stopPrice;
         double atrValue = atr[0];
         if(signal > 0) // bullish
           {
            entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            stopPrice  = entryPrice - atrValue * InpAtrSLMult;
           }
         else // bearish
           {
            entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            stopPrice  = entryPrice + atrValue * InpAtrSLMult;
           }
         //--- calculate position volume
         double lot = CalculateLot(entryPrice, stopPrice);
         if(lot <= 0.0)
            return;
         //--- open trade
         bool result;
         if(signal > 0)
           {
            result = m_trade.Buy(lot, NULL, entryPrice, stopPrice, 0.0, "Session long");
           }
         else
           {
            result = m_trade.Sell(lot, NULL, entryPrice, stopPrice, 0.0, "Session short");
           }
         if(!result)
            Print("OrderSend failed: ", m_trade.ResultComment());
        }
     }
  }