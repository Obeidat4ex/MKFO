//+------------------------------------------------------------------+
//|                                          MultiEdgeEA_clean.mq5   |
//| Minimal compile-safe baseline (MQL5).                            |
//| No tnow / idx / TimeCurrent(), handles + CopyBuffer only.        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.06"

//---------------- Inputs ----------------
input ulong   InpMagic            = 20250909;  // Magic number
input double  InpRiskPerTradePct  = 0.50;      // Risk per trade (% of balance)
input int     InpMaxPositions     = 1;         // Max positions per symbol
input double  InpMaxSpreadPoints  = 30;        // Max spread (points)
input int     InpRolloverHour     = 22;        // Avoid trading at this server hour, -1 = off
input double  InpMinAtrFilter     = 0.0;       // Min ATR (price units) to allow entries (0=off)
input int     InpSlippagePoints   = 5;         // Slippage (points)

// Strategy toggles (simple votes demo)
input bool Use_SMA       = true;
input bool Use_Donchian  = true;
input bool Use_RSI_MR    = true;
input int  VoteThreshold = 1;

// SMA
input int SMA_Fast = 20;
input int SMA_Slow = 100;

// Donchian
input int Don_Breakout = 55;
input int Don_Exit     = 20;

// RSI MR
input int RSI_Period = 21;
input int RSI_Buy    = 30;
input int RSI_Sell   = 70;
input int RSI_Exit   = 50;

// Risk / exits
input int    ATR_Period     = 14;
input double SL_ATR_Mult    = 2.5;
input double TP_ATR_Mult    = 3.0;
input double Trail_ATR_Mult = 1.5;
input int    MaxBarsInTrade = 24*10;

//---------------- Globals ----------------
MqlTick g_tick;

//---------------- Indicator helpers (MQL5 handles) ----------------
double GetATR(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(h, 0, shift, 1, buf) <= 0) { IndicatorRelease(h); return 0.0; }
   IndicatorRelease(h);
   return buf[0];
}

double GetMA(const string sym, ENUM_TIMEFRAMES tf, int period, int shift,
             ENUM_MA_METHOD method=MODE_SMA, ENUM_APPLIED_PRICE price=PRICE_CLOSE)
{
   int h = iMA(sym, tf, period, 0, method, price);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(h, 0, shift, 1, buf) <= 0) { IndicatorRelease(h); return 0.0; }
   IndicatorRelease(h);
   return buf[0];
}

double GetRSI(const string sym, ENUM_TIMEFRAMES tf, int period, int shift,
              ENUM_APPLIED_PRICE price=PRICE_CLOSE)
{
   int h = iRSI(sym, tf, period, price);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(h, 0, shift, 1, buf) <= 0) { IndicatorRelease(h); return 0.0; }
   IndicatorRelease(h);
   return buf[0];
}

//---------------- Utilities ----------------
int CountPositionsByMagic(const string sym, ulong magic)
{
   int count = 0;
   int total = PositionsTotal();
   for(int p=0; p<total; p++)
   {
      if(!PositionSelectByIndex(p)) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == (long)magic)
         count++;
   }
   return count;
}

bool UpdateSLTP(long ticket, double new_sl, double new_tp)
{
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol = _Symbol;
   req.sl = new_sl;
   req.tp = new_tp;
   return OrderSend(req, res);
}

bool ClosePosition(long ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   long type = PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action    = TRADE_ACTION_DEAL;
   req.position  = ticket;
   req.symbol    = _Symbol;
   req.magic     = InpMagic;
   req.deviation = InpSlippagePoints;
   if(type == POSITION_TYPE_BUY)  { req.type=ORDER_TYPE_SELL; req.price=g_tick.bid; }
   else                           { req.type=ORDER_TYPE_BUY;  req.price=g_tick.ask; }
   req.volume    = vol;
   return OrderSend(req, res);
}

//---------------- Signals (simple) ----------------
int Signal_SMA()
{
   if(SMA_Fast <= 0 || SMA_Slow <= 0 || SMA_Fast >= SMA_Slow) return 0;
   double fast_prev = GetMA(_Symbol, PERIOD_CURRENT, SMA_Fast, 2, MODE_SMA, PRICE_CLOSE);
   double slow_prev = GetMA(_Symbol, PERIOD_CURRENT, SMA_Slow, 2, MODE_SMA, PRICE_CLOSE);
   double fast_now  = GetMA(_Symbol, PERIOD_CURRENT, SMA_Fast, 1, MODE_SMA, PRICE_CLOSE);
   double slow_now  = GetMA(_Symbol, PERIOD_CURRENT, SMA_Slow, 1, MODE_SMA, PRICE_CLOSE);
   if(fast_prev <= slow_prev && fast_now >  slow_now) return +1;
   if(fast_prev >= slow_prev && fast_now <  slow_now) return -1;
   return 0;
}

int Signal_Donchian()
{
   if(Don_Breakout <= 1) return 0;
   int hiIndex = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, Don_Breakout, 2);
   int loIndex = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  Don_Breakout, 2);
   if(hiIndex < 0 || loIndex < 0) return 0;
   double hh = iHigh(_Symbol, PERIOD_CURRENT, hiIndex);
   double ll = iLow (_Symbol, PERIOD_CURRENT, loIndex);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(c1 > hh) return +1;
   if(c1 < ll) return -1;
   return 0;
}

int Signal_RSI_MR()
{
   if(RSI_Period <= 1) return 0;
   double r1 = GetRSI(_Symbol, PERIOD_CURRENT, RSI_Period, 1, PRICE_CLOSE);
   if(r1 < RSI_Buy)  return +1;
   if(r1 > RSI_Sell) return -1;
   return 0;
}

//---------------- Trading ----------------
double CalcLotByRisk(double sl_dist_price)
{
   if(InpRiskPerTradePct <= 0.0) return 0.0;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_value = bal * InpRiskPerTradePct / 100.0;

   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val<=0 || tick_sz<=0) return 0.0;

   double pts = sl_dist_price / tick_sz;
   double value_per_lot = pts * tick_val;
   if(value_per_lot <= 0) return 0.0;

   double lot = risk_value / value_per_lot;
   double lotstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minlot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxlot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lotstep<=0) lotstep = 0.01;
   lot = MathMax(minlot, MathMin(maxlot, MathFloor(lot/lotstep)*lotstep));
   return lot;
}

void TryOpen(ENUM_ORDER_TYPE type)
{
   double atr = GetATR(_Symbol, PERIOD_CURRENT, ATR_Period, 1);
   if(atr <= 0) return;

   double entry = (type==ORDER_TYPE_BUY)? g_tick.ask : g_tick.bid;
   double sl    = (type==ORDER_TYPE_BUY)? entry - SL_ATR_Mult*atr : entry + SL_ATR_Mult*atr;
   double tp    = 0.0;
   if(TP_ATR_Mult > 0) tp = (type==ORDER_TYPE_BUY)? entry + TP_ATR_Mult*atr : entry - TP_ATR_Mult*atr;

   double lot = CalcLotByRisk(SL_ATR_Mult*atr);
   if(lot <= 0) return;

   MqlTradeRequest  req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action      = TRADE_ACTION_DEAL;
   req.magic       = InpMagic;
   req.symbol      = _Symbol;
   req.type        = type;
   req.volume      = lot;
   req.price       = entry;
   req.sl          = sl;
   req.tp          = tp;
   req.deviation   = InpSlippagePoints;
   req.type_filling= ORDER_FILLING_FOK;
   OrderSend(req, res);
}

void ManageOpenPosition()
{
   int total = PositionsTotal();
   for(int p=0; p<total; p++)
   {
      if(!PositionSelectByIndex(p)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      long    ptype   = PositionGetInteger(POSITION_TYPE);
      long    ticket  = (long)PositionGetInteger(POSITION_TICKET);
      double  price   = (ptype==POSITION_TYPE_BUY)? g_tick.bid : g_tick.ask;
      double  sl      = PositionGetDouble(POSITION_SL);
      double  tp      = PositionGetDouble(POSITION_TP);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

      // Trailing by ATR
      if(Trail_ATR_Mult > 0.0)
      {
         double atr = GetATR(_Symbol, PERIOD_CURRENT, ATR_Period, 1);
         if(ptype == POSITION_TYPE_BUY)
         {
            double nsl = price - Trail_ATR_Mult*atr;
            if(nsl > sl) UpdateSLTP(ticket, nsl, tp);
         }
         else
         {
            double nsl = price + Trail_ATR_Mult*atr;
            if(sl==0.0 || nsl < sl) UpdateSLTP(ticket, nsl, tp);
         }
      }

      // RSI midline exit
      if(Use_RSI_MR && RSI_Exit > 0)
      {
         double r = GetRSI(_Symbol, PERIOD_CURRENT, RSI_Period, 1, PRICE_CLOSE);
         if(ptype==POSITION_TYPE_BUY  && r>RSI_Exit) ClosePosition(ticket);
         if(ptype==POSITION_TYPE_SELL && r<RSI_Exit) ClosePosition(ticket);
      }

      // Donchian opposite-channel exit
      if(Use_Donchian && Don_Exit > 0)
      {
         int hiIndex = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, Don_Exit, 2);
         int loIndex = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  Don_Exit, 2);
         if(hiIndex>=0 && loIndex>=0)
         {
            double hh = iHigh(_Symbol, PERIOD_CURRENT, hiIndex);
            double ll = iLow (_Symbol, PERIOD_CURRENT, loIndex);
            if(ptype==POSITION_TYPE_BUY  && price < ll) ClosePosition(ticket);
            if(ptype==POSITION_TYPE_SELL && price > hh) ClosePosition(ticket);
         }
      }

      // Time-based exit
      if(MaxBarsInTrade > 0)
      {
         int barsSinceOpen = iBarShift(_Symbol, PERIOD_CURRENT, opened, true);
         if(barsSinceOpen >= MaxBarsInTrade) ClosePosition(ticket);
      }
      break; // manage first only
   }
}

//---------------- MT5 Events ----------------
int OnInit() { return(INIT_SUCCEEDED); }
void OnDeinit(const int reason) {}

void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_tick)) return;

   // Spread filter
   double spread_pts = (g_tick.ask - g_tick.bid) / _Point;
   if(InpMaxSpreadPoints > 0 && spread_pts > InpMaxSpreadPoints) return;

   // Rollover-hour filter WITHOUT TimeCurrent()/tnow
   if(InpRolloverHour >= 0)
   {
      long     lastbar = 0;
      bool     ok      = SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE, lastbar);
      datetime curTime = ok ? (datetime)lastbar : TimeLocal();
      int      curHour = TimeHour(curTime);
      if(curHour == InpRolloverHour) return;
   }

   // ATR filter
   if(InpMinAtrFilter > 0.0)
   {
      double atr = GetATR(_Symbol, PERIOD_CURRENT, ATR_Period, 1);
      if(atr < InpMinAtrFilter) return;
   }

   // Simple votes
   int votes_long = 0, votes_short = 0;
   if(Use_SMA)
   {
      int s = Signal_SMA();
      if(s>0) votes_long++; else if(s<0) votes_short++;
   }
   if(Use_Donchian)
   {
      int s = Signal_Donchian();
      if(s>0) votes_long++; else if(s<0) votes_short++;
   }
   if(Use_RSI_MR)
   {
      int s = Signal_RSI_MR();
      if(s>0) votes_long++; else if(s<0) votes_short++;
   }

   int need = (VoteThreshold<1)?1:VoteThreshold;

   // One-position-per-symbol logic
   int openCount = CountPositionsByMagic(_Symbol, InpMagic);
   if(openCount >= InpMaxPositions)
   {
      ManageOpenPosition();
      return;
   }

   if(votes_long >= need)      TryOpen(ORDER_TYPE_BUY);
   else if(votes_short >= need)TryOpen(ORDER_TYPE_SELL);
   else                        ManageOpenPosition();
}
//+------------------------------------------------------------------+
