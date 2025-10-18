//+------------------------------------------------------------------+
//|                MA_Trend_Pullback_Manager.mq5 (MT5)              |
//|  Semi-auto: One-side-per-day (H1), M15 pullback entry           |
//|  SL by structure/ATR, TP1=1R (BE), TP2=2R / EMA20 trailing      |
//+------------------------------------------------------------------+
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==== Inputs ========================================================
input string   ____General____          = "=== General ===";
input double   RiskPercent              = 0.7;       // % risk per trade
input int      MagicNumber              = 902715;
input bool     AutoPlace                = true;      // false = signals only
input int      MaxTradesPerDay          = 2;
input int      MaxPendingBars           = 6;         // cancel pending after N M15 bars
input int      MaxSpreadPoints          = 30;
input double   EntryOffsetPips          = 2.0;       // buffer above/below trigger

input string   ____MAs____              = "=== Moving Averages (M15) ===";
input int      EMA_Fast                 = 9;
input int      EMA_Mid                  = 20;
input int      EMA_Slow                 = 50;
input int      MA_Trend                 = 200;       // 200 SMA on M15
input ENUM_MA_METHOD MA_Method          = MODE_EMA;

input string   ____HigherTF____         = "=== H1 Bias ===";
input int      H1_MA_Trend              = 200;       // 200 SMA on H1
input int      H1_EMA20                 = 20;
input int      H1_EMA50                 = 50;

input string   ____ADX_ATR____          = "=== ADX / ATR ===";
input int      ADX_Period               = 14;
input double   ADX_Enter                = 22.0;
input double   ADX_Exit                 = 18.0;
input int      ATR_Period               = 14;
input double   ATR_SL_Mult              = 1.0;

input string   ____ADR____              = "=== ADR (optional filter) ===";
input int      ADR_Period               = 20;
input double   ADR_MaxUsed              = 0.8;       // avoid entries if day >80% ADR used
input bool     Use_ADR_Filter           = false;

input string   ____Sessions____         = "=== Sessions (+3) ===";
input int      LondonStartHour          = 10;        // +3 tz
input int      LondonEndHour            = 12;
input int      NYStartHour              = 15;
input int      NYEndHour                = 17;

input bool     OneSidePerDay            = true;
input bool     AllowHardFlip            = false;     // rarely switch same day
//====================================================================

//---- Handles
int hEMA_Fast, hEMA_Mid, hEMA_Slow, hMA_Trend, hATR, hADX;
int hH1_MA,   hH1_EMA20, hH1_EMA50;

//---- State
datetime lastSignalBar=0;
int      todayDate=0;
int      dayBias=0;   // 1=LONG, -1=SHORT, 0=unset

//---- Small helpers --------------------------------------------------
bool Copy1(int handle,int buffer,int shift,double &val){
   double tmp[];
   if(CopyBuffer(handle,buffer,shift,1,tmp)<1) return false;
   val=tmp[0]; return true;
}

double GetMA(int handle,int shift=1){
   double v; if(!Copy1(handle,0,shift,v)) return EMPTY_VALUE; return v;
}

bool GetADXPack(int handle,int shift,double &adx,double &diplus,double &diminus){
   double a[],p[],m[];
   if(CopyBuffer(handle,0,shift,1,a)<1) return false;
   if(CopyBuffer(handle,1,shift,1,p)<1) return false;
   if(CopyBuffer(handle,2,shift,1,m)<1) return false;
   adx=a[0]; diplus=p[0]; diminus=m[0]; return true;
}

int PipsToPoints(double pips){
   // 5-digit & 3-digit symbols: 1 pip = 10 points; legacy 4/2-digit: 1 pip = 1 point
   if(_Digits==5 || _Digits==3) return (int)MathRound(pips*10.0);
   return (int)MathRound(pips*1.0);
}

bool SpreadOK(){
   int spr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spr>0 && spr <= MaxSpreadPoints);
}

bool InSession(datetime t){
   MqlDateTime mt; TimeToStruct(t,mt);
   int hr=mt.hour;
   bool london = (hr>=LondonStartHour && hr<LondonEndHour);
   bool ny     = (hr>=NYStartHour     && hr<NYEndHour);
   return (london || ny);
}

int TradesTodayCount(){
   int total=0;

   // Positions
   for(int i=PositionsTotal()-1; i>=0; --i){
      if(!PositionSelectByIndex(i)) continue;
      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg!=(long)MagicNumber) continue;
      datetime opentime=(datetime)PositionGetInteger(POSITION_TIME);
      MqlDateTime mt; TimeToStruct(opentime,mt);
      MqlDateTime now; TimeToStruct(TimeCurrent(),now);
      int d=(mt.year*10000+mt.mon*100+mt.day);
      int dn=(now.year*10000+now.mon*100+now.day);
      if(d==dn) total++;
   }

   // Pending orders
   for(int j=OrdersTotal()-1; j>=0; --j){
      ulong ticket = OrderGetTicket(j);
      if(ticket==0) continue;
      if(!OrderSelect(ticket)) continue;
      long mg = (long)OrderGetInteger(ORDER_MAGIC);
      if(mg!=(long)MagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP){
         datetime ot=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
         MqlDateTime mt; TimeToStruct(ot,mt);
         MqlDateTime now; TimeToStruct(TimeCurrent(),now);
         int d=(mt.year*10000+mt.mon*100+mt.day);
         int dn=(now.year*10000+now.mon*100+now.day);
         if(d==dn) total++;
      }
   }
   return total;
}

double GetATR(int shift=1){ double v; if(!Copy1(hATR,0,shift,v)) return 0; return v; }

bool GetBiasH1(int &bias){
   // Bias: H1 close vs H1 200SMA and EMA20 vs EMA50
   MqlRates rates[]; if(CopyRates(_Symbol,PERIOD_H1,1,2,rates)<2) return false;
   double ma, e20, e50;
   if(!Copy1(hH1_MA,0,1,ma))  return false;
   if(!Copy1(hH1_EMA20,0,1,e20)) return false;
   if(!Copy1(hH1_EMA50,0,1,e50)) return false;

   double close=rates[0].close;
   if(close>ma && e20>=e50) bias=1;
   else if(close<ma && e20<=e50) bias=-1;
   else bias=0;
   return true;
}

bool AlignmentM15(bool longSide){
   double eF=GetMA(hEMA_Fast,1), eM=GetMA(hEMA_Mid,1), eS=GetMA(hEMA_Slow,1), ma200=GetMA(hMA_Trend,1);
   if(eF==EMPTY_VALUE||eM==EMPTY_VALUE||eS==EMPTY_VALUE||ma200==EMPTY_VALUE) return false;
   if(longSide) return (eF>eM && eM>eS && eS>ma200);
   else         return (eF<eM && eM<eS && eS<ma200);
}

bool TriggerCandle(bool longSide){
   // last closed bar
   MqlRates r[]; if(CopyRates(_Symbol,PERIOD_M15,1,2,r)<2) return false;
   double e20=GetMA(hEMA_Mid,1), e50=GetMA(hEMA_Slow,1);
   double hi=r[0].high, lo=r[0].low, cl=r[0].close, op=r[0].open;

   bool touched = longSide ? (lo<=e20 || lo<=e50) : (hi>=e20 || hi>=e50);
   if(!touched) return false;

   if(longSide) return (cl>e20 && cl>op);
   return (cl<e20 && cl<op);
}

bool MomentumOK(bool longSide){
   double adx, diP, diM;
   if(!GetADXPack(hADX,1,adx,diP,diM)) return false;
   if(adx<ADX_Enter) return false;
   if(longSide && diP<=diM) return false;
   if(!longSide && diM<=diP) return false;

   double adxPrev, p2, m2;
   if(!GetADXPack(hADX,2,adxPrev,p2,m2)) return false;
   return (adx>=adxPrev);
}

double LastSwing(bool longSide,int lookback=10){
   MqlRates r[]; if(CopyRates(_Symbol,PERIOD_M15,1,lookback,r)<lookback) return 0;
   double swing = longSide? r[0].low : r[0].high;
   for(int i=0;i<lookback;i++){
      if(longSide) swing = MathMin(swing,r[i].low);
      else         swing = MathMax(swing,r[i].high);
   }
   return swing;
}

double PointsValue(){
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pt        = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(tickSize<=0.0) tickSize=pt;
   // value per POINT:
   return (tickValue * (pt/tickSize));
}

double LotsFromRisk(double stopPoints){
   if(stopPoints<=0) return 0;
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
   double valPerPoint = PointsValue();
   if(valPerPoint<=0) return 0;
   double lots = riskMoney/(stopPoints*valPerPoint);

   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots/step)*step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}

bool ADRTooHigh(){
   if(!Use_ADR_Filter) return false;
   MqlRates d1[]; if(CopyRates(_Symbol,PERIOD_D1,0,ADR_Period+1,d1)<ADR_Period+1) return false;
   double adr=0;
   for(int i=1;i<=ADR_Period;i++) adr += (d1[i].high - d1[i].low);
   adr/=ADR_Period;
   double todayUsed = (d1[0].high - d1[0].low);
   return (adr>0 && todayUsed/adr >= ADR_MaxUsed);
}

void CancelExpiredPendings(){
   for(int i=OrdersTotal()-1;i>=0;--i){
      ulong ticket=OrderGetTicket(i); if(ticket==0) continue;
      if(!OrderSelect(ticket)) continue;
      if((int)OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP) continue;
      datetime setup=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(TimeCurrent() - setup > (MaxPendingBars*PeriodSeconds(PERIOD_M15))){
         trade.OrderDelete(ticket);
      }
   }
}

void ManageOpen(){
   // Move to BE at 1R, trail by EMA20, optional ADX exit
   double e20=GetMA(hEMA_Mid,1);

   for(int i=PositionsTotal()-1;i>=0;--i){
      if(!PositionSelectByIndex(i)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      double cur   = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double dist  = MathAbs(open - sl);
      if(dist<=0) continue;

      double rr    = (type==POSITION_TYPE_BUY) ? (cur-open)/dist : (open-cur)/dist;

      // BE at >=1R
      if(rr>=1.0){
         double newSL = open;
         if((type==POSITION_TYPE_BUY && sl<newSL) || (type==POSITION_TYPE_SELL && sl>newSL))
            trade.PositionModify(_Symbol,newSL,tp);
      }

      // EMA20 trailing
      if(e20!=EMPTY_VALUE){
         double trailSL = (type==POSITION_TYPE_BUY)? (e20 - _Point*PipsToPoints(0.1))  // ~0.1 pip buffer
                                                   : (e20 + _Point*PipsToPoints(0.1));
         if(type==POSITION_TYPE_BUY && trailSL>sl) trade.PositionModify(_Symbol,trailSL,tp);
         if(type==POSITION_TYPE_SELL && trailSL<sl) trade.PositionModify(_Symbol,trailSL,tp);
      }

      // ADX exit (optional hard exit)
      double adx,dp,dm;
      if(GetADXPack(hADX,1,adx,dp,dm) && adx<ADX_Exit){
         trade.PositionClose(_Symbol);
      }
   }
}

bool PlaceEntry(bool longSide){
   MqlRates r[]; if(CopyRates(_Symbol,PERIOD_M15,1,2,r)<2) return false;

   int    offPts = PipsToPoints(EntryOffsetPips);
   double entry  = longSide? (r[0].high + offPts*_Point)
                           : (r[0].low  - offPts*_Point);

   double atr    = GetATR(1);
   double swing  = LastSwing(longSide,10);
   if(atr<=0 || swing==0) return false;

   double sl = longSide ? MathMin(swing, entry - atr*ATR_SL_Mult)
                        : MathMax(swing, entry + atr*ATR_SL_Mult);

   double stopPoints = MathAbs(entry - sl)/_Point;
   double lots = LotsFromRisk(stopPoints);
   if(lots<=0) { Print("Lots calc failed"); return false; }

   double half = MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                         NormalizeDouble(lots/2.0,2));
   double tp1  = longSide? (entry + (entry-sl)) : (entry - (entry-sl)); // 1R

   // Pending #1 (TP1)
   MqlTradeRequest req1; MqlTradeResult res1; ZeroMemory(req1); ZeroMemory(res1);
   req1.symbol=_Symbol; req1.magic=MagicNumber; req1.deviation=10;
   req1.volume=half; req1.type_filling=ORDER_FILLING_RETURN;
   req1.action=TRADE_ACTION_PENDING;
   req1.type= longSide? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   req1.price=entry; req1.sl=sl; req1.tp=tp1;
   req1.expiration=TimeCurrent() + (MaxPendingBars*PeriodSeconds(PERIOD_M15));
   if(!OrderSend(req1,res1)){ Print("Pending #1 failed: ",_LastError); return false; }

   // Pending #2 (runner, trailed)
   MqlTradeRequest req2; MqlTradeResult res2; ZeroMemory(req2); ZeroMemory(res2);
   req2.symbol=_Symbol; req2.magic=MagicNumber; req2.deviation=10;
   req2.volume=half; req2.type_filling=ORDER_FILLING_RETURN;
   req2.action=TRADE_ACTION_PENDING;
   req2.type= longSide? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   req2.price=entry; req2.sl=sl; req2.tp=0.0;
   req2.expiration=TimeCurrent() + (MaxPendingBars*PeriodSeconds(PERIOD_M15));
   if(!OrderSend(req2,res2)){ Print("Pending #2 failed: ",_LastError); }

   return true;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // M15 handles
   hEMA_Fast = iMA(_Symbol,PERIOD_M15,EMA_Fast,0,MA_Method,PRICE_CLOSE);
   hEMA_Mid  = iMA(_Symbol,PERIOD_M15,EMA_Mid ,0,MA_Method,PRICE_CLOSE);
   hEMA_Slow = iMA(_Symbol,PERIOD_M15,EMA_Slow,0,MA_Method,PRICE_CLOSE);
   hMA_Trend = iMA(_Symbol,PERIOD_M15,MA_Trend,0,MODE_SMA,PRICE_CLOSE);
   hATR      = iATR(_Symbol,PERIOD_M15,ATR_Period);
   hADX      = iADX(_Symbol,PERIOD_M15,ADX_Period);

   // H1 handles
   hH1_MA    = iMA(_Symbol,PERIOD_H1,H1_MA_Trend,0,MODE_SMA,PRICE_CLOSE);
   hH1_EMA20 = iMA(_Symbol,PERIOD_H1,H1_EMA20,  0,MODE_EMA,PRICE_CLOSE);
   hH1_EMA50 = iMA(_Symbol,PERIOD_H1,H1_EMA50,  0,MODE_EMA,PRICE_CLOSE);

   if(hEMA_Fast<=0 || hEMA_Mid<=0 || hEMA_Slow<=0 || hMA_Trend<=0 || hATR<=0 || hADX<=0 ||
      hH1_MA<=0 || hH1_EMA20<=0 || hH1_EMA50<=0){
      Print("Indicator handle error"); return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void RefreshDayState(){
   MqlDateTime now; TimeToStruct(TimeCurrent(),now);
   int d=(now.year*10000+now.mon*100+now.day);
   if(d!=todayDate){
      todayDate=d; dayBias=0;
   }
   if(OneSidePerDay && dayBias==0 && now.hour>=LondonStartHour){
      int b=0; if(GetBiasH1(b)) dayBias=b;
   }
}

void OnTick()
{
   if(Symbol()!=_Symbol || !SpreadOK()){ CancelExpiredPendings(); return; }

   RefreshDayState();
   CancelExpiredPendings();
   ManageOpen();

   if(!InSession(TimeCurrent())) return;
   if(Use_ADR_Filter && ADRTooHigh()) return;

   // Bias
   int bias=0;
   if(OneSidePerDay) bias = dayBias;
   else GetBiasH1(bias);
   if(bias==0) return;

   bool wantLong = (bias==1);
   bool alignOK = AlignmentM15(wantLong);
   if(!alignOK) return;

   double adx,dp,dm;
   if(!GetADXPack(hADX,1,adx,dp,dm)) return;
   if(adx<ADX_Enter) return;
   if(!MomentumOK(wantLong)) return;
   if(!TriggerCandle(wantLong)) return;

   // prevent multiple per bar
   MqlRates r[]; if(CopyRates(_Symbol,PERIOD_M15,1,2,r)<2) return;
   if(r[0].time==lastSignalBar) return;

   if(TradesTodayCount()>=MaxTradesPerDay) return;

   if(AutoPlace){
      if(PlaceEntry(wantLong)){
         lastSignalBar = r[0].time;
         Print("Entry placed: ", (wantLong?"LONG":"SHORT"));
      }
   }else{
      PrintFormat("[Signal] %s @ %s | ADX=%.1f",
                  wantLong?"LONG":"SHORT", TimeToString(r[0].time), adx);
   }
}
//+------------------------------------------------------------------+
