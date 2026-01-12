#ifndef AAI_INCLUDE_NEWS_MQH
#define AAI_INCLUDE_NEWS_MQH
#property strict

// -----------------------------------------------------------------------------
// AAI_Include_News.mqh
// Economic-Calendar news gate for AlfredAI.
//
// IMPORTANT:
// - This file is a *library*. It must NOT declare `input` variables.
// - It does NOT require <EconomicCalendar.mqh> (many terminals don't ship it).
// - It uses the built-in Economic Calendar API:
//     CalendarValueHistory(), CalendarEventById()
// - Economic calendar times are in *trade server time*.
//
// The EA expects:
//   - enum ENUM_NEWS_Mode with NEWS_REQUIRED / NEWS_PREFERRED
//   - class AAI_NewsGate with:
//       void Init(bool enable, string csvNameUnused, ENUM_NEWS_Mode mode, bool timesAreUTC,
//                 bool filterHigh, bool filterMedium, bool filterLow, int prefPenalty);
//       bool CheckGate(datetime t, double &conf_io, int &flag_for_bar);
// -----------------------------------------------------------------------------

// Define the mode enum if it isn't defined elsewhere.
#ifndef AAI_ENUM_NEWS_MODE_DEFINED
#define AAI_ENUM_NEWS_MODE_DEFINED
enum ENUM_NEWS_Mode
{
   NEWS_REQUIRED  = 0,  // hard block
   NEWS_PREFERRED = 1   // allow but reduce confidence
};
#endif

// Some terminals define these already; keep safe fallbacks.
#ifndef CALENDAR_IMPORTANCE_LOW
   #define CALENDAR_IMPORTANCE_LOW       0
#endif
#ifndef CALENDAR_IMPORTANCE_MODERATE
   #define CALENDAR_IMPORTANCE_MODERATE  1
#endif
#ifndef CALENDAR_IMPORTANCE_HIGH
   #define CALENDAR_IMPORTANCE_HIGH      2
#endif

class AAI_NewsGate
{
private:
   bool           m_enabled;
   ENUM_NEWS_Mode m_mode;
   bool           m_input_is_utc;
   bool           m_f_high;
   bool           m_f_med;
   bool           m_f_low;
   int            m_pref_penalty;

   // window (minutes). Keep defaults here; you can later expose as EA inputs if desired.
   int            m_pre_min;
   int            m_post_min;

   // lightweight cache (per symbol + bar-time passed to CheckGate)
   datetime       m_cache_t;
   string         m_cache_sym;
   bool           m_cache_has_hit;
   bool           m_cache_blocks;
   string         m_cache_note;

   string         m_last_reason;

private:
   static int ClampInt(const int v, const int lo, const int hi)
   {
      if(v < lo) return lo;
      if(v > hi) return hi;
      return v;
   }

   static bool GetSymbolCurrencies(const string sym, string &c1, string &c2)
   {
      c1 = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      c2 = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      return (c1 != "" && c2 != "");
   }

   bool ImpactSelected(const int importance) const
   {
      if(importance == CALENDAR_IMPORTANCE_HIGH)     return m_f_high;
      if(importance == CALENDAR_IMPORTANCE_MODERATE) return m_f_med;
      if(importance == CALENDAR_IMPORTANCE_LOW)      return m_f_low;
      return false;
   }

   static datetime UTCToServer(const datetime t_utc)
   {
      // Approximate using current server offset to GMT.
      const datetime srv = TimeTradeServer();
      const datetime gmt = TimeGMT();
      const int offset_sec = (int)(srv - gmt);
      return (t_utc + offset_sec);
   }

   void ResetCache()
   {
      m_cache_t       = 0;
      m_cache_sym     = "";
      m_cache_has_hit = false;
      m_cache_blocks  = false;
      m_cache_note    = "";
   }

   bool ScanCurrencyWindow(const string currency,
                           const datetime from_ts,
                           const datetime to_ts,
                           string &note_out) const
   {
      MqlCalendarValue vals[];
      ResetLastError();

      // Filter by currency directly (more efficient + avoids manual currency checks)
      const int n = CalendarValueHistory(vals, from_ts, to_ts, NULL, currency);
      if(n <= 0)
         return false;

      for(int i = 0; i < n; ++i)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;

         if(!ImpactSelected((int)ev.importance))
            continue;

         // vals[i].time is in trade server time
         const datetime et = vals[i].time;
         if(et < from_ts || et > to_ts)
            continue;

MqlCalendarCountry cn;
if(!CalendarCountryById(ev.country_id, cn))
   continue;

string cur = cn.currency;
StringToUpper(cur);

         note_out = StringFormat("news %s: %s imp=%d at %s",
                                 cur, ev.name, (int)ev.importance,
                                 TimeToString(et, TIME_DATE|TIME_MINUTES));
         return true;
      }

      return false;
   }

public:
   AAI_NewsGate()
   {
      m_enabled       = false;
      m_mode          = NEWS_PREFERRED;
      m_input_is_utc  = false;

      m_f_high        = true;
      m_f_med         = true;
      m_f_low         = false;

      m_pref_penalty  = 5;

      m_pre_min       = 30;
      m_post_min      = 30;

      m_last_reason   = "";
      ResetCache();
   }

   // EA-compatible signature (csvName is ignored for Economic Calendar mode)
   void Init(const bool enable,
             const string /*csvNameUnused*/,
             const ENUM_NEWS_Mode mode,
             const bool timesAreUTC,
             const bool filterHigh,
             const bool filterMedium,
             const bool filterLow,
             const int prefPenalty)
   {
      m_enabled      = enable;
      m_mode         = mode;
      m_input_is_utc = timesAreUTC;

      m_f_high       = filterHigh;
      m_f_med        = filterMedium;
      m_f_low        = filterLow;

      m_pref_penalty = (prefPenalty < 0 ? 0 : prefPenalty);

      m_last_reason  = "";
      ResetCache();
   }

   // Optional: let you change windows later without touching the EA inputs
   void SetWindowMinutes(const int pre_minutes, const int post_minutes)
   {
      m_pre_min  = ClampInt(pre_minutes,  0, 240);
      m_post_min = ClampInt(post_minutes, 0, 240);
      ResetCache();
   }

   string LastReason() const { return m_last_reason; }

   // Returns false if blocked (NEWS_REQUIRED hit). In preferred mode, reduces conf_io.
   bool CheckGate(const datetime t_in,
                  double &conf_io,
                  int &flag_for_bar)
   {
      m_last_reason = "";

      if(!m_enabled)
         return true;

      const string sym = _Symbol;

      // normalize to server time if caller claims UTC
      datetime t_server = t_in;
      if(m_input_is_utc)
         t_server = UTCToServer(t_in);

      // cache: same symbol + same input time => same result
      if(m_cache_t == t_server && m_cache_sym == sym)
      {
         if(m_cache_has_hit)
         {
            flag_for_bar = 1;
            m_last_reason = m_cache_note;

            if(m_mode == NEWS_REQUIRED && m_cache_blocks)
               return false;

            if(m_mode == NEWS_PREFERRED)
               conf_io = MathMax(0.0, conf_io - (double)m_pref_penalty);
         }
         return true;
      }

      // reset cache key
      m_cache_t   = t_server;
      m_cache_sym = sym;
      m_cache_has_hit = false;
      m_cache_blocks  = false;
      m_cache_note    = "";

      // build time window (server time)
      const datetime from_ts = t_server - (m_pre_min  * 60);
      const datetime to_ts   = t_server + (m_post_min * 60);

      string c1, c2;
      if(!GetSymbolCurrencies(sym, c1, c2))
      {
         // Non-FX symbols: fail-open
         return true;
      }
      StringToUpper(c1);
      StringToUpper(c2);

      string note = "";
      bool hit = false;

      if(ScanCurrencyWindow(c1, from_ts, to_ts, note))
         hit = true;
      else if(c2 != c1 && ScanCurrencyWindow(c2, from_ts, to_ts, note))
         hit = true;

      if(!hit)
      {
         // no news in window
         return true;
      }

      // news window active
      flag_for_bar = 1;
      m_last_reason = note;

      m_cache_has_hit = true;
      m_cache_note    = note;

      if(m_mode == NEWS_REQUIRED)
      {
         m_cache_blocks = true;
         return false;
      }

      // preferred: allow, penalize confidence
      m_cache_blocks = false;
      conf_io = MathMax(0.0, conf_io - (double)m_pref_penalty);
      return true;
   }
};

#endif // AAI_INCLUDE_NEWS_MQH
