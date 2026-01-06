#ifndef AAI_IMC_MQH
#define AAI_IMC_MQH

//+------------------------------------------------------------------+
//| >>> T029 Inter-Market Confirmation Helpers <<<                   |
//+------------------------------------------------------------------+
bool IMC_RocBps(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, double &roc_bps_out)
{
  roc_bps_out = 0.0;
  if(sym=="" || lookback < 1) return false;
  if(!SymbolSelect(sym, true)) return false;

  double c_new[1], c_old[1];
  if(CopyClose(sym, tf, 1, 1, c_new) != 1) return false;
  if(CopyClose(sym, tf, 1+lookback, 1, c_old) != 1) return false;
  if(c_old[0] == 0.0) return false;

  double roc = (c_new[0] - c_old[0]) / c_old[0];
  roc_bps_out = roc * 10000.0;
  return true;
}

double IMC_PerConfSupport_ROC(const int our_direction, const string sym, ENUM_TIMEFRAMES tf,
                              ENUM_IMC_Rel rel, int lookback, double minAbsBps)
{
  double roc_bps;
  if(!IMC_RocBps(sym, tf, lookback, roc_bps)) return 0.5; // neutral if unavailable

  if(MathAbs(roc_bps) < MathMax(0.0, minAbsBps)) return 0.5;

  int conf_dir = (roc_bps > 0.0 ? +1 : -1);
  conf_dir = (rel==IMC_CONTRA ? -conf_dir : conf_dir);

  if(conf_dir == our_direction) return 1.0;
  return 0.0; // opposing
}

double IMC_WeightedSupport(const int our_direction)
{
  double wsum = 0.0, accum = 0.0;

  if(InpIMC1_Symbol != "")
  {
    double s1 = IMC_PerConfSupport_ROC(our_direction, InpIMC1_Symbol, InpIMC1_Timeframe,
                                       InpIMC1_Relation, InpIMC1_LookbackBars, InpIMC1_MinAbsRocBps);
    accum += InpIMC1_Weight * s1;
    wsum  += MathMax(0.0, InpIMC1_Weight);
  }

  if(InpIMC2_Symbol != "")
  {
    double s2 = IMC_PerConfSupport_ROC(our_direction, InpIMC2_Symbol, InpIMC2_Timeframe,
                                       InpIMC2_Relation, InpIMC2_LookbackBars, InpIMC2_MinAbsRocBps);
    accum += InpIMC2_Weight * s2;
    wsum  += MathMax(0.0, InpIMC2_Weight);
  }

  if(wsum <= 0.0) return 1.0; // no active confirmers ? fully permissive
  return accum / wsum;
}



#endif 

