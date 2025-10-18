//+------------------------------------------------------------------+
//|                                         MultiEdgeEA_Pro_v2.mq5   |
//| Clean MQL5 EA: SMA + Donchian + RSI with ATR risk & voting       |
//| Revised: no ternary dt, no inline loop vars for compatibility    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.11"

//================== Inputs ==================
input ulong   InpMagic             = 20250909;  // Magic number
input double  InpRiskPerTradePct   = 0.50;      // % balance risk per trade
input int     InpMaxPositions      = 1;         // Max positions per symbol
input double  InpMaxSpreadPoints   = 30;        // Spread filter (points)
input int     InpRolloverHour      = 22;        // Avoid trading at this hour (server), -1=off
input double  InpMinAtrFilter      = 0.0;       // Min ATR (price units) to allow entries (0=off)
input int     InpSlippagePoints    = 5;         // Slippage (points)

// Strategy toggles & vote gate
input bool Use_SMA       = true;
input bool Use_Donchian  = true;
input bool Use_RSI_MR    = true;
input int  VoteThreshold = 1;       // require this many modules to agree

// SMA
input int SMA_Fast = 20;
input int SMA_Slow = 100;

// Donchian
input int Don_Breakout = 55;        // breakout channel lookback
input int Don_Exit     = 20;        // exit channel lookback

// RSI mean reversion
input int RSI_Period = 21;
input int RSI_BuyLevel  = 30;
input int RSI_SellLevel = 70;
input int RSI_ExitMid   = 50;

// Risk / exits
input int    ATR_Period     = 14;
input double SL_ATR_Mult    = 2.5;
input double TP_ATR_Mult    = 3.0;  // 0 = off
input double Trail_ATR_Mult = 1.5;  // 0 = off
input int    MaxBarsInTrade = 240;  // 0 = off

//================== Globals ==================
MqlTick g_tick;

//================== Indicator helpers ==================
double GetATR(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   int copied = CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   if(copied <= 0) return 0.0;
   return buf[0];
}

double GetMA(const string sym, ENUM_TIMEFRAMES tf, int period, int shift,
             ENUM_MA_METHOD method=MODE_SMA, ENUM_APPLIED_PRICE price=PRICE_CLOSE)
{
   int h = iMA(sym, tf, period, 0, method, price);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   int copied = CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   if(copied <= 0) return 0.0;
   return buf[0];
}

double GetRSI(const string sym, ENUM_TIMEFRAMES tf, int period, int shift,
              ENUM_APPLIED_PRICE price=PRICE_CLOSE)
{
   int h = iRSI(sym, tf, period, price);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   int copied = CopyBuffer(h, 0, shift, 1, buf);
   IndicatorRelease(h);
   if(copied <= 0) return 0.0;
   return buf[0];
}

//================== Utilities ==================
int CountPositionsByMagic(const string sym, ulong magic)
{
   // Count open positions matching symbol and magic
   int total = PositionsTotal();
   int cnt   = 0;
   int pos   = 0;
   while(pos < total)
   {
       if(PositionSelectByIndex(pos))
       {
           if(PositionGetString(POSITION_SYMBOL) == sym &&
              PositionGetInteger(POSITION_MAGIC) == (long)magic)
               cnt++;
       }
       pos++;
   }
   return cnt;
}

bool UpdateSLTP(long pos_ticket, double new_sl, double new_tp)
{
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = pos_ticket;
   req.symbol   = _Symbol;
   req.sl       = new_sl;
   req.tp       = new_tp;
   bool ok = OrderSend(req, res);
   if(!ok) Print("SLTP update failed: ", GetLastError());
   return ok;
}

bool ClosePosition(long pos_ticket)
{
   if(!PositionSelectByTicket(pos_ticket)) return false;
   long   ptype = PositionGetInteger(POSITION_TYPE);
   double vol   = PositionGetDouble(POSITION_VOLUME);

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action    = TRADE_ACTION_DEAL;
   req.position  = pos_ticket;
   req.symbol    = _Symbol;
   req.magic     = InpMagic;
   req.deviation = InpSlippagePoints;
   if(ptype == POSITION_TYPE_BUY)  { req.type = ORDER_TYPE_SELL; req.price = g_tick.bid; }
   else                            { req.type = ORDER_TYPE_BUY;  req.price = g_tick.ask; }
   req.volume    = vol;
   bool ok = OrderSend(req, res);
   if(!ok) Print("Close failed: ", GetLastError());
   return ok;
}

//================== Signals ==================
int Signal_SMA()
{
   if(!Use_SMA || SMA_Fast<=0 || SMA_Slow<=0 || SMA_Fast>=SMA_Slow) return 0;
   double fast_prev = GetMA(_Symbol, PERIOD_CURRENT, SMA_Fast, 2, MODE_SMA, PRICE_CLOSE);
   double slow_prev = GetMA(_Symbol, PERIOD_CURRENT, SMA_Slow, 2, MODE_SMA, PRICE_CLOSE);
   double fast_now  = GetMA(_Symbol, PERIOD_CURRENT, SMA_Fast, 1, MODE_SMA, PRICE_CLOSE);
   double slow_now  = GetMA(_Symbol, PERIOD_CURRENT, SMA_Slow, 1, MODE_SMA, PRICE_CLOSE);
   if(fast_prev <= slow_prev && fast_now > slow_now) return +1;
   if(fast_prev >= slow_prev && fast_now < slow_now) return -1;
   return 0;
}

int Signal_Donchian()
{
   if(!Use_Donchian || Don_Breakout<=1) return 0;
   int hi = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, Don_Breakout, 2);
   int lo = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  Don_Breakout, 2);
   if(hi<0 || lo<0) return 0;
   double hh = iHigh(_Symbol, PERIOD_CURRENT, hi);
   double ll = iLow (_Symbol, PERIOD_CURRENT, lo);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(c1 > hh) return +1;
   if(c1 < ll) return -1;
   return 0;
}

int Signal_RSI_MR()
{
   if(!Use_RSI_MR || RSI_Period<=1) return 0;
   double r1 = GetRSI(_Symbol, PERIOD_CURRENT, RSI_Period, 1, PRICE_CLOSE);
   if(r1 < RSI_BuyLevel)  return +1;
   if(r1 > RSI_SellLevel) return -1;
   return 0;
}

//================== Trading ==================
double CalcLotByRisk(double sl_dist_price)
{
   if(InpRiskPerTradePct <= 0.0 || sl_dist_price <= 0.0) return 0.0;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_value = bal * InpRiskPerTradePct / 100.0;

   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val<=0 || tick_sz<=0) return 0.0;

   double pts = sl_dist_price / tick_sz;
   double value_per_lot = pts * tick_val;
   if(value_per_lot <= 0) return 0.0;

   double lot = risk_value / value_per_lot;

   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step<=0) step = 0.01;
   lot = MathFloor(lot/step)*step;
   if(lot < minv) lot = minv;
   if(lot > maxv) lot = maxv;
   return lot;
}

bool TryOpen(ENUM_ORDER_TYPE type)
{
   double atr = GetATR(_Symbol, PERIOD_CURRENT, ATR_Period, 1);
   if(atr <= 0) return false;

   double price = (type==ORDER_TYPE_BUY) ? g_tick.ask : g_tick.bid;
   double sl    = (type==ORDER_TYPE_BUY) ? price - SL_ATR_Mult*atr
                                         : price + SL_ATR_Mult*atr;
   double tp    = 0.0;
   if(TP_ATR_Mult > 0.0)
      tp = (type==ORDER_TYPE_BUY) ? price + TP_ATR_Mult*atr
                                  : price - TP_ATR_Mult*atr;

   double lot = CalcLotByRisk(SL_ATR_Mult*atr);
   if(lot <= 0) return false;

   MqlTradeRequest  req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.magic        = InpMagic;
   req.symbol       = _Symbol;
   req.type         = type;
   req.volume       = lot;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = InpSlippagePoints;
   req.type_filling = ORDER_FILLING_FOK;

   bool ok = OrderSend(req, res);
   if(!ok) Print("OrderSend failed: ", GetLastError());
   return ok;
}

void ManageOpenPosition()
{
   int total = PositionsTotal();
   int idx   = 0;
   while(idx < total)
   {
      if(PositionSelectByIndex(idx))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         {
            long    ptype   = PositionGetInteger(POSITION_TYPE);
            long    ticket  = (long)PositionGetInteger(POSITION_TICKET);
            double  price   = (ptype==POSITION_TYPE_BUY)? g_tick.bid : g_tick.ask;
            double  sl_cur  = PositionGetDouble(POSITION_SL);
            double  tp_cur  = PositionGetDouble(POSITION_TP);
            datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

            // ATR trailing
            if(Trail_ATR_Mult > 0.0)
            {
               double atr = GetATR(_Symbol, PERIOD_CURRENT, ATR_Period, 1);
               if(atr > 0.0)
               {
                  if(ptype == POSITION_TYPE_BUY)
                  {
                     double nsl = price - Trail_ATR_Mult*atr;
                     if(sl_cur==0.0 || nsl > sl_cur) UpdateSLTP(ticket, nsl, tp_cur);
                  }
                  else
                  {
                     double nsl = price + Trail_ATR_Mult*atr;
                     if(sl_cur==0.0 || nsl < sl_cur) UpdateSLTP(ticket, nsl, tp_cur);
                  }
               }
            }

            // RSI midline exit
            if(Use_RSI_MR && RSI_ExitMid>0)
            {
               double r = GetRSI(_Symbol, PERIOD_CURRENT, RSI_Period, 1, PRICE_CLOSE);
               if(ptype==POSITION_TYPE_BUY  && r>RSI_ExitMid)  ClosePosition(ticket);
               if(ptype==POSITION_TYPE_SELL && r<RSI_ExitMid) ClosePosition(ticket);
            }

            // Donchian opposite-channel exit
            if(Use_Donchian && Don_Exit>0)
            {
               int hi2 = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, Don_Exit, 2);
               int lo2 = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  Don_Exit, 2);
               if(hi2>=0 && lo2>=0)
               {
                  double hh = iHigh(_Symbol, PERIOD_CURRENT, hi2);
                  double ll = iLow (_Symbol, PERIOD_CURRENT, lo2);
                  if(ptype==POSITION_TYPE_BUY  && price < ll)  ClosePosition(ticket);
                  if(ptype==POSITION_TYPE_SELL && price > hh) ClosePosition(ticket);
               }
            }

            // Time-based exit
            if(MaxBarsInTrade > 0)
            {
               int bars = iBarShift(_Symbol, PERIOD_CURRENT, opened, true);
               if(bars >= MaxBarsInTrade) ClosePosition(ticket);
            }
            break; // manage only one position per symbol
         }
      }
      idx++;
   }
}

//================== Events ==================
int OnInit(){ return(INIT_SUCCEEDED); }
void OnDeinit(const int reason){}

void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_tick)) return;

   // Spread filter
   double sp = (g_tick.ask - g_tick.bid) / _Point;
   if(InpMaxSpreadPoints > 0.0 && sp > InpMaxSpreadPoints) return;

   // Rollover-hour filter (simplified; use local time only)
   if(InpRolloverHour >= 0)
   {
      int hh = TimeHour(TimeLocal());
      if(hh == InpRolloverHour) return;
   }

   // ATR activity filter
   if(InpMinAtrFilter > 0.0)
   {
      double atrf = GetATR(_Symbol, PERIOD_CURRENT, ATR_Period, 1);
      if(atrf < InpMinAtrFilter) return;
   }

   // Vote signals
   int vL = 0, vS = 0;
   int s1 = Signal_SMA();      if(s1>0) vL++; else if(s1<0) vS++;
   int s2 = Signal_Donchian(); if(s2>0) vL++; else if(s2<0) vS++;
   int s3 = Signal_RSI_MR();   if(s3>0) vL++; else if(s3<0) vS++;

   int need = (VoteThreshold < 1) ? 1 : VoteThreshold;

   // Position limit
   if(CountPositionsByMagic(_Symbol, InpMagic) >= InpMaxPositions)
   {
      ManageOpenPosition();
      return;
   }

   // Entry
   if(vL >= need)       TryOpen(ORDER_TYPE_BUY);
   else if(vS >= need)  TryOpen(ORDER_TYPE_SELL);
   else                 ManageOpenPosition();
}

//+------------------------------------------------------------------+
