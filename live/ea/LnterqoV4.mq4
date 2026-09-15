//+------------------------------------------------------------------+
//|  LnterqoV4.mq4  —  lnterqo v4 Auto-Trader (FIXED)                |
//|  Reads signals from Python engine via CSV bridge file.           |
//|  Exports live bar data back to Python for signal generation.     |
//+------------------------------------------------------------------+
#property copyright "lnterqo v4 — SMM591"
#property strict

//── Inputs ──────────────────────────────────────────────────────────
input string   InpSymbol        = "Gold";      // Symbol (match Market Watch)
input int      InpMagicNumber   = 20260001;    // Unique EA identifier
input int      InpExportBars    = 2000;        // 5m bars to export
input int      InpTimerSec      = 60;          // Export/check interval (sec)
input bool     InpLiveTrading   = false;       // SAFETY: must set true to trade
input double   InpMaxLotSize    = 1.0;         // Hard lot cap
input int      InpSlippage      = 3;           // Max slippage (points)

//── Bridge file names (in MT4 Common/Files folder) ──────────────────
string FILE_SIGNALS = "lnterqo_signals.csv";
string FILE_TRADES  = "lnterqo_trades.csv";
string FILE_5M      = "gold_5m_live.csv";
string FILE_D1      = "gold_d1_live.csv";
string FILE_STATUS  = "lnterqo_status.csv";

//── State ────────────────────────────────────────────────────────────
int    g_lastSignalId   = 0;
int    g_ticket         = 0;
string g_lastExportTime = "";

//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsDllsAllowed())
   {
      Alert("LnterqoV4: Enable DLL imports in Tools → Options → Expert Advisors");
      return INIT_FAILED;
   }
   EventSetTimer(InpTimerSec);
   Print("LnterqoV4 initialised. Symbol=", InpSymbol, " LiveTrading=", InpLiveTrading);
   ExportBars();
   WriteStatus("INIT");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   WriteStatus("STOPPED");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   ExportBars();
   CheckAndExecuteSignal();
   ManageOpenPosition();
   WriteStatus("RUNNING");
}

void OnTick()
{
   ManageOpenPosition();
}

//+------------------------------------------------------------------+
//  Export last N bars of 5m and D1 to CSV files Python can read.
//+------------------------------------------------------------------+
void ExportBars()
{
   string dt = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
   if(dt == g_lastExportTime) return;
   g_lastExportTime = dt;

   // ── 5m bars ──────────────────────────────────────────────────────
   int fh = FileOpen(FILE_5M, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) { Print("ERROR: Cannot open ", FILE_5M); return; }
   FileWrite(fh, "time,open,high,low,close,volume");
   int bars = MathMin(InpExportBars, iBars(InpSymbol, PERIOD_M5));
   for(int i = bars - 1; i >= 0; i--)
   {
      datetime t  = iTime(InpSymbol,  PERIOD_M5, i);
      double   op = iOpen(InpSymbol,  PERIOD_M5, i);
      double   hi = iHigh(InpSymbol,  PERIOD_M5, i);
      double   lo = iLow(InpSymbol,   PERIOD_M5, i);
      double   cl = iClose(InpSymbol, PERIOD_M5, i);
      long     vo = iVolume(InpSymbol,PERIOD_M5, i);
      FileWrite(fh, TimeToString(t, TIME_DATE|TIME_SECONDS), op, hi, lo, cl, vo);
   }
   FileClose(fh);

   // ── D1 bars ──────────────────────────────────────────────────────
   fh = FileOpen(FILE_D1, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) { Print("ERROR: Cannot open ", FILE_D1); return; }
   FileWrite(fh, "time,open,high,low,close,volume");
   int d1bars = MathMin(500, iBars(InpSymbol, PERIOD_D1));
   for(int i = d1bars - 1; i >= 0; i--)
   {
      datetime t  = iTime(InpSymbol,  PERIOD_D1, i);
      double   op = iOpen(InpSymbol,  PERIOD_D1, i);
      double   hi = iHigh(InpSymbol,  PERIOD_D1, i);
      double   lo = iLow(InpSymbol,   PERIOD_D1, i);
      double   cl = iClose(InpSymbol, PERIOD_D1, i);
      long     vo = iVolume(InpSymbol,PERIOD_D1, i);
      FileWrite(fh, TimeToString(t, TIME_DATE|TIME_SECONDS), op, hi, lo, cl, vo);
   }
   FileClose(fh);
}

//+------------------------------------------------------------------+
//  Read latest unexecuted signal from Python and place order.
//+------------------------------------------------------------------+
void CheckAndExecuteSignal()
{
   if(!FileIsExist(FILE_SIGNALS, FILE_COMMON)) 
   {
      Print("Signal file not found: ", FILE_SIGNALS);
      return;
   }

   int fh = FileOpen(FILE_SIGNALS, FILE_READ|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) 
   { 
      Print("ERROR: Cannot open signal file ", FILE_SIGNALS);
      return;
   }

   // ── Read all lines and find the last unprocessed signal ──────
   string lastLine = "";
   int lineCount = 0;
   
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      lineCount++;
      
      // Skip header (line 1)
      if(lineCount == 1) 
      {
         Print("Signal CSV header: ", line);
         continue;
      }
      
      // Store non-empty lines
      if(StringLen(line) > 5)
      {
         lastLine = line;
         Print("Read signal line ", lineCount, ": ", line);
      }
   }
   FileClose(fh);

   if(StringLen(lastLine) < 5) 
   {
      Print("No valid signal line found in CSV");
      return;
   }

   // ── Parse CSV: id,timestamp,direction,entry,stop,target,confidence,zone_type,status ──
   string parts[];
   int n = StringSplit(lastLine, ',', parts);
   
   if(n < 9) 
   {
      Print("ERROR: Signal line has ", n, " fields, expected 9. Line: ", lastLine);
      return;
   }

   // Parse fields with validation
   int    sigId      = MyStrToInt(parts[0]);
   string timestamp  = parts[1];
   string direction  = StringToLower(parts[2]);
   double entry      = MyStrToDouble(parts[3]);
   double stop       = MyStrToDouble(parts[4]);
   double target     = MyStrToDouble(parts[5]);
   int    confidence = MyStrToInt(parts[6]);
   string zone       = parts[7];
   string status     = parts[8];

   // Validate parsed values
   if(sigId <= 0 || entry <= 0 || stop <= 0 || target <= 0)
   {
      Print("ERROR: Invalid signal values. ID=", sigId, " Entry=", entry, 
            " Stop=", stop, " Target=", target);
      return;
   }

   if(direction != "long" && direction != "short")
   {
      Print("ERROR: Invalid direction=", direction, ". Expected 'long' or 'short'");
      return;
   }

   // ── Execution logic ──────────────────────────────────────────────
   // 1. Skip if we've already processed this signal
   if(sigId <= g_lastSignalId) 
   {
      Print("Signal ", sigId, " already processed (last=", g_lastSignalId, ")");
      return;
   }

   // 2. Skip if not NEW status
   if(status != "NEW") 
   {
      Print("Signal ", sigId, " status=", status, " (skipping, not NEW)");
      return;
   }

   // 3. Skip if we already have an open position
   if(g_ticket > 0)
   {
      if(OrderSelect(g_ticket, SELECT_BY_TICKET))
      {
         if(OrderCloseTime() == 0) 
         {
            Print("Position already open (ticket=", g_ticket, "). Waiting for close.");
            return;
         }
      }
   }

   g_lastSignalId = sigId;

   // ── Calculate lot size (risk-based) ──────────────────────────────
   double riskPct  = (confidence >= 4) ? 0.01 : 0.005;
   double equity   = AccountEquity();
   double riskAmt  = equity * riskPct;
   double riskPts  = MathAbs(entry - stop);
   double tickVal  = MarketInfo(InpSymbol, MODE_TICKVALUE);
   double tickSz   = MarketInfo(InpSymbol, MODE_TICKSIZE);
   double minLot   = MarketInfo(InpSymbol, MODE_MINLOT);
   double lots     = 0;

   if(riskPts <= 0 || tickVal <= 0 || tickSz <= 0 || minLot <= 0)
   {
      Print("ERROR: Invalid market data. Risk=", riskPts, " TickVal=", tickVal, 
            " TickSize=", tickSz, " MinLot=", minLot);
      return;
   }

   lots = riskAmt / (riskPts / tickSz * tickVal);
   lots = NormalizeDouble(MathMin(lots, InpMaxLotSize), 2);
   lots = MathMax(lots, minLot);

   if(lots <= 0) 
   { 
      Print("ERROR: Invalid lot size=", lots, ". Signal ", sigId, " skipped");
      return; 
   }

   // ── Place order or paper-trade ────────────────────────────────────
   if(!InpLiveTrading)
   {
      Print("═══ PAPER TRADE ═══");
      Print("Signal ID:  ", sigId);
      Print("Direction:  ", direction);
      Print("Entry:      ", entry);
      Print("Stop Loss:  ", stop);
      Print("Take Profit:", target);
      Print("Lots:       ", lots);
      Print("Confidence: ", confidence);
      Print("Zone:       ", zone);
      Print("Timestamp:  ", timestamp);
      Print("══════════════════");
      
      AppendTradeResult(sigId, 0, entry, lots, "PAPER");
      return;
   }

   // ── LIVE TRADING ─────────────────────────────────────────────────
   int cmd = (direction == "long") ? OP_BUY : OP_SELL;
   double price = (cmd == OP_BUY) ? Ask : Bid;
   color  clr   = (cmd == OP_BUY) ? clrBlue : clrRed;

   Print("═══ PLACING LIVE ORDER ═══");
   Print("Signal ID:  ", sigId);
   Print("Command:    ", (cmd == OP_BUY ? "BUY" : "SELL"));
   Print("Entry Price:", price);
   Print("Lots:       ", lots);
   Print("Stop Loss:  ", stop);
   Print("Take Profit:", target);
   Print("═════════════════════════");

   int ticket = OrderSend(
      InpSymbol, cmd, lots, price, InpSlippage,
      stop, target,
      "LnterqoV4 sig#" + IntegerToString(sigId),
      InpMagicNumber, 0, clr
   );

   if(ticket > 0)
   {
      g_ticket = ticket;
      Print("✓ Order PLACED successfully!");
      Print("  Ticket: ", ticket);
      Print("  Signal: ", sigId);
      Print("  Lots:   ", lots);
      AppendTradeResult(sigId, ticket, price, lots, "OPEN");
   }
   else
   {
      int err = GetLastError();
      Print("✗ OrderSend FAILED!");
      Print("  Error Code: ", err);
      Print("  Error Desc: ", ErrorDescription(err));
      Print("  Signal ID:  ", sigId);
      AppendTradeResult(sigId, -1, price, lots, "ERROR_" + IntegerToString(err));
   }
}

//+------------------------------------------------------------------+
//  Monitor open position — write result when it closes.
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(g_ticket <= 0) return;
   if(!OrderSelect(g_ticket, SELECT_BY_TICKET)) return;
   if(OrderCloseTime() == 0) return; // still open

   string outcome = (OrderProfit() >= 0) ? "WIN" : "LOSS";
   double rMult = 0;
   double risk  = MathAbs(OrderOpenPrice() - OrderStopLoss());
   if(risk > 0)
      rMult = OrderProfit() / (risk / MarketInfo(InpSymbol, MODE_TICKSIZE) *
              MarketInfo(InpSymbol, MODE_TICKVALUE) * OrderLots());
   rMult = NormalizeDouble(rMult, 2);

   Print("═════════════════════════");
   Print("✓ Trade CLOSED!");
   Print("  Ticket:    ", g_ticket);
   Print("  Outcome:   ", outcome);
   Print("  R-Multiple:", rMult);
   Print("  PnL:       ", OrderProfit());
   Print("═════════════════════════");
   
   UpdateTradeResult(g_ticket, outcome, OrderClosePrice(), OrderProfit(), rMult);
   g_ticket = 0;
}

//+------------------------------------------------------------------+
//  Helper: Convert string to integer (safe)
//+------------------------------------------------------------------+
int MyStrToInt(string s)
{
   s = MyStringTrim(s);
   if(StringLen(s) == 0) return 0;
   return (int)StringToInteger(s);
}

//+------------------------------------------------------------------+
//  Helper: Convert string to double (safe)
//+------------------------------------------------------------------+
double MyStrToDouble(string s)
{
   s = MyStringTrim(s);
   if(StringLen(s) == 0) return 0.0;
   return StringToDouble(s);
}

//+------------------------------------------------------------------+
//  Helper: Trim whitespace
//+------------------------------------------------------------------+
string MyStringTrim(string s)
{
   string result = s;
   int len = StringLen(result);
   int start = 0, end = len - 1;
   
   while(start < len && (result[start] == ' ' || result[start] == '\t' || result[start] == '\r')) 
      start++;
   
   while(end >= start && (result[end] == ' ' || result[end] == '\t' || result[end] == '\n' || result[end] == '\r')) 
      end--;
   
   if(start > end) return "";
   return StringSubstr(result, start, end - start + 1);
}

//+------------------------------------------------------------------+
//  Helper: Get error description
//+------------------------------------------------------------------+
string ErrorDescription(int error)
{
   switch(error)
   {
      case 0:   return "No error";
      case 1:   return "No error returned, but the result is unknown";
      case 2:   return "Common error";
      case 3:   return "Invalid trade parameters";
      case 4:   return "Server is busy";
      case 5:   return "Old version of the client terminal";
      case 6:   return "No connection with trade server";
      case 7:   return "Not enough rights";
      case 8:   return "Too frequent requests";
      case 9:   return "Malfunctional trade operation";
      case 64:  return "Account disabled";
      case 65:  return "Invalid account";
      case 128: return "Trade timeout";
      case 129: return "Invalid price";
      case 130: return "Invalid stops";
      case 131: return "Invalid trade volume";
      case 132: return "Market is closed";
      case 133: return "Trade is disabled";
      case 134: return "Not enough money";
      case 135: return "Price changed";
      case 136: return "Off quotes";
      case 137: return "Broker is busy";
      case 138: return "Requote";
      case 139: return "Order is locked";
      case 140: return "Long positions only allowed";
      case 141: return "Too many requests";
      case 145: return "Modification denied because order is too close to market";
      case 146: return "Trade context is busy";
      case 147: return "Excessively high slippage";
      case 148: return "Unsupported trade operation";
      case 149: return "Invalid stops distance";
      case 150: return "Invalid trade filling type";
      case 151: return "Invalid expiration time";
      case 152: return "Order is expired";
      case 153: return "Order status did not change";
      case 154: return "System busy";
      case 155: return "Function is not allowed in testing mode";
      case 156: return "Function is not confirmed";
      case 157: return "Send request is not confirmed";
      case 158: return "Mailbox is full";
      case 159: return "API call timeout";
      case 4000: return "No error (returned value 4000)";
      case 4001: return "Wrong function pointer";
      case 4002: return "Array index is out of range";
      case 4003: return "No memory for function call stack";
      case 4004: return "Structure copying error";
      case 4005: return "Stack overflow";
      case 4006: return "Float as function parameter";
      case 4007: return "Array as function parameter";
      case 4009: return "Uninitialized local variable";
      case 4010: return "Local variable is of complex type";
      case 4011: return "Mutual recursion functions";
      case 4012: return "Array parameter expected";
      case 4013: return "Incorrect function type";
      case 4014: return "Code is too long";
      case 4015: return "Compile error";
      case 4016: return "Execution suspended";
      case 4017: return "Incorrect use of API";
      case 4018: return "Old MQL4 call syntax used";
      case 4019: return "Brackets mismatch";
      case 4020: return "Brackets matching failed";
      case 4021: return "Incorrect number of function parameters";
      case 4022: return "Invalid function parameter type";
      case 4023: return "Invalid array size";
      case 4024: return "No memory for variable allocation";
      case 4025: return "No memory allocated";
      case 4026: return "Null pointer was passed as array reference";
      case 4027: return "Array copying error";
      case 4028: return "Assertion failed";
      case 4029: return "Resource not found";
      case 4030: return "Resource busy";
      case 4031: return "Invalid parameter for resource operation";
      case 4032: return "Terminal not ready";
      case 4033: return "Terminal quitting";
      case 4034: return "Invalid account name";
      case 4035: return "Wrong record index";
      case 4036: return "Wrong passwords";
      case 4037: return "Wrong record";
      case 4038: return "Wrong result";
      case 4039: return "Invalid trade parameters";
      case 4040: return "Server connection failed";
      case 4041: return "Wrong URL";
      case 4042: return "Wrong XML";
      case 4043: return "Wrong request";
      case 4044: return "Uptime not available";
      case 4045: return "Wrong operation";
      case 4046: return "Confirmation failed";
      case 4047: return "Timeout";
      case 4048: return "Invalid file path";
      case 4049: return "File API is disabled";
      case 4050: return "Structures are incompatible";
      case 4051: return "Invalid field in structure";
      case 4052: return "Integer parameter expected";
      case 4053: return "Double parameter expected";
      case 4054: return "String parameter expected";
      case 4055: return "Struct expected";
      case 4056: return "Trade operation is not allowed";
      case 4057: return "Too many simultaneous requests";
      default:  return "Unknown error: " + IntegerToString(error);
   }
}

//+------------------------------------------------------------------+
//  Append new row to trades CSV (MQL4 compatible)
//  Reads existing file, adds new line, rewrites entire file.
//+------------------------------------------------------------------+
void AppendTradeResult(int sigId, int ticket, double price, double lots, string status)
{
   string allLines[];
   int lineCount = 0;
   
   // ── Read existing file if it exists ─────────────────────────────
   if(FileIsExist(FILE_TRADES, FILE_COMMON))
   {
      int fh = FileOpen(FILE_TRADES, FILE_READ|FILE_CSV|FILE_COMMON, ',');
      if(fh != INVALID_HANDLE)
      {
         while(!FileIsEnding(fh))
         {
            string line = FileReadString(fh);
            if(StringLen(line) > 0)
            {
               ArrayResize(allLines, lineCount + 1);
               allLines[lineCount] = line;
               lineCount++;
            }
         }
         FileClose(fh);
      }
   }
   
   // ── Create/rewrite file with all lines + new entry ─────────────
   int fh = FileOpen(FILE_TRADES, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) 
   { 
      Print("ERROR: Cannot create trades file ", FILE_TRADES);
      return;
   }
   
   // Write header if file was empty
   if(lineCount == 0)
   {
      FileWrite(fh, "signal_id,ticket,entry_price,lots,status,close_price,pnl,r_multiple,timestamp");
   }
   else
   {
      // Rewrite all existing lines
      for(int i = 0; i < lineCount; i++)
      {
         FileWrite(fh, allLines[i]);
      }
   }
   
   // Write new entry
   FileWrite(fh, sigId, ticket, price, lots, status, 0, 0, 0,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   
   FileClose(fh);
   Print("✓ Trade result appended: SigID=", sigId, " Ticket=", ticket, " Status=", status);
}

//+------------------------------------------------------------------+
//  Update existing trade result when position closes.
//+------------------------------------------------------------------+
void UpdateTradeResult(int ticket, string outcome, double closePrice, double pnl, double rMult)
{
   string allLines[];
   int lineCount = 0;
   
   // ── Read existing file ──────────────────────────────────────────
   if(!FileIsExist(FILE_TRADES, FILE_COMMON)) return;
   
   int fh = FileOpen(FILE_TRADES, FILE_READ|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) return;
   
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      if(StringLen(line) > 0)
      {
         ArrayResize(allLines, lineCount + 1);
         allLines[lineCount] = line;
         lineCount++;
      }
   }
   FileClose(fh);
   
   // ── Rewrite file with update ────────────────────────────────────
   fh = FileOpen(FILE_TRADES, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) return;
   
   // Write all existing lines
   for(int i = 0; i < lineCount; i++)
   {
      FileWrite(fh, allLines[i]);
   }
   
   // Append close update (Python script will merge on ticket)
   FileWrite(fh, 0, ticket, 0, 0, outcome, closePrice, pnl, rMult,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   
   FileClose(fh);
   Print("✓ Trade update written: Ticket=", ticket, " Outcome=", outcome, " PnL=", pnl);
}

//+------------------------------------------------------------------+
//  Write status heartbeat
//+------------------------------------------------------------------+
void WriteStatus(string state)
{
   int fh = FileOpen(FILE_STATUS, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) return;
   
   FileWrite(fh, "state,symbol,equity,spread,timestamp");
   double spread = MarketInfo(InpSymbol, MODE_SPREAD) * MarketInfo(InpSymbol, MODE_POINT);
   FileWrite(fh, state, InpSymbol, AccountEquity(), spread,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   FileClose(fh);
}
//+------------------------------------------------------------------+
