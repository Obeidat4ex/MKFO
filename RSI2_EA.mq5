//+------------------------------------------------------------------+
//|                                                 RSI2_EA.mq5       |
//|  Copyright 2025, OpenAI.                                         |
//|                                                                  |
//|  This Expert Advisor implements a simple mean‑reversion system   |
//|  based on Larry Connors' 2‑period RSI strategy.  It trades in    |
//|  the direction of the long‑term trend (200‑period EMA) and opens |
//|  positions when the RSI(2) reaches extreme oversold or           |
//|  overbought levels.  A volatility‑based stop loss is used,       |
//|  calculated as a multiple of the Average True Range (ATR).       |
//|  Trades are closed when the RSI returns to mid‑range, or when    |
//|  the stop is hit.  Lot sizing is calculated so that each trade   |
//|  risks a fixed percentage of account equity.                     |
//+------------------------------------------------------------------+
#property copyright "OpenAI"
#property link      "https://openai.com"
#property version   "1.00"
#property strict

// Include the trade class for trade execution
#include <Trade/Trade.mqh>
CTrade trade;

//--- input parameters
input double   RiskPercent      = 0.5;   // Risk per trade in percent of account balance
input int      EMA_Period       = 200;   // Period of the exponential moving average (trend filter)
input int      RSI_Period       = 2;     // RSI period
input double   RSI_Oversold     = 5.0;   // Oversold threshold to trigger long setups
input double   RSI_Overbought   = 95.0;  // Overbought threshold to trigger short setups
input double   RSI_ExitLevel    = 50.0;  // RSI level used to close trades (long exits when RSI > this, shorts when RSI < 100-this)
input int      ATR_Period       = 14;    // ATR period used for stop loss sizing
input double   StopMultiplier   = 2.0;   // Stop loss distance expressed as ATR multiplier

//--- global state to track bar timing
datetime last_bar_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // initialise last_bar_time to zero
   last_bar_time = 0;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Calculate the position size based on risk percent and stop size  |
//+------------------------------------------------------------------+
double CalculateLotSize(double stop_distance)
  {
   // Retrieve symbol properties
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double min_lot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Calculate the monetary risk per lot for the given stop distance
   // Risk per lot = (stop_distance / point) * tick_value
   double risk_per_lot = 0.0;
   if(point > 0.0 && tick_value > 0.0)
     risk_per_lot = (stop_distance / point) * tick_value;

   // Determine the amount of money to risk per trade
   double risk_amount = AccountBalance() * (RiskPercent / 100.0);

   // Calculate the raw lot size
   double lot_size = 0.0;
   if(risk_per_lot > 0.0)
      lot_size = risk_amount / risk_per_lot;

   // Constrain lot size to broker limits
   if(lot_size < min_lot)
      lot_size = min_lot;
   if(lot_size > max_lot)
      lot_size = max_lot;

   // Round lot size down to the nearest step
   lot_size = MathFloor(lot_size / lot_step) * lot_step;
   // Normalize to two decimal places for most brokers
   lot_size = NormalizeDouble(lot_size, 2);

   return(lot_size);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Only operate once per new H1 bar
   datetime current_time = iTime(_Symbol, PERIOD_H1, 0);
   if(current_time == last_bar_time)
      return;
   last_bar_time = current_time;

   // Obtain indicator values from the previous completed bar (shift=1)
   double ema200 = iMA(_Symbol, PERIOD_H1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE, 1);
   double rsi    = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE, 1);
   double atr    = iATR(_Symbol, PERIOD_H1, ATR_Period, 1);
   double close_price = iClose(_Symbol, PERIOD_H1, 1);

   // Skip trading if indicators return zero (not enough data)
   if(ema200 == 0.0 || atr == 0.0)
      return;

   // Determine stop loss distance
   double stop_distance = atr * StopMultiplier;
   // Compute lot size for current stop distance
   double lot_size = CalculateLotSize(stop_distance);

   //--- Manage existing positions
   bool have_position = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol)
        {
         have_position = true;
         // Retrieve ticket and type
         ulong pos_ticket = PositionGetTicket(i);
         long  pos_type   = PositionGetInteger(POSITION_TYPE);
         // Exit conditions based on RSI returning to mid‑range
         if(pos_type == POSITION_TYPE_BUY)
           {
            // If RSI rises above the exit threshold, close long
            if(rsi > RSI_ExitLevel)
              {
               trade.PositionClose(pos_ticket);
              }
           }
         else if(pos_type == POSITION_TYPE_SELL)
           {
            // If RSI falls below the complementary exit threshold, close short
            if(rsi < (100.0 - RSI_ExitLevel))
              {
               trade.PositionClose(pos_ticket);
              }
           }
        }
     }

   //--- Entry logic (only when flat)
   if(!have_position)
     {
      // Determine trend direction using EMA200
      bool uptrend   = (close_price > ema200);
      bool downtrend = (close_price < ema200);

      // Obtain current market prices
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // Long entry: price above EMA200 and RSI deeply oversold
      if(uptrend && rsi < RSI_Oversold)
        {
         // Calculate stop loss price for long position
         double sl = ask - stop_distance;
         // Normalize stop to instrument digits
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         sl = NormalizeDouble(sl, digits);
         // Send market buy order with stop loss; no take profit (exit via RSI)
         trade.Buy(lot_size, _Symbol, 0.0, sl, 0.0);
        }
      // Short entry: price below EMA200 and RSI deeply overbought
      else if(downtrend && rsi > RSI_Overbought)
        {
         // Calculate stop loss price for short position
         double sl = bid + stop_distance;
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         sl = NormalizeDouble(sl, digits);
         // Send market sell order
         trade.Sell(lot_size, _Symbol, 0.0, sl, 0.0);
        }
     }
  }
