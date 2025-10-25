//+------------------------------------------------------------------+
//|                         AsianBreakoutRetrace_Rev.mq5             |
//|  Asian session breakout -> wait N closed bars -> retrace entry   |
//|  Clean compile: no reversal code, conservative loops & vars      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade Trade;

//-------------------- Inputs --------------------//
input int      SessionStartHour    = 0;      // Asian session start (server time)
input int      SessionEndHour      = 8;      // Asian session end   (server time)
input ENUM_TIMEFRAMES WorkTF       = PERIOD_M5;

input int      MinRangePoints      = 50;     // Ignore too-small ranges
input int      MaxRangePoints      = 5000;   // Ignore too-large ranges
input int      BreakoutBufferPts   = 5;      // Close beyond range by this many points
input int      RetraceAfterBars    = 2;      // Wait N CLOSED bars after breakout
input int      RetraceTolerancePts = 10;     // How close to border counts as retrace touch

input bool     UseRangeForSLTP     = true;   // SL/TP as multiples of range?
input double   SL_RangeMult        = 1.0;
input double   TP_RangeMult        = 1.0;
input int      SL_FixedPoints      = 300;    // Used if UseRangeForSLTP=false
input int      TP_FixedPoints      = 600;

input double   FixedLots           = 0.10;   // Used if RiskPercent<=0
input double   RiskPercent         = 0.0;    // % balance risk per trade (0 = use FixedLots)
input int      SlippagePts         = 20;

input int      TrailingStartPts    = 200;    // Start trailing after this profit (points)
input int      TrailingStopPts     = 150;    // Trailing distance (points)
input int      TrailingStepPts     = 10;     // Min improvement to move SL (points)

input bool     OneTradePerDay      = true;   // At most one trade per session-day
input long     MagicNumber         = 8652001;

//-------------------- State --------------------//
enum Direction { DIR_NONE=0, DIR_UP=1, DIR_DOWN=2 };
enum Phase { P_WAIT_RANGE=0, P_WAIT_BREAKOUT=1, P_WAIT_RETRACE=2, P_DONE=3 };

datetime g_sessionDay      = 0;
double   g_hi              = 0.0;
double   g_lo              = 0.0;
int      g_phase           = P_WAIT_RANGE;
Direction g_dir            = DIR_NONE;
datetime g_breakoutBarTime = 0;
int      g_tradedDay       = -1;

//-------------------- Small helpers --------------------//
int DayOfYear(datetime t){ MqlDateTime dt; TimeToStruct(t,dt); return dt.day_of_year; }
datetime DayAnchor(datetime t){ MqlDateTime dt; TimeToStruct(t,dt); dt.hour=0;dt.min=0;dt.sec=0; return StructToTime(dt); }

bool RangeIsValid(double hi, double lo)
{
   double pts = (hi - lo)/_Point;
   if(pts < MinRangePoints) return false;
   if(pts > MaxRangePoints) return false;
   return true;
}

bool GetAsianRange(datetime now, double &hi, double &lo)
{
   datetime dayStart = DayAnchor(now);
   MqlDateTime dt; TimeToStruct(now, dt);

   datetime sesStart = dayStart + SessionStartHour*3600;
   datetime sesEnd   = dayStart + SessionEndHour*3600;

   // Wrap (e.g., 22 -> 06)
   if(SessionEndHour <= SessionStartHour)
   {
      if(dt.hour < SessionEndHour){
         datetime ydayStart = dayStart - 24*3600;
         sesStart = ydayStart + SessionStartHour*3600;
         sesEnd   = dayStart  + SessionEndHour*3600;
         dayStart = DayAnchor(sesStart);
      }else{
         datetime tmrwStart = dayStart + 24*3600;
         sesStart = dayStart + SessionStartHour*3600;
         sesEnd   = tmrwStart + SessionEndHour*3600;
      }
   }

   int startShift = iBarShift(_Symbol, WorkTF, sesStart, true);
   int endShift   = iBarShift(_Symbol, WorkTF, sesEnd,   true);
   if(startShift < 0 || endShift < 0) return false;
   if(startShift < endShift){ int tmp=startShift; startShift=endShift; endShift=tmp; }
   if(startShift == endShift) return false;

   double sHigh = -DBL_MAX, sLow = DBL_MAX;
   int i = endShift;
   while(i <= startShift)
   {
      double h = iHigh(_Symbol, WorkTF, i);
      double l = iLow (_Symbol, WorkTF, i);
      if(h > sHigh) sHigh = h;
      if(l < sLow ) sLow  = l;
      i++;
   }
   if(sHigh <= sLow) return false;

   hi = sHigh; lo = sLow;
   g_sessionDay = DayAnchor(sesStart);
   return true;
}

int ClosedBarsSince(datetime refTime)
{
   if(refTime<=0) return 0;
   int count=0;
   int limit=iBars(_Symbol,WorkTF);
   if(limit>10000) limit=10000;
   int i=1; // closed bars only
   while(i<limit)
   {
      datetime bt=iTime(_Symbol,WorkTF,i);
      if(bt<=refTime) break;
      count++;
      i++;
   }
   return count;
}

bool HasOpenPosition()
{
   int total = PositionsTotal();
   int pos = total - 1;
   while(pos >= 0)
   {
      bool sel = PositionSelectByIndex(pos);
      if(sel)
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         long   mgc = (long)PositionGetInteger(POSITION_MAGIC);
         if(sym==_Symbol && mgc==MagicNumber) return true;
      }
      pos--;
   }
   return false;
}

double NormalizeVolumeToStep(double lots)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step<=0.0) step=0.01;
   lots = MathFloor(lots/step + 1e-8)*step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   return lots; // keep as-is; broker will accept step-aligned value
}

double CalcLotsByRisk(double stopPoints)
{
   if(RiskPercent<=0.0) return NormalizeVolumeToStep(FixedLots);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * (RiskPercent/100.0);

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0 || tickSize<=0) return NormalizeVolumeToStep(FixedLots);

   double valPerPointPerLot = (tickVal / tickSize);
   if(valPerPointPerLot<=0) return NormalizeVolumeToStep(FixedLots);

   double lots = riskMoney / (stopPoints * valPerPointPerLot);
   return NormalizeVolumeToStep(lots);
}

void TrailPositions()
{
   int total = PositionsTotal();
   int pos = total - 1;
   while(pos >= 0)
   {
      bool sel = PositionSelectByIndex(pos);
      if(sel)
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         if(sym==_Symbol)
         {
            long mgc = (long)PositionGetInteger(POSITION_MAGIC);
            if(mgc==MagicNumber)
            {
               long   type      = PositionGetInteger(POSITION_TYPE);
               double sl        = PositionGetDouble(POSITION_SL);
               double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
               double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double tp        = PositionGetDouble(POSITION_TP);

               if(type == POSITION_TYPE_BUY)
               {
                  double profitPts = (bid - priceOpen)/_Point;
                  if(profitPts >= TrailingStartPts)
                  {
                     double newSL = bid - TrailingStopPts*_Point;
                     if(sl == 0 || newSL - sl >= TrailingStepPts*_Point)
                     {
                        if(newSL<bid) Trade.PositionModify(_Symbol, MathMax(sl,newSL), tp);
                     }
                  }
               }
               else if(type == POSITION_TYPE_SELL)
               {
                  double profitPts = (priceOpen - ask)/_Point;
                  if(profitPts >= TrailingStartPts)
                  {
                     double newSL = ask + TrailingStopPts*_Point;
                     if(sl == 0 || sl - newSL >= TrailingStepPts*_Point)
                     {
                        if(newSL>ask) Trade.PositionModify(_Symbol, (sl==0?newSL:MathMin(sl,newSL)), tp);
                     }
                  }
               }
            }
         }
      }
      pos--;
   }
}

bool PlaceOrder(Direction d, double hi, double lo)
{
   if(HasOpenPosition()) return false;

   double rangePts = (hi - lo)/_Point;
   double slPts = UseRangeForSLTP ? (SL_RangeMult*rangePts) : SL_FixedPoints;
   double tpPts = UseRangeForSLTP ? (TP_RangeMult*rangePts) : TP_FixedPoints;
   if(slPts<10) slPts=10;
   if(tpPts<10) tpPts=10;

   double lots = CalcLotsByRisk(slPts);
   if(lots<=0) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(SlippagePts);

   bool ok=false;
   if(d==DIR_UP)
   {
      double sl=ask - slPts*_Point;
      double tp=ask + tpPts*_Point;
      ok = Trade.Buy(lots,_Symbol,ask,sl,tp,"AsianBreakout BUY");
   }
   else if(d==DIR_DOWN)
   {
      double sl=bid + slPts*_Point;
      double tp=bid - tpPts*_Point;
      ok = Trade.Sell(lots,_Symbol,bid,sl,tp,"AsianBreakout SELL");
   }

   if(ok && OneTradePerDay)
   {
      g_tradedDay = DayOfYear(g_sessionDay);
      g_phase = P_DONE;
   }
   return ok;
}

//-------------------- Core Logic --------------------//
void ResetForNewDay()
{
   g_hi=0.0; g_lo=0.0;
   g_phase=P_WAIT_RANGE;
   g_dir=DIR_NONE;
   g_breakoutBarTime=0;
}

void OnTick()
{
   static datetime lastCalc=0;
   datetime now = TimeCurrent();

   // Reset trade limiter if day changed
   if(g_sessionDay>0)
   {
      int dnow = DayOfYear(now);
      int dses = DayOfYear(g_sessionDay);
      if(dnow!=dses && OneTradePerDay) g_tradedDay=-1;
   }

   // Recompute range periodically / while waiting range
   if(lastCalc==0 || (now-lastCalc)>=30 || g_phase==P_WAIT_RANGE)
   {
      double hi,lo;
      bool ok = GetAsianRange(now,hi,lo);
      if(ok)
      {
         g_hi=hi; g_lo=lo;
         if(RangeIsValid(g_hi,g_lo))
         {
            MqlDateTime dt; TimeToStruct(now,dt);
            bool sessionFinished;
            if(SessionEndHour>SessionStartHour) sessionFinished=(dt.hour>=SessionEndHour);
            else sessionFinished=(dt.hour>=SessionEndHour && dt.hour<SessionStartHour);
            if(sessionFinished) g_phase=P_WAIT_BREAKOUT;
         }
      }
      lastCalc=now;
   }

   // Respect one-trade-per-day
   if(OneTradePerDay && g_tradedDay==DayOfYear(g_sessionDay))
   {
      TrailPositions();
      return;
   }

   // If invalid range, just trail any open positions
   if(!RangeIsValid(g_hi,g_lo))
   {
      TrailPositions();
      return;
   }

   int nb = iBars(_Symbol,WorkTF);
   if(nb<10){ TrailPositions(); return; }

   // Last CLOSED bar data
   double c1 = iClose(_Symbol,WorkTF,1);
   double h1 = iHigh (_Symbol,WorkTF,1);
   double l1 = iLow  (_Symbol,WorkTF,1);
   datetime t1 = iTime(_Symbol,WorkTF,1);

   // --- Detect breakout (bar CLOSE beyond range + buffer) ---
   if(g_phase==P_WAIT_BREAKOUT)
   {
      if(c1 > g_hi + BreakoutBufferPts*_Point)
      {
         g_dir = DIR_UP;
         g_breakoutBarTime = t1;
         g_phase = P_WAIT_RETRACE;
      }
      else if(c1 < g_lo - BreakoutBufferPts*_Point)
      {
         g_dir = DIR_DOWN;
         g_breakoutBarTime = t1;
         g_phase = P_WAIT_RETRACE;
      }
   }

   // --- Wait N closed bars and then retrace touch to border ---
   if(g_phase==P_WAIT_RETRACE && g_breakoutBarTime>0 && g_dir!=DIR_NONE)
   {
      int closedSince = ClosedBarsSince(g_breakoutBarTime);
      if(closedSince >= RetraceAfterBars)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         bool touched=false;

         if(g_dir==DIR_UP)
         {
            if(bid >= g_hi - RetraceTolerancePts*_Point && bid <= g_hi + RetraceTolerancePts*_Point) touched=true;
            if(l1  <= g_hi + RetraceTolerancePts*_Point && l1  >= g_hi - RetraceTolerancePts*_Point) touched=true;
            if(touched){ if(PlaceOrder(DIR_UP, g_hi, g_lo)) g_phase=P_DONE; }
         }
         else if(g_dir==DIR_DOWN)
         {
            if(ask <= g_lo + RetraceTolerancePts*_Point && ask >= g_lo - RetraceTolerancePts*_Point) touched=true;
            if(h1  >= g_lo - RetraceTolerancePts*_Point && h1  <= g_lo + RetraceTolerancePts*_Point) touched=true;
            if(touched){ if(PlaceOrder(DIR_DOWN, g_hi, g_lo)) g_phase=P_DONE; }
         }
      }
   }

   // Trailing
   TrailPositions();
}

int OnInit(){ ResetForNewDay(); return(INIT_SUCCEEDED); }
void OnDeinit(const int reason){}
void OnTimer(){}
