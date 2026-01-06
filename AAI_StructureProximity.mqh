#ifndef AAI_STRUCTUREPROXIMITY_MQH
#define AAI_STRUCTUREPROXIMITY_MQH


//+------------------------------------------------------------------+
//| >>> T027 Structure Proximity Helpers <<<                         |
//+------------------------------------------------------------------+
// Returns last swing high within lookback using a simple fractal test (leg L on both sides)
double FindRecentSwingHigh(const int lookback, const int L)
{
  if(lookback < 2*L+1) return 0.0;
  const int n = lookback;
  MqlRates rates[]; ArraySetAsSeries(rates,true);
  if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, n, rates) != n) return 0.0; // closed bars only

  for(int i=L; i<n-L; ++i){
    bool ok = true;
    double h = rates[i].high;
    for(int k=1;k<=L && ok;k++){ if(rates[i-k].high >= h || rates[i+k].high >= h) ok=false; }
    if(ok) return h;
  }
  return 0.0;
}

double FindRecentSwingLow(const int lookback, const int L)
{
  if(lookback < 2*L+1) return 0.0;
  const int n = lookback;
  MqlRates rates[]; ArraySetAsSeries(rates,true);
  if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, n, rates) != n) return 0.0; // closed bars only

  for(int i=L; i<n-L; ++i){
    bool ok = true;
    double lo = rates[i].low;
    for(int k=1;k<=L && ok;k++){ if(rates[i-k].low <= lo || rates[i+k].low <= lo) ok=false; }
    if(ok) return lo;
  }
  return 0.0;
}



#endif 
