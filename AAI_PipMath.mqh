#ifndef AAI_PIPMATH_MQH
#define AAI_PIPMATH_MQH

// This file is also in "\MQL5\Experts\AlfredAI\inc\AAI_PipMath.mqh" and in "\MQL5\Experts\AlfredAI\inc\AAI_PipMath.mqh"

// Resolve empty symbol to current chart symbol
inline string AAI_Sym(const string sym = "")
{
   return (sym == "" ? _Symbol : sym);
}

// Price of 1 point for a symbol
inline double AAI_Point(const string sym = "")
{
   const string s = AAI_Sym(sym);

   double pt = 0.0;
   if(SymbolInfoDouble(s, SYMBOL_POINT, pt) && pt > 0.0)
      return pt;

   return _Point; // fallback
}

// Digits for a symbol
inline int AAI_Digits(const string sym = "")
{
   const string s = AAI_Sym(sym);

   long d = 0;
   if(SymbolInfoInteger(s, SYMBOL_DIGITS, d))
      return (int)d;

   return _Digits; // fallback
}

// Price of 1 pip for a symbol (FX-style: 1 pip = 10 points on 5/3-digit symbols)
inline double AAI_Pip(const string sym = "")
{
   const string s = AAI_Sym(sym);

   const double pt = AAI_Point(s);
   const int digits = AAI_Digits(s);

   return ((digits == 3 || digits == 5) ? 10.0 * pt : pt);
}

// Conversions
inline double AAI_PriceFromPips(const double pips, const string sym = "")
{
   const string s = AAI_Sym(sym);
   return pips * AAI_Pip(s);
}

inline double AAI_PipsFromPrice(const double price_dist, const string sym = "")
{
   const string s = AAI_Sym(sym);
   return price_dist / AAI_Pip(s);
}

inline double AAI_PriceFromPoints(const double points, const string sym = "")
{
   const string s = AAI_Sym(sym);
   return points * AAI_Point(s);
}

inline double AAI_PointsFromPrice(const double price_dist, const string sym = "")
{
   const string s = AAI_Sym(sym);
   return price_dist / AAI_Point(s);
}

// Backwards-compatible aliases
inline double PipSize(const string sym = "") { return AAI_Pip(sym); }
inline double PriceFromPips(const double pips, const string sym = "") { return AAI_PriceFromPips(pips, sym); }

#endif // AAI_PIPMATH_MQH
