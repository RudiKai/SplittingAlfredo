
#ifndef AAI_SESSIONTIME_MQH
#define AAI_SESSIONTIME_MQH
////////////
//++++   Helper for AAI_ClearSessionWindows below
///////////
void AAI_ClearSessionWindows(CArrayObj &windows)
{
   for(int i = windows.Total() - 1; i >= 0; --i)
   {
      SessionTimeWindow *win = (SessionTimeWindow*)windows.At(i);
      delete win;
   }
   windows.Clear();  
}


//+------------------------------------------------------------------+
//| >>> NEW: Session/Time Helper Functions (with minute precision) <<< |
//+------------------------------------------------------------------+
// Helper struct to store a time-of-day window in seconds
// --- FIX: Must be a class inheriting from CObject to use with CArrayObj ---
class SessionTimeWindow : public CObject
{
public:
   int day_of_week;    // 0=Sun, 1=Mon, ..., 6=Sat. -1 = All Days
   int start_sec;      // Seconds from midnight
   int end_sec;        // Seconds from midnight
   
   // Constructor
   SessionTimeWindow(void) : day_of_week(-1), start_sec(0), end_sec(0) {};
};
// Global list to store all parsed time windows
CArrayObj g_session_windows;


// ---
// NEW Parser: Handles "7-15:25,15:35-21" and "Mon:7-12,Tue:9-17"
// Replaces AAI_ParseHourRanges
// ---
void AAI_ParseSessionRanges(const string ranges, CArrayObj &windows)
{
   AAI_ClearSessionWindows(windows);   // deletes + clears, nothing else

   string parts[];
   int n = StringSplit(ranges, ',', parts);     // Split by comma first

   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      AAI_Trim(p);
      if(StringLen(p) == 0) continue;

      int day = -1; // Default to all days
      string range_str = p;

      // Check for Day prefix (e.g., "Mon:")
      int day_colon = StringFind(p, ":");
      if(day_colon > 0 && day_colon <= 4)
      {
         string day_str = StringSubstr(p, 0, day_colon);
         StringToLower(day_str);
         if(day_str == "sun") day = 0;
         else if(day_str == "mon") day = 1;
         else if(day_str == "tue") day = 2;
         else if(day_str == "wed") day = 3;
         else if(day_str == "thu") day = 4;
         else if(day_str == "fri") day = 5;
         else if(day_str == "sat") day = 6;
         
         if(day != -1)
            range_str = StringSubstr(p, day_colon + 1); // Get text after "Mon:"
      }

      // Parse the time range (e.g., "7-15:25")
      int dash = StringFind(range_str, "-");
      if(dash < 0) continue; // Invalid range, must have a dash

      string s_start = StringSubstr(range_str, 0, dash);
      string s_end   = StringSubstr(range_str, dash + 1);

      // Parse Start Time (HH or HH:MM)
      string h_m_start[];
      int h1=0, m1=0;
      if(StringSplit(s_start, ':', h_m_start) >= 1)
      {
         h1 = (int)StringToInteger(h_m_start[0]);
         if(ArraySize(h_m_start) > 1) m1 = (int)StringToInteger(h_m_start[1]);
      }

      // Parse End Time (HH or HH:MM)
      string h_m_end[];
      int h2=0, m2=0;
      if(StringSplit(s_end, ':', h_m_end) >= 1)
      {
         h2 = (int)StringToInteger(h_m_end[0]);
         if(ArraySize(h_m_end) > 1) m2 = (int)StringToInteger(h_m_end[1]);
      }

      // Create and store the window object
      SessionTimeWindow *win = new SessionTimeWindow;
      win.day_of_week = day;
      win.start_sec   = h1 * 3600 + m1 * 60;
      win.end_sec     = h2 * 3600 + m2 * 60;
      
      windows.Add(win);
   }
}
// Returns true if 'now' is inside any session window.
bool AAI_SessionIsOpen(const datetime now, const CArrayObj &windows)
{
   MqlDateTime lt;
   TimeToStruct(now, lt);

   const int dow       = lt.day_of_week;                     // 0=Sun..6=Sat
   const int sec_today = lt.hour * 3600 + lt.min * 60 + lt.sec;

   const int total = windows.Total();
   for(int i = 0; i < total; ++i)
   {
      SessionTimeWindow *win = (SessionTimeWindow*)windows.At(i);
      if(win == NULL)
         continue;

      // Day filter: -1 = all days, otherwise specific weekday
      if(win.day_of_week != -1 && win.day_of_week != dow)
         continue;

      const int start_sec = win.start_sec;
      const int end_sec   = win.end_sec;

      // Assumes windows do not cross midnight (fine for 7-15:25,15:35-21)
      if(sec_today >= start_sec && sec_today < end_sec)
         return true;
   }
   return false;
}

// Minutes until the end of the *current* session window.
// - If we're not in any window -> -1.
int AAI_MinutesToSessionCutoff(const datetime now, const CArrayObj &windows)
{
   MqlDateTime lt;
   TimeToStruct(now, lt);

   const int dow       = lt.day_of_week;
   const int sec_today = lt.hour * 3600 + lt.min * 60 + lt.sec;

   int  best_delta = INT_MAX;
   bool in_session = false;

   const int total = windows.Total();
   for(int i = 0; i < total; ++i)
   {
      SessionTimeWindow *win = (SessionTimeWindow*)windows.At(i);
      if(win == NULL)
         continue;

      if(win.day_of_week != -1 && win.day_of_week != dow)
         continue;

      const int start_sec = win.start_sec;
      const int end_sec   = win.end_sec;

      if(sec_today >= start_sec && sec_today < end_sec)
      {
         in_session = true;
         int delta = end_sec - sec_today;
         if(delta < best_delta)
            best_delta = delta;
      }
   }

   if(!in_session || best_delta <= 0)
      return -1;

   // ceil(seconds / 60)
   int mins = (best_delta + 59) / 60;
   return mins;
}



int AAI_ConfBandIndex(const double conf)
{
   if(conf < 20.0)  return -1;     // ignore extremely low conf
   if(conf < 30.0)  return 0;      // 20-30
   if(conf < 40.0)  return 1;      // 30-40
   if(conf >= 90.0) return 7;      // 90-100 (last bucket)

   // 40-50 => 2, 50-60 => 3, ..., 80-90 => 6
   return 2 + (int)MathFloor((conf - 40.0) / 10.0);
}

string AAI_ConfBandLabel(const int idx)
{
   switch(idx)
   {
      case 0: return "20_30";
      case 1: return "30_40";
      case 2: return "40_50";
      case 3: return "50_60";
      case 4: return "60_70";
      case 5: return "70_80";
      case 6: return "80_90";
      case 7: return "90_100";
      default: return "NA";
   }
}

// --- Playbook: band-level risk multiplier lookup -----------------
double AAI_ConfBandRiskMultFromIndex(const int idx)
{
   switch(idx)
   {
      case 0: return InpPB_BandRiskMult_20_30;
      case 1: return InpPB_BandRiskMult_30_40;
      case 2: return InpPB_BandRiskMult_40_50;
      case 3: return InpPB_BandRiskMult_50_60;
      case 4: return InpPB_BandRiskMult_60_70;
      case 5: return InpPB_BandRiskMult_70_80;
      case 6: return InpPB_BandRiskMult_80_90;
      case 7: return InpPB_BandRiskMult_90_100;
      default: return 1.0;
   }
}

double AAI_ConfBandRiskMultFromConf(const double conf)
  {
   // Use same band mapping as analytics.
   // AAI_ConfBandIndex(conf) should return -1 for conf<40 if you kept that design.
   const int idx = AAI_ConfBandIndex(conf);

   if(idx < 0)
     {
      // For conf below trade threshold:
      // - If MinConfidence gating is already blocking <40, 1.0 is fine (we'll never get here).
      // - If you want "no risk below 40 even if gated differently", change this to 0.0.
      return 1.0;
     }

   return AAI_ConfBandRiskMultFromIndex(idx);
  }

// ---
// NEW Session Check: Checks day mask AND minute-level time windows
// Replaces AAI_HourDayAutoOK
// ---
bool AAI_IsInsideAutoSession(int &seconds_to_end)
{
   seconds_to_end = 2147483647; // Max int
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   
   // 1) Check Day-of-Week Mask
   bool day_ok = ( (dt.day_of_week==0 && AutoSun) || (dt.day_of_week==1 && AutoMon) || (dt.day_of_week==2 && AutoTue) ||
                   (dt.day_of_week==3 && AutoWed) || (dt.day_of_week==4 && AutoThu) || (dt.day_of_week==5 && AutoFri) ||
                   (dt.day_of_week==6 && AutoSat) );
   
   if(!day_ok) return false;

   // 2) Check Time-of-Day Windows
   long now_secs_of_day = dt.hour * 3600 + dt.min * 60 + dt.sec;
   bool time_ok = false;
   int nearest_end_sec = 2147483647;

   for(int i = 0; i < g_session_windows.Total(); i++)
   {
      SessionTimeWindow *win = (SessionTimeWindow*)g_session_windows.At(i);
      if(!win) continue;
      
      // Check if this window applies to this day
      if(win.day_of_week != -1 && win.day_of_week != dt.day_of_week)
         continue; // This window is for a different day

      // Check normal vs. overnight session
      if (win.start_sec <= win.end_sec) // Normal session (e.g., 07:00 - 15:25)
      {
         if (now_secs_of_day >= win.start_sec && now_secs_of_day < win.end_sec)
         {
            time_ok = true;
            int secs_left = (int)(win.end_sec - now_secs_of_day);
            if(secs_left < nearest_end_sec) nearest_end_sec = secs_left;
         }
      }
      else // Overnight session (e.g., 21:00 - 05:00)
      {
         if (now_secs_of_day >= win.start_sec || now_secs_of_day < win.end_sec)
         {
            time_ok = true;
            int secs_left = 0;
            if (now_secs_of_day >= win.start_sec)
               secs_left = (int)((win.end_sec + 86400) - now_secs_of_day); // Time until tomorrow's end
            else
               secs_left = (int)(win.end_sec - now_secs_of_day); // Time until today's end
            
            if(secs_left < nearest_end_sec) nearest_end_sec = secs_left;
         }
      }
   }
   
   if(time_ok)
      seconds_to_end = nearest_end_sec;

   return time_ok;
}

#endif 
