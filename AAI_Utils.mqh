#ifndef AAI_UTILS_MQH
#define AAI_UTILS_MQH

// ===================== AAI UTILS (idempotent) =======================
#ifndef AAI_UTILS_DEFINED
#define AAI_UTILS_DEFINED




// TICKET #2: New defensive read helper
inline bool Read1(int h,int b,int shift,double &out,const string id){
   double v[1]; if(CopyBuffer(h,b,shift,1,v)==1){ out=v[0]; return true; }
   static datetime lastWarn=0; datetime bt=iTime(_Symbol,(ENUM_TIMEFRAMES)SignalTimeframe,shift);
   if(bt!=lastWarn){ PrintFormat("[%s_READFAIL] t=%s",id,TimeToString(bt,TIME_DATE|TIME_SECONDS)); lastWarn=bt; }
   return false;
}

// T043: FNV-1a 32-bit string hasher
inline uint FNV1a32(const string s)
{
   uint h = 2166136261;
   for(int i=0;i<StringLen(s);++i){ h ^= (uchar)s[i]; h *= 16777619; }
   return h;
}

void LogBlockOncePerBar(const string reason_tag, const int reason_code = 0)
{
  datetime curBar = iTime(_Symbol, SignalTimeframe, 0);
  if(curBar == 0) { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_tag); return; }

  if(curBar == g_lastBlockBarTime && reason_tag == g_lastBlockReason && reason_code == g_lastBlockCode)
    return;

  g_lastBlockBarTime = curBar;
  g_lastBlockReason  = reason_tag;
  g_lastBlockCode    = reason_code;

  PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_tag);
}

// Fallback for printing ZE gate nicely
string ZE_GateToStr(int gate)
{
   switch(gate){
      case 0: return "ZE_OFF";
      case 1: return "ZE_PREFERRED";
      case 2: return "ZE_REQUIRED";
   }
   return "ZE_?";
}

// Helper to get short timeframe string (e.g., "M15")
string TFToStringShort(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

// T042: More robust spread helper
int CurrentSpreadPoints()
{
   long spr = 0;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD, spr) && spr > 0) return (int)spr;
   // Fallback for variable spread / during backtest
   double s = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   return (int)MathMax(0, (int)MathRound(s));
}

// --- Timeframe label helpers ---
inline string TfLabel(ENUM_TIMEFRAMES tf) {
   string s = EnumToString(tf);
   // e.g., "PERIOD_M15"
   int p = StringFind(s, "PERIOD_");
   return (p == 0 ? StringSubstr(s, 7) : s);
   // -> "M15"
}

inline string CurrentTfLabel() {
   ENUM_TIMEFRAMES eff = (SignalTimeframe == PERIOD_CURRENT)
                           ?
   (ENUM_TIMEFRAMES)_Period
                           : SignalTimeframe;
   return TfLabel(eff);
}



#endif

#endif // AAI_UTILS_MQH
