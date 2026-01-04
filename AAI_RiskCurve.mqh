
#ifndef AAI_RISKCURVE_MQH
#define AAI_RISKCURVE_MQH

//+------------------------------------------------------------------+
//| >>> T032: Confidence-to-Risk Curve Helpers <<<                   |
//+------------------------------------------------------------------+
double LotsFromRiskAndSL(const double risk_pct, const double sl_pts)
{
  // Guard
  if(sl_pts <= 0.0 || risk_pct <= 0.0) return 0.0;

  const double bal       = AccountInfoDouble(ACCOUNT_BALANCE);
  const double risk_money= bal * (risk_pct/100.0);

  const double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

  double point_value = 0.0;
  if(tick_val>0.0 && tick_size>0.0)
    point_value = tick_val * (point / tick_size);
  else
    point_value = tick_val; // fallback; many FX have tick_size==_Point

  if(point_value <= 0.0) return 0.0;

  const double risk_per_lot = sl_pts * point_value;
  if(risk_per_lot <= 0.0) return 0.0;

  double lots = risk_money / risk_per_lot;
// --- TICKET T047: Apply VAPT Hot Profile Lot Size Reduction ---
    if (VR_IsHot() && InpVAPT_HotBps > 0)
    {
        // HotBps is in 1/10000ths of the lot size (e.g., 2000 HotBps = 20% reduction)
        double reduction_factor = 1.0 - (InpVAPT_HotBps / 10000.0);

        // Apply reduction
        lots = lots * reduction_factor;

        // Re-normalize to the broker's step size
// Re-normalize the scaled-down lots to the minimum step (e.g., 0.01)
    lots = NormalizeLots(lots); // Corrected function name
        
        // Optional log for testing:
        // PrintFormat("[VAPT] Hot Profile reduction applied. Lots scaled down to %.2f", lots);
    }
    // --- END VAPT HOT PROFILE CHECK ---
  // Apply lot clamps if set
  if(InpCRC_MinLots > 0.0) lots = MathMax(lots, InpCRC_MinLots);
  if(InpCRC_MaxLots > 0.0) lots = MathMin(lots, InpCRC_MaxLots);

  return NormalizeLots(lots);
}

double CRC_MapConfToRisk(const int conf)
{
  const double c = (double)MathMax(0, MathMin(100, conf));
  const double rmin = MathMax(0.0, InpCRC_MinRiskPct);
  const double rmax = MathMax(rmin, InpCRC_MaxRiskPct);

  if(!InpCRC_Enable || InpCRC_Mode==CRC_OFF)
    return rmax;

  const double t = c/100.0;
  double r = rmin;

  switch(InpCRC_Mode)
  {
    case CRC_LINEAR:
    {
      const double c0 = (double)MathMax(0, MathMin(100, InpCRC_MinConfidence));
      if(c <= c0) r = rmin;
      else{
        const double frac = (c - c0) / (100.0 - c0);
        r = rmin + (rmax - rmin) * MathMax(0.0, MathMin(1.0, frac));
      }
      break;
    }
    case CRC_QUADRATIC:
    {
      const double a = MathMax(0.2, MathMin(2.0, InpCRC_QuadAlpha));
      r = rmin + (rmax - rmin) * MathPow(t, a);
      break;
    }
    case CRC_LOGISTIC:
    {
      const double k   = MathMax(0.01, InpCRC_LogisticSlope);
      const double mid = MathMax(0.0, MathMin(100.0, InpCRC_LogisticMid));
      const double x   = c - mid;
      const double s   = 1.0 / (1.0 + MathExp(-k * x));
      r = rmin + (rmax - rmin) * s;
      break;
    }
    case CRC_PIECEWISE:
    {
      int    C1 = MathMax(0,   MathMin(100, InpCRC_PW_C1));
      int    C2 = MathMax(C1,  MathMin(100, InpCRC_PW_C2));
      int    C3 = MathMax(C2,  MathMin(100, InpCRC_PW_C3));
      double R1 = MathMax(rmin, MathMin(rmax, InpCRC_PW_R1));
      double R2 = MathMax(rmin, MathMin(rmax, InpCRC_PW_R2));
      double R3 = MathMax(rmin, MathMin(rmax, InpCRC_PW_R3));

      if(c <= C1){
        double frac = (C1>0 ? c/(double)C1 : 1.0);
        r = rmin + (R1 - rmin) * frac;
      }else if(c <= C2){
        double frac = (C2>C1 ? (c - C1)/(double)(C2 - C1) : 1.0);
        r = R1 + (R2 - R1) * frac;
      }else if(c <= C3){
        double frac = (C3>C2 ? (c - C2)/(double)(C3 - C2) : 1.0);
        r = R2 + (R3 - R2) * frac;
      }else{
        double frac = (100>C3 ? (c - C3)/(double)(100 - C3) : 1.0);
        r = R3 + (rmax - R3) * frac;
      }
      break;
    }
  }

  if(InpCRC_MaxRiskMoney > 0.0)
  {
    const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    const double risk_money = bal * (r/100.0);
    if(risk_money > InpCRC_MaxRiskMoney)
      r = (InpCRC_MaxRiskMoney / MathMax(1e-9, bal)) * 100.0;
  }
  return r;
}

  #endif



//+------------------------------------------------------------------+
//|                                                AAI_RiskCurve.mqh |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
//+------------------------------------------------------------------+
//| defines                                                          |
//+------------------------------------------------------------------+
// #define MacrosHello   "Hello, world!"
// #define MacrosYear    2010
//+------------------------------------------------------------------+
//| DLL imports                                                      |
//+------------------------------------------------------------------+
// #import "user32.dll"
//   int      SendMessageA(int hWnd,int Msg,int wParam,int lParam);
// #import "my_expert.dll"
//   int      ExpertRecalculate(int wParam,int lParam);
// #import
//+------------------------------------------------------------------+
//| EX5 imports                                                      |
//+------------------------------------------------------------------+
// #import "stdlib.ex5"
//   string ErrorDescription(int error_code);
// #import
//+------------------------------------------------------------------+
