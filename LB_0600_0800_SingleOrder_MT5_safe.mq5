#property strict
#property version "2.1"
#include <Trade/Trade.mqh>

CTrade trade;
string Sym; double Pt; int Dig;

/*** Inputs ***/
input bool  UseChartTimeDirect   = true;
input int   ServerGMTOffsetHours = 3;
input int   RangeStartHourGMT    = 6;
input int   RangeEndHourGMT      = 8;
input int   CancelHourGMT        = 16;
input ENUM_TIMEFRAMES BoxTF      = PERIOD_M15;

input int   Buffer_Points        = 5;
input int   MaxSpread_Points     = 30;
enum EntryConfirm{ENTRY_ON_TICK=0,ENTRY_ON_M15_CLOSE=1};
input EntryConfirm EntryMode     = ENTRY_ON_TICK;

enum ExitModeEnum{EXIT_FIXED_POINTS=0,EXIT_ATR_MULTIPLIER=1};
input ExitModeEnum ExitMode      = EXIT_ATR_MULTIPLIER;
input int   TP_Points_Fixed      = 400;
input int   SL_Points_Fixed      = 250;
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_M15;
input int   ATR_Period           = 14;
input double TP_ATR_Mult         = 2.0;
input double SL_ATR_Mult         = 1.2;
input int   Min_TP_Points        = 250;
input int   Max_TP_Points        = 2000;
input int   Min_SL_Points        = 150;
input int   Max_SL_Points        = 1500;

enum TPStyle{TP_NORMAL=0,TP_EQUAL_SL_DISTANCE=1};
input TPStyle TP_Mode            = TP_NORMAL;

enum TrailModeEnum{TRAIL_OFF=0,TRAIL_FIXED=1,TRAIL_ATR=2};
input TrailModeEnum TrailMode    = TRAIL_ATR;
input int   TrailStart_Points    = 200;
input bool  TrailOnlyOnBarClose  = false;
input int   Trail_Fixed_Distance = 250;
input double Trail_ATR_Mult      = 1.0;

input double FixedLots           = 0.10;
input long   MagicNumber         = 1006008;

input bool   AllowMonday         = true;
input bool   AllowTuesday        = true;
input bool   AllowWednesday      = true;
input bool   AllowThursday       = true;
input bool   AllowFriday         = true;

input bool   DrawBoxAndTriggers  = true;
input color  BoxColor            = clrDodgerBlue;
input color  TriggerColor        = clrTomato;
input color  GuideColor          = clrLime;
input bool   VerboseLog          = true;

input bool   UseMartingale       = true;
input double MartingaleFactor    = 2.0;
input int    MaxFlipsPerDay      = 2;

/*** State ***/
datetime g_day=0;
bool  g_boxReady=false;
double g_boxHigh=0.0,g_boxLow=0.0,g_trigHigh=0.0,g_trigLow=0.0;

bool  g_inPosition=false; int g_dir=0; double g_entry=0.0;
double g_targetTP_pts=0.0,g_targetSL_pts=0.0;
double g_trailLevel=0.0; datetime g_lastTrailBar=0;
int    g_cycleFlips=0; double g_cycleBaseLots=0.0; bool g_submitting=false;

datetime g_lastM15bar=0;

string OBJ_BOX="LB_BOX", OBJ_H="LB_HI", OBJ_L="LB_LO", OBJ_TH="LB_TH", OBJ_TL="LB_TL";
string OBJ_TP="LB_TP", OBJ_SL="LB_SL";

/*** Utils ***/
void Log(string s){ if(VerboseLog) Print("[LB] ",s); }

datetime DayStart(datetime ts){ MqlDateTime x; TimeToStruct(ts,x); x.hour=0; x.min=0; x.sec=0; return StructToTime(x); }
bool WeekdayOK(datetime ts){
  MqlDateTime t; TimeToStruct(ts,t); int w=t.day_of_week; if(w==0) w=7;
  if(w==1) return AllowMonday; if(w==2) return AllowTuesday; if(w==3) return AllowWednesday;
  if(w==4) return AllowThursday; if(w==5) return AllowFriday; return false;
}
double Bid(){return SymbolInfoDouble(Sym,SYMBOL_BID);}
double Ask(){return SymbolInfoDouble(Sym,SYMBOL_ASK);}
bool SpreadOK(){ if(MaxSpread_Points<=0) return true; return ((Ask()-Bid())/Pt)<=MaxSpread_Points; }
int ToChartHour(int g){ if(UseChartTimeDirect) return g; int h=(g+ServerGMTOffsetHours)%24; if(h<0) h+=24; return h; }
int VolumeDigitsFromStep(double step){ if(step<=0.0) return 2; int d=0; while(step<1.0 && d<8){ step*=10.0; d++; } return d; }
double NLots(double lots){
  double vmin=SymbolInfoDouble(Sym,SYMBOL_VOLUME_MIN);
  double vmax=SymbolInfoDouble(Sym,SYMBOL_VOLUME_MAX);
  double vstep=SymbolInfoDouble(Sym,SYMBOL_VOLUME_STEP);
  int vdig=VolumeDigitsFromStep(vstep);
  if(lots<vmin) lots=vmin;
  if(lots>vmax) lots=vmax;
  if(vstep>0) lots=MathFloor(lots/vstep)*vstep;
  return NormalizeDouble(lots,vdig);
}
int CountMyOpenPositions(){
  int cnt=0;
  int total=PositionsTotal();
  int posIdx=0;
  while(posIdx<total){
    if(PositionSelectByIndex(posIdx)){
      if(PositionGetString(POSITION_SYMBOL)==Sym && PositionGetInteger(POSITION_MAGIC)==MagicNumber) cnt++;
    }
    posIdx++;
  }
  return cnt;
}
bool HasMyOpenPosition(){ return CountMyOpenPositions()>0; }

/*** CopyRates helpers (no iTime/iClose/iATR) ***/
bool LastM15Close(double &closeOut, datetime &barTimeOut){
  MqlRates r[]; int copied=CopyRates(Sym,PERIOD_M15,1,1,r); // last closed bar
  if(copied!=1) return false; closeOut=r[0].close; barTimeOut=r[0].time; return true;
}
bool ComputeATRpoints(int period, ENUM_TIMEFRAMES tf, double &atrPts){
  int need=period+1; MqlRates r[]; int got=CopyRates(Sym,tf,0,need,r);
  if(got<need) return false;
  double sumTR=0.0; int idx=1;
  while(idx<got){
    double high=r[idx-1].high;
    double low =r[idx-1].low;
    double prevClose=r[idx].close;
    double tr1=high-low;
    double tr2=MathAbs(high-prevClose);
    double tr3=MathAbs(low -prevClose);
    double tr=MathMax(tr1,MathMax(tr2,tr3));
    sumTR+=tr; idx++;
  }
  double atr=sumTR/period;
  atrPts=atr/Pt; return true;
}

/*** Box ***/
bool BuildBox(datetime now){
  g_boxReady=false; g_boxHigh=0.0; g_boxLow=0.0; g_trigHigh=0.0; g_trigLow=0.0;
  datetime d0=DayStart(now);
  int hs=ToChartHour(RangeStartHourGMT);
  int he=ToChartHour(RangeEndHourGMT);
  MqlDateTime ts; TimeToStruct(d0,ts);
  ts.hour=hs; ts.min=0; ts.sec=0; datetime t1=StructToTime(ts);
  ts.hour=he; ts.min=0; ts.sec=0; datetime t2=StructToTime(ts);
  if(t2<=t1){ Log("Bad window"); return false; }
  MqlRates rr[]; int n=CopyRates(Sym, BoxTF, t1, t2, rr);
  if(n<=0){ Log("CopyRates empty"); return false; }
  double hi=-DBL_MAX, lo=DBL_MAX; int idx=0;
  while(idx<n){
    if(rr[idx].time>=t1 && rr[idx].time<t2){
      if(rr[idx].high>hi) hi=rr[idx].high;
      if(rr[idx].low <lo) lo=rr[idx].low;
    }
    idx++;
  }
  if(hi==-DBL_MAX || lo==DBL_MAX) return false;
  g_boxHigh=hi; g_boxLow=lo;
  g_trigHigh=g_boxHigh+Buffer_Points*Pt;
  g_trigLow =g_boxLow -Buffer_Points*Pt;
  g_boxReady=true;
  if(DrawBoxAndTriggers){
    ObjectDelete(0,OBJ_BOX); ObjectDelete(0,OBJ_H); ObjectDelete(0,OBJ_L); ObjectDelete(0,OBJ_TH); ObjectDelete(0,OBJ_TL);
    ObjectCreate(0,OBJ_BOX,OBJ_RECTANGLE,0,t1,g_boxHigh,t2,g_boxLow);
    ObjectSetInteger(0,OBJ_BOX,OBJPROP_COLOR,BoxColor); ObjectSetInteger(0,OBJ_BOX,OBJPROP_BACK,true);
    ObjectCreate(0,OBJ_H,OBJ_TREND,0,t1,g_boxHigh,t2,g_boxHigh); ObjectSetInteger(0,OBJ_H,OBJPROP_COLOR,BoxColor);
    ObjectCreate(0,OBJ_L,OBJ_TREND,0,t1,g_boxLow,t2,g_boxLow);   ObjectSetInteger(0,OBJ_L,OBJPROP_COLOR,BoxColor);
    ObjectCreate(0,OBJ_TH,OBJ_TREND,0,t1,g_trigHigh,t2,g_trigHigh); ObjectSetInteger(0,OBJ_TH,OBJPROP_COLOR,TriggerColor);
    ObjectCreate(0,OBJ_TL,OBJ_TREND,0,t1,g_trigLow,t2,g_trigLow);   ObjectSetInteger(0,OBJ_TL,OBJPROP_COLOR,TriggerColor);
  }
  return true;
}
bool AfterBoxWindow(datetime now){ int eh=ToChartHour(RangeEndHourGMT); MqlDateTime t; TimeToStruct(now,t); return t.hour>=eh; }
bool BeforeCancel(datetime now){ int ch=ToChartHour(CancelHourGMT); MqlDateTime t; TimeToStruct(now,t); return t.hour<ch; }
bool BreakLong_Tick(){ return g_boxReady && Ask()>g_trigHigh; }
bool BreakShort_Tick(){return g_boxReady && Bid()<g_trigLow; }
bool BreakLong_ClosedBar(){
  if(!g_boxReady) return false; double c; datetime bt; if(!LastM15Close(c,bt)) return false;
  if(bt==g_lastM15bar) return false; g_lastM15bar=bt; return c>g_trigHigh;
}
bool BreakShort_ClosedBar(){
  if(!g_boxReady) return false; double c; datetime bt; if(!LastM15Close(c,bt)) return false;
  if(bt==g_lastM15bar) return false; g_lastM15bar=bt; return c<g_trigLow;
}

/*** Targets ***/
void CalcTargetsPoints(){
  double slp; double tpp;
  if(ExitMode==EXIT_FIXED_POINTS){ slp=SL_Points_Fixed; tpp=TP_Points_Fixed; }
  else{
    double atrPts=0.0;
    bool ok=ComputeATRpoints(ATR_Period, ATR_TF, atrPts);
    if(!ok || atrPts<=0.0){ slp=SL_Points_Fixed; tpp=TP_Points_Fixed; }
    else{
      tpp = MathRound(TP_ATR_Mult*atrPts);
      slp = MathRound(SL_ATR_Mult*atrPts);
      if(tpp<Min_TP_Points) tpp=Min_TP_Points;
      if(tpp>Max_TP_Points) tpp=Max_TP_Points;
      if(slp<Min_SL_Points) slp=Min_SL_Points;
      if(slp>Max_SL_Points) slp=Max_SL_Points;
    }
  }
  if(TP_Mode==TP_EQUAL_SL_DISTANCE) tpp=slp;
  g_targetSL_pts=slp; g_targetTP_pts=tpp;
}
void DrawTP_SL_Guides(){
  ObjectDelete(0,OBJ_TP); ObjectDelete(0,OBJ_SL);
  if(!DrawBoxAndTriggers || g_entry==0 || g_dir==0) return;
  double tp=g_entry+g_targetTP_pts*Pt*g_dir;
  double sl=g_entry-g_targetSL_pts*Pt*g_dir;
  datetime now=TimeTradeServer(); datetime t2=now+PeriodSeconds(PERIOD_D1);
  ObjectCreate(0,OBJ_TP,OBJ_TREND,0,now,tp,t2,tp); ObjectSetInteger(0,OBJ_TP,OBJPROP_COLOR,GuideColor);
  ObjectCreate(0,OBJ_SL,OBJ_TREND,0,now,sl,t2,sl); ObjectSetInteger(0,OBJ_SL,OBJPROP_COLOR,GuideColor);
}

/*** Reset ***/
void ResetDay(){
  g_boxReady=false; g_boxHigh=0.0; g_boxLow=0.0; g_trigHigh=0.0; g_trigLow=0.0;
  g_inPosition=false; g_dir=0; g_entry=0.0;
  g_targetTP_pts=0.0; g_targetSL_pts=0.0; g_trailLevel=0.0; g_lastTrailBar=0;
  g_cycleFlips=0; g_cycleBaseLots=0.0; g_submitting=false; g_lastM15bar=0;
  ObjectDelete(0,OBJ_BOX); ObjectDelete(0,OBJ_H); ObjectDelete(0,OBJ_L); ObjectDelete(0,OBJ_TH); ObjectDelete(0,OBJ_TL);
  ObjectDelete(0,OBJ_TP); ObjectDelete(0,OBJ_SL);
}
bool UpdateInPositionFlag(){ g_inPosition=HasMyOpenPosition(); return g_inPosition; }

/*** Orders ***/
void ComputeSLTP(int dir, double &price, double &sl, double &tp){
  if(dir>0) price=Ask(); else price=Bid();
  sl=price-g_targetSL_pts*Pt*dir;
  tp=price+g_targetTP_pts*Pt*dir;
}
bool SafeSend(int dir, double lots, double price, double sl, double tp, string tag){
  if(g_submitting) return false;
  if(UpdateInPositionFlag()) return false;
  g_submitting=true;
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(20);
  bool ok=false;
  double vol=NLots(lots);
  if(dir>0) ok=trade.Buy(vol,Sym,price,sl,tp,tag);
  else      ok=trade.Sell(vol,Sym,price,sl,tp,tag);
  if(!ok){ g_submitting=false; return false; }
  Sleep(50);
  UpdateInPositionFlag();
  g_submitting=false;
  return true;
}

/*** Martingale flip ***/
double LotsForCurrentStep(){
  double lots=NLots(FixedLots);
  int step=0;
  while(step<g_cycleFlips){ lots*=MartingaleFactor; step++; }
  return lots;
}
bool M15ClosedBeyondOppositeTrigger(int dir){
  double c; datetime bt;
  bool ok=LastM15Close(c,bt);
  if(!ok) return false;
  if(dir>0) return (c<g_trigLow);
  return (c>g_trigHigh);
}
void TryFlipOnSL(){
  if(!g_inPosition || !g_boxReady) return;
  if(!M15ClosedBeyondOppositeTrigger(g_dir)) return;

  int total=PositionsTotal();
  int posIdx=total-1;
  while(posIdx>=0){
    if(PositionSelectByIndex(posIdx)){
      if(PositionGetString(POSITION_SYMBOL)==Sym && PositionGetInteger(POSITION_MAGIC)==MagicNumber){
        ulong tk=(ulong)PositionGetInteger(POSITION_TICKET);
        trade.PositionClose(tk);
      }
    }
    posIdx--;
  }
  UpdateInPositionFlag();
  g_dir=-g_dir;
  g_entry=0.0;

  if(!UseMartingale) return;
  if(g_cycleFlips>=MaxFlipsPerDay) return;

  g_cycleFlips++;
  CalcTargetsPoints();
  double price; double sl; double tp;
  ComputeSLTP(g_dir,price,sl,tp);
  double lots=LotsForCurrentStep();
  if(SafeSend(g_dir,lots,price,sl,tp,"LB Flip")){
    g_entry=price;
    DrawTP_SL_Guides();
  }
}

/*** Trailing ***/
double TrailDistancePoints(){
  if(TrailMode==TRAIL_FIXED) return (double)Trail_Fixed_Distance;
  if(TrailMode==TRAIL_ATR){
    double atrPts=0.0;
    bool ok=ComputeATRpoints(ATR_Period,ATR_TF,atrPts);
    if(ok && atrPts>0.0){
      double d=Trail_ATR_Mult*atrPts;
      if(d<50.0) d=50.0;
      return d;
    }
  }
  return (double)SL_Points_Fixed;
}
void ApplyTrailing(){
  if(TrailMode==TRAIL_OFF || !g_inPosition || g_dir==0) return;

  double price;
  if(g_dir>0) price=Bid(); else price=Ask();
  double profitPts;
  if(g_dir>0) profitPts=(price-g_entry)/Pt; else profitPts=(g_entry-price)/Pt;
  if(profitPts<TrailStart_Points) return;

  if(TrailOnlyOnBarClose){
    MqlRates r[]; int c=CopyRates(Sym,PERIOD_M15,0,1,r);
    if(c!=1) return;
    if(r[0].time==g_lastTrailBar) return;
    g_lastTrailBar=r[0].time;
  }

  double distPts=TrailDistancePoints();
  double wantSL=price - distPts*Pt*g_dir;

  if(g_trailLevel==0.0 || (g_dir>0 && wantSL>g_trailLevel) || (g_dir<0 && wantSL<g_trailLevel)){
    g_trailLevel=wantSL;

    int total=PositionsTotal();
    int posIdx=0;
    while(posIdx<total){
      if(PositionSelectByIndex(posIdx)){
        if(PositionGetString(POSITION_SYMBOL)==Sym && PositionGetInteger(POSITION_MAGIC)==MagicNumber){
          ulong tk=(ulong)PositionGetInteger(POSITION_TICKET);
          double curTP=PositionGetDouble(POSITION_TP);
          double curSL=PositionGetDouble(POSITION_SL);
          bool betterLong=(g_dir>0 && (curSL==0.0 || g_trailLevel>curSL));
          bool betterShort=(g_dir<0 && (curSL==0.0 || g_trailLevel<curSL));
          if(betterLong || betterShort) trade.PositionModify(tk,g_trailLevel,curTP);
        }
      }
      posIdx++;
    }

    if(DrawBoxAndTriggers){
      ObjectDelete(0,OBJ_SL);
      datetime now=TimeTradeServer(); datetime t2=now+PeriodSeconds(PERIOD_D1);
      ObjectCreate(0,OBJ_SL,OBJ_TREND,0,now,g_trailLevel,t2,g_trailLevel);
      ObjectSetInteger(0,OBJ_SL,OBJPROP_COLOR,GuideColor);
    }
  }
}

/*** Core ***/
int OnInit(){
  Sym=_Symbol; Pt=SymbolInfoDouble(Sym,SYMBOL_POINT); Dig=(int)SymbolInfoInteger(Sym,SYMBOL_DIGITS);
  trade.SetExpertMagicNumber(MagicNumber);
  ResetDay(); return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){ Comment(""); }

void StartNewCycle(int dir){
  g_cycleFlips=0;
  g_cycleBaseLots=NLots(FixedLots);
  g_dir=dir;
  CalcTargetsPoints();
  double price; double sl; double tp;
  ComputeSLTP(g_dir,price,sl,tp);
  double lots=LotsForCurrentStep();
  if(SafeSend(g_dir,lots,price,sl,tp,"LB Start")){
    g_entry=price; DrawTP_SL_Guides();
  }
}
void HandleOvernightCarryAndNewBox(datetime now){
  if(!g_boxReady) return;
  bool havePos=UpdateInPositionFlag();
  if(!havePos) return;

  int desired=0;
  if(Ask()>g_trigHigh) desired=+1; else if(Bid()<g_trigLow) desired=-1;
  if(desired==0) return;
  if(desired==g_dir) return;

  int total=PositionsTotal();
  int posIdx=total-1;
  while(posIdx>=0){
    if(PositionSelectByIndex(posIdx)){
      if(PositionGetString(POSITION_SYMBOL)==Sym && PositionGetInteger(POSITION_MAGIC)==MagicNumber){
        ulong tk=(ulong)PositionGetInteger(POSITION_TICKET);
        trade.PositionClose(tk);
      }
    }
    posIdx--;
  }
  UpdateInPositionFlag();
  StartNewCycle(desired);
}
bool M15BarChanged(datetime &btOut){
  MqlRates r[]; int c=CopyRates(Sym,PERIOD_M15,0,1,r);
  if(c!=1) return false;
  if(r[0].time==g_lastM15bar) return false;
  g_lastM15bar=r[0].time; btOut=g_lastM15bar; return true;
}
void MaybeEnterInitial(datetime now){
  if(!BeforeCancel(now)) return;
  if(UpdateInPositionFlag()) return;
  if(!SpreadOK()) return;

  bool goLong=false;
  bool goShort=false;

  if(EntryMode==ENTRY_ON_TICK){
    goLong=BreakLong_Tick();
    goShort=BreakShort_Tick();
  }else{
    datetime bt;
    bool changed=M15BarChanged(bt);
    if(changed){
      goLong=BreakLong_ClosedBar();
      if(!goLong) goShort=BreakShort_ClosedBar();
    }
  }
  if(goLong) StartNewCycle(+1);
  else if(goShort) StartNewCycle(-1);
}
void OnTick(){
  datetime now=TimeTradeServer();
  if(!WeekdayOK(now)){ Comment("Weekday blocked"); return; }

  datetime d0=DayStart(now);
  if(d0!=g_day){ g_day=d0; ResetDay(); }

  if(!g_boxReady){
    if(AfterBoxWindow(now)){
      bool ok=BuildBox(now);
      if(!ok){ Comment("Waiting: box"); return; }
      HandleOvernightCarryAndNewBox(now);
    }else{
      Comment("Waiting box window end"); return;
    }
  }

  UpdateInPositionFlag();
  if(!g_inPosition) MaybeEnterInitial(now);

  if(g_inPosition){
    TryFlipOnSL();
    ApplyTrailing();
    if(!HasMyOpenPosition()){
      g_inPosition=false; g_dir=0; g_entry=0.0; g_trailLevel=0.0;
      ObjectDelete(0,OBJ_TP); ObjectDelete(0,OBJ_SL);
    }
  }

  string s="LB Box:"+(g_boxReady?"READY":"-")+"  H:"+DoubleToString(g_boxHigh,Dig)+"  L:"+DoubleToString(g_boxLow,Dig)+"\n";
  s+="TrigH:"+DoubleToString(g_trigHigh,Dig)+"  TrigL:"+DoubleToString(g_trigLow,Dig)+"  SpreadOK:"+(SpreadOK()?"YES":"NO")+"\n";
  s+="Pos:"+(g_inPosition?(g_dir>0?"LONG":"SHORT"):"FLAT")+"  Flips:"+IntegerToString(g_cycleFlips)+"/"+IntegerToString(MaxFlipsPerDay);
  s+="  Lots:"+DoubleToString(LotsForCurrentStep(),2)+"  TP_pts:"+IntegerToString((int)g_targetTP_pts)+"  SL_pts:"+IntegerToString((int)g_targetSL_pts);
  s+="  Trail:"+(TrailMode==TRAIL_OFF?"OFF":(g_trailLevel==0.0?"arm":"ON"));
  Comment(s);
}
void OnTradeTransaction(const MqlTradeTransaction& trans,const MqlTradeRequest& request,const MqlTradeResult& result){
  if(request.magic==MagicNumber && request.symbol==Sym){ UpdateInPositionFlag(); }
}
