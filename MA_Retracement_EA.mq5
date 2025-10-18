//+------------------------------------------------------------------+
//|                                            MA_Retracement_EA.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//--- Input parameters
input group "=== MA Settings ==="
input int    MA_Fast_Period = 50;           // Fast MA Period
input int    MA_Slow_Period = 200;          // Slow MA Period
input ENUM_MA_METHOD MA_Method = MODE_EMA;  // MA Method
input ENUM_APPLIED_PRICE MA_Price = PRICE_CLOSE; // MA Applied Price

input group "=== Retracement Settings ==="
input double Retracement_Percent = 0.5;     // Retracement % (0.5 = 50%)
input int    Min_Pips_From_MA = 10;         // Min pips from MA to enter
input int    Max_Pips_From_MA = 50;         // Max pips from MA to enter
input bool   Use_Dynamic_Retracement = true; // Use dynamic retracement calculation

input group "=== Trading Settings ==="
input double Lot_Size = 0.1;                // Lot Size
input int    Magic_Number = 123456;         // Magic Number
input int    Stop_Loss_Pips = 100;          // Stop Loss in pips
input int    Take_Profit_Pips = 200;        // Take Profit in pips
input bool   Use_Trailing_Stop = true;      // Use Trailing Stop
input int    Trailing_Start_Pips = 50;      // Trailing Start in pips
input int    Trailing_Step_Pips = 10;       // Trailing Step in pips

input group "=== Risk Management ==="
input double Max_Risk_Percent = 2.0;        // Max Risk % per trade
input double Max_Spread_Pips = 3.0;         // Max Spread in pips
input int    Max_Concurrent_Trades = 1;     // Max Concurrent Trades
input bool   Use_Time_Filter = true;        // Use Time Filter
input int    Start_Hour = 8;                // Start Hour (24h format)
input int    End_Hour = 18;                 // End Hour (24h format)

input group "=== Optimization ==="
input bool   Enable_Optimization = false;   // Enable Parameter Optimization
input int    Optimization_Period = 100;     // Optimization Period (bars)
input double Min_Retracement_Test = 0.3;    // Min Retracement for Testing
input double Max_Retracement_Test = 0.8;    // Max Retracement for Testing
input double Retracement_Step = 0.1;        // Retracement Test Step

input group "=== Backtesting ==="
input bool   Enable_Backtest_Logging = true; // Enable detailed backtest logging
input bool   Show_Entry_Exit_Arrows = true;  // Show entry/exit arrows on chart
input bool   Enable_Statistics = true;       // Enable trade statistics
input int    Max_Backtest_Trades = 1000;     // Maximum trades for backtesting

//--- Global variables
int ma_fast_handle, ma_slow_handle;
double ma_fast_buffer[], ma_slow_buffer[];
datetime last_crossover_time = 0;
int crossover_direction = 0; // 1 = bullish, -1 = bearish
double last_high_price = 0, last_low_price = 0;
double optimal_retracement = 0.5;
bool optimization_complete = false;

//--- Backtesting variables
int total_trades = 0;
int winning_trades = 0;
double total_profit = 0;
double max_drawdown = 0;
double peak_equity = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Validate input parameters
    if(MA_Fast_Period >= MA_Slow_Period)
    {
        Print("Error: Fast MA period must be less than Slow MA period");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    if(Retracement_Percent <= 0 || Retracement_Percent > 1)
    {
        Print("Error: Retracement percent must be between 0 and 1");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    //--- Create MA indicator handles
    ma_fast_handle = iMA(_Symbol, _Period, MA_Fast_Period, 0, MA_Method, MA_Price);
    ma_slow_handle = iMA(_Symbol, _Period, MA_Slow_Period, 0, MA_Method, MA_Price);
    
    if(ma_fast_handle == INVALID_HANDLE || ma_slow_handle == INVALID_HANDLE)
    {
        Print("Error creating MA indicators");
        return(INIT_FAILED);
    }
    
    //--- Set arrays as series
    ArraySetAsSeries(ma_fast_buffer, true);
    ArraySetAsSeries(ma_slow_buffer, true);
    
    //--- Initialize optimization if enabled
    if(Enable_Optimization)
    {
        optimal_retracement = OptimizeRetracement();
        optimization_complete = true;
        Print("Optimization complete. Optimal retracement: ", optimal_retracement);
    }
    else
    {
        optimal_retracement = Retracement_Percent;
    }
    
    Print("MA Retracement EA initialized successfully");
    Print("Fast MA: ", MA_Fast_Period, ", Slow MA: ", MA_Slow_Period);
    Print("Retracement: ", optimal_retracement * 100, "%");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Print final backtest results
    PrintFinalResults();
    
    //--- Release indicator handles
    if(ma_fast_handle != INVALID_HANDLE)
        IndicatorRelease(ma_fast_handle);
    if(ma_slow_handle != INVALID_HANDLE)
        IndicatorRelease(ma_slow_handle);
        
    Print("MA Retracement EA deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check if we have enough bars
    if(Bars(_Symbol, _Period) < MA_Slow_Period + 10)
        return;
    
    //--- Check spread
    if(!CheckSpread())
        return;
    
    //--- Check time filter
    if(Use_Time_Filter && !IsWithinTradingHours())
        return;
    
    //--- Get MA values
    if(CopyBuffer(ma_fast_handle, 0, 0, 3, ma_fast_buffer) < 3)
        return;
    if(CopyBuffer(ma_slow_handle, 0, 0, 3, ma_slow_buffer) < 3)
        return;
    
    //--- Check for MA crossover
    CheckForCrossover();
    
    //--- Check for retracement opportunities
    CheckForRetracement();
    
    //--- Manage existing positions
    ManagePositions();
    
    //--- Update backtest statistics
    UpdateStatistics();
}

//+------------------------------------------------------------------+
//| Check for MA crossover                                           |
//+------------------------------------------------------------------+
void CheckForCrossover()
{
    //--- Check for bullish crossover (fast MA crosses above slow MA)
    if(ma_fast_buffer[1] <= ma_slow_buffer[1] && ma_fast_buffer[0] > ma_slow_buffer[0])
    {
        crossover_direction = 1;
        last_crossover_time = TimeCurrent();
        last_high_price = iHigh(_Symbol, _Period, 1);
        Print("Bullish MA crossover detected at ", TimeToString(TimeCurrent()));
    }
    
    //--- Check for bearish crossover (fast MA crosses below slow MA)
    if(ma_fast_buffer[1] >= ma_slow_buffer[1] && ma_fast_buffer[0] < ma_slow_buffer[0])
    {
        crossover_direction = -1;
        last_crossover_time = TimeCurrent();
        last_low_price = iLow(_Symbol, _Period, 1);
        Print("Bearish MA crossover detected at ", TimeToString(TimeCurrent()));
    }
}

//+------------------------------------------------------------------+
//| Check for retracement opportunities                              |
//+------------------------------------------------------------------+
void CheckForRetracement()
{
    //--- Skip if no recent crossover
    if(last_crossover_time == 0 || TimeCurrent() - last_crossover_time > 3600) // 1 hour timeout
        return;
    
    //--- Skip if we already have max trades
    if(CountPositions() >= Max_Concurrent_Trades)
        return;
    
    double current_price = (crossover_direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                                                       SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double ma_level = (crossover_direction == 1) ? ma_slow_buffer[0] : ma_slow_buffer[0];
    
    //--- Calculate retracement level
    double retracement_level;
    if(crossover_direction == 1) // Bullish crossover
    {
        double high_price = MathMax(last_high_price, iHigh(_Symbol, _Period, 1));
        retracement_level = high_price - (high_price - ma_level) * optimal_retracement;
        
        //--- Check if price has retraced to the level
        if(current_price <= retracement_level && current_price >= ma_level)
        {
            double distance_from_ma = (current_price - ma_level) / _Point;
            if(distance_from_ma >= Min_Pips_From_MA && distance_from_ma <= Max_Pips_From_MA)
            {
                OpenBuyOrder();
            }
        }
    }
    else // Bearish crossover
    {
        double low_price = MathMin(last_low_price, iLow(_Symbol, _Period, 1));
        retracement_level = low_price + (ma_level - low_price) * optimal_retracement;
        
        //--- Check if price has retraced to the level
        if(current_price >= retracement_level && current_price <= ma_level)
        {
            double distance_from_ma = (ma_level - current_price) / _Point;
            if(distance_from_ma >= Min_Pips_From_MA && distance_from_ma <= Max_Pips_From_MA)
            {
                OpenSellOrder();
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Open buy order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double lot_size = CalculateLotSize();
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lot_size;
    request.type = ORDER_TYPE_BUY;
    request.price = ask;
    request.sl = ask - Stop_Loss_Pips * _Point;
    request.tp = ask + Take_Profit_Pips * _Point;
    request.magic = Magic_Number;
    request.comment = "MA Retracement Buy";
    request.deviation = 10;
    
    if(OrderSend(request, result))
    {
        if(Enable_Backtest_Logging)
            Print("BUY ORDER: Ticket=", result.order, ", Price=", ask, ", Lot=", lot_size, 
                  ", SL=", request.sl, ", TP=", request.tp);
        
        if(Show_Entry_Exit_Arrows)
            CreateArrow(TimeCurrent(), ask, 233, "Buy Entry", clrLime);
            
        last_crossover_time = 0; // Reset crossover flag
    }
    else
    {
        if(Enable_Backtest_Logging)
            Print("Error opening buy order: ", result.retcode, " - ", result.comment);
    }
}

//+------------------------------------------------------------------+
//| Open sell order                                                  |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot_size = CalculateLotSize();
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lot_size;
    request.type = ORDER_TYPE_SELL;
    request.price = bid;
    request.sl = bid + Stop_Loss_Pips * _Point;
    request.tp = bid - Take_Profit_Pips * _Point;
    request.magic = Magic_Number;
    request.comment = "MA Retracement Sell";
    request.deviation = 10;
    
    if(OrderSend(request, result))
    {
        if(Enable_Backtest_Logging)
            Print("SELL ORDER: Ticket=", result.order, ", Price=", bid, ", Lot=", lot_size, 
                  ", SL=", request.sl, ", TP=", request.tp);
        
        if(Show_Entry_Exit_Arrows)
            CreateArrow(TimeCurrent(), bid, 234, "Sell Entry", clrRed);
            
        last_crossover_time = 0; // Reset crossover flag
    }
    else
    {
        if(Enable_Backtest_Logging)
            Print("Error opening sell order: ", result.retcode, " - ", result.comment);
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk management                     |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_amount = account_balance * Max_Risk_Percent / 100.0;
    double pip_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lot_size = risk_amount / (Stop_Loss_Pips * pip_value);
    
    //--- Normalize lot size
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    lot_size = MathMax(min_lot, MathMin(max_lot, lot_size));
    lot_size = MathRound(lot_size / lot_step) * lot_step;
    
    return MathMax(lot_size, Lot_Size);
}

//+------------------------------------------------------------------+
//| Manage existing positions                                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
    if(!Use_Trailing_Stop)
        return;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Number)
        {
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double current_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                                 SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                                 SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            double profit_pips = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                               (current_price - open_price) / _Point : 
                               (open_price - current_price) / _Point;
            
            if(profit_pips >= Trailing_Start_Pips)
            {
                double new_sl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                              current_price - Trailing_Step_Pips * _Point :
                              current_price + Trailing_Step_Pips * _Point;
                
                if(ModifyPosition(PositionGetInteger(POSITION_TICKET), new_sl))
                {
                    Print("Trailing stop updated for position ", PositionGetInteger(POSITION_TICKET));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Modify position                                                  |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double new_sl)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.sl = new_sl;
    request.tp = PositionGetDouble(POSITION_TP);
    
    return OrderSend(request, result);
}

//+------------------------------------------------------------------+
//| Count positions                                                  |
//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Number)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Check spread                                                     |
//+------------------------------------------------------------------+
bool CheckSpread()
{
    double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    double max_spread = Max_Spread_Pips * _Point;
    return spread <= max_spread;
}

//+------------------------------------------------------------------+
//| Check if within trading hours                                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
    MqlDateTime time_struct;
    TimeToStruct(TimeCurrent(), time_struct);
    int current_hour = time_struct.hour;
    
    if(Start_Hour <= End_Hour)
        return current_hour >= Start_Hour && current_hour < End_Hour;
    else
        return current_hour >= Start_Hour || current_hour < End_Hour;
}

//+------------------------------------------------------------------+
//| Optimize retracement parameter                                   |
//+------------------------------------------------------------------+
double OptimizeRetracement()
{
    Print("Starting retracement optimization...");
    
    double best_retracement = Retracement_Percent;
    double best_profit = 0;
    int test_bars = MathMin(Optimization_Period, Bars(_Symbol, _Period) - MA_Slow_Period - 10);
    int total_trades = 0;
    
    for(double test_retracement = Min_Retracement_Test; 
        test_retracement <= Max_Retracement_Test; 
        test_retracement += Retracement_Step)
    {
        double total_profit = 0;
        int trades = 0;
        
        //--- Simulate trades with this retracement level
        for(int i = MA_Slow_Period + 10; i < test_bars; i++)
        {
            //--- Get historical MA values
            double ma_fast_hist[], ma_slow_hist[];
            ArrayResize(ma_fast_hist, 3);
            ArrayResize(ma_slow_hist, 3);
            
            if(CopyBuffer(ma_fast_handle, 0, i-2, 3, ma_fast_hist) < 3) continue;
            if(CopyBuffer(ma_slow_handle, 0, i-2, 3, ma_slow_hist) < 3) continue;
            
            //--- Check for crossover
            if(ma_fast_hist[1] <= ma_slow_hist[1] && ma_fast_hist[0] > ma_slow_hist[0])
            {
                //--- Bullish crossover - check retracement
                double high_price = iHigh(_Symbol, _Period, i);
                double retracement_level = high_price - (high_price - ma_slow_hist[0]) * test_retracement;
                double entry_price = iLow(_Symbol, _Period, i);
                
                if(entry_price <= retracement_level && entry_price >= ma_slow_hist[0])
                {
                    //--- Simulate trade
                    double exit_price = iHigh(_Symbol, _Period, i + 10); // Assume 10 bar hold
                    double profit = (exit_price - entry_price) / _Point;
                    total_profit += profit;
                    trades++;
                }
            }
        }
        
        if(trades > 0 && total_profit > best_profit)
        {
            best_profit = total_profit;
            best_retracement = test_retracement;
            total_trades = trades;
        }
    }
    
    Print("Optimization complete. Best retracement: ", best_retracement, 
          ", Profit: ", best_profit, ", Trades: ", total_trades);
    
    return best_retracement;
}

//+------------------------------------------------------------------+
//| Create arrow on chart                                            |
//+------------------------------------------------------------------+
void CreateArrow(datetime time, double price, int arrow_code, string text, color clr)
{
    if(!Show_Entry_Exit_Arrows) return;
    
    string obj_name = "Arrow_" + IntegerToString(GetTickCount());
    ObjectCreate(0, obj_name, OBJ_ARROW, 0, time, price);
    ObjectSetInteger(0, obj_name, OBJPROP_ARROWCODE, arrow_code);
    ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, obj_name, OBJPROP_WIDTH, 3);
    ObjectSetString(0, obj_name, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
//| Update backtest statistics                                       |
//+------------------------------------------------------------------+
void UpdateStatistics()
{
    if(!Enable_Statistics) return;
    
    double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Update peak equity
    if(current_equity > peak_equity)
        peak_equity = current_equity;
    
    // Calculate current drawdown
    double current_drawdown = (peak_equity - current_equity) / peak_equity * 100;
    if(current_drawdown > max_drawdown)
        max_drawdown = current_drawdown;
    
    // Print statistics every 100 trades
    if(total_trades > 0 && total_trades % 100 == 0)
    {
        double win_rate = (double)winning_trades / total_trades * 100;
        Print("=== BACKTEST STATISTICS ===");
        Print("Total Trades: ", total_trades);
        Print("Winning Trades: ", winning_trades);
        Print("Win Rate: ", DoubleToString(win_rate, 2), "%");
        Print("Total Profit: ", DoubleToString(total_profit, 2));
        Print("Max Drawdown: ", DoubleToString(max_drawdown, 2), "%");
        Print("Current Equity: ", DoubleToString(current_equity, 2));
    }
}

//+------------------------------------------------------------------+
//| Print final backtest results                                     |
//+------------------------------------------------------------------+
void PrintFinalResults()
{
    if(!Enable_Statistics) return;
    
    double win_rate = (total_trades > 0) ? (double)winning_trades / total_trades * 100 : 0;
    double avg_profit = (total_trades > 0) ? total_profit / total_trades : 0;
    
    Print("=== FINAL BACKTEST RESULTS ===");
    Print("Total Trades: ", total_trades);
    Print("Winning Trades: ", winning_trades);
    Print("Losing Trades: ", total_trades - winning_trades);
    Print("Win Rate: ", DoubleToString(win_rate, 2), "%");
    Print("Total Profit: ", DoubleToString(total_profit, 2));
    Print("Average Profit per Trade: ", DoubleToString(avg_profit, 2));
    Print("Max Drawdown: ", DoubleToString(max_drawdown, 2), "%");
    Print("Final Equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
}
