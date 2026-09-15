//+------------------------------------------------------------------+
//|  LnterqoV3.mq4  —  lnterqo v3 Auto-Trader                       |
//|  Reads signals from Python engine via CSV bridge file.           |
//|  Exports live bar data back to Python for signal generation.     |
//+------------------------------------------------------------------+
#property copyright "lnterqo v3 — SMM591"
#property strict

//── Inputs ──────────────────────────────────────────────────────────
input string   InpSymbol        = "GOLD";      // Symbol (match Market Watch)
input int      InpMagicNumber   = 20260001;    // Unique EA identifier
input int      InpExportBars    = 2000;        // 5m bars to export
input int      InpTimerSec      = 60;          // Export/check interval (sec)
input bool     InpLiveTrading   = false;       // SAFETY: must set true to trade
input double   InpMaxLotSize    = 1.0;         // Hard lot cap
input int      InpSlippage      = 3;           // Max slippage (points)

//── Break-even inputs ───────────────────────────────────────────────
input bool     InpUseBreakeven  = true;        // Enable break-even move
input double   InpBE_TriggerPct = 50.0;        // % of TP distance to trigger BE
input double   InpBE_OffsetPoints = 0;         // Points locked beyond BE (0 = pure BE)

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
      Alert("LnterqoV3: Enable DLL imports in Tools → Options → Expert Advisors");
      return INIT_FAILED;
   }
   EventSetTimer(InpTimerSec);
   Print("LnterqoV3 initialised. LiveTrading=", InpLiveTrading,
         " BE=", InpUseBreakeven, " trigger=", InpBE_TriggerPct, "%");
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
   if(fh == INVALID_HANDLE) { Print("Cannot open ", FILE_5M); return; }
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
   if(fh == INVALID_HANDLE) { Print("Cannot open ", FILE_D1); return; }
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
   if(!FileIsExist(FILE_SIGNALS, FILE_COMMON)) return;

   int fh = FileOpen(FILE_SIGNALS, FILE_READ|FILE_TXT|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) return;

   // Skip header
   if(!FileIsEnding(fh)) FileReadString(fh);

   string lastLine = "";
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      if(StringLen(line) > 5) lastLine = line;
   }
   FileClose(fh);

   if(StringLen(lastLine) < 5) return;

   // Parse CSV: id,timestamp,direction,entry,stop,target,confidence,zone_type,status,rr,rationale
   string parts[];
   int n = StringSplit(lastLine, ',', parts);
   if(n < 9) return;

   int    sigId     = (int)StringToInteger(parts[0]);
   string direction = parts[2];
   double entry     = StringToDouble(parts[3]);
   double stop      = StringToDouble(parts[4]);
   double target    = StringToDouble(parts[5]);
   int    confidence= (int)StringToInteger(parts[6]);
   string status    = parts[8];

   if(sigId <= g_lastSignalId) return;
   if(status != "NEW") return;
   if(g_ticket > 0 && OrderSelect(g_ticket, SELECT_BY_TICKET) && OrderCloseTime() == 0) return;

   g_lastSignalId = sigId;

   double riskPct  = (confidence >= 4) ? 0.01 : 0.005;
   double equity   = AccountEquity();
   double riskAmt  = equity * riskPct;
   double riskPts  = MathAbs(entry - stop);
   double tickVal  = MarketInfo(InpSymbol, MODE_TICKVALUE);
   double tickSz   = MarketInfo(InpSymbol, MODE_TICKSIZE);
   double lots     = 0;
   if(riskPts > 0 && tickVal > 0 && tickSz > 0)
      lots = riskAmt / (riskPts / tickSz * tickVal);
   lots = NormalizeDouble(MathMin(lots, InpMaxLotSize), 2);
   lots = MathMax(lots, MarketInfo(InpSymbol, MODE_MINLOT));

   if(lots <= 0) { Print("Lot calc error — skipping signal ", sigId); return; }

   if(!InpLiveTrading)
   {
      Print("SIGNAL (paper): id=", sigId, " dir=", direction,
            " entry=", entry, " sl=", stop, " tp=", target,
            " lots=", lots, " conf=", confidence);
      AppendTradeResult(sigId, 0, entry, lots, "PAPER");
      return;
   }

   int cmd = (direction == "long") ? OP_BUY : OP_SELL;
   double price = (cmd == OP_BUY) ? Ask : Bid;
   color  clr   = (cmd == OP_BUY) ? clrBlue : clrRed;

   int ticket = OrderSend(
      InpSymbol, cmd, lots, price, InpSlippage,
      stop, target,
      "LnterqoV3 sig#" + IntegerToString(sigId),
      InpMagicNumber, 0, clr
   );

   if(ticket > 0)
   {
      g_ticket = ticket;
      Print("Order placed: ticket=", ticket, " sig=", sigId, " lots=", lots);
      AppendTradeResult(sigId, ticket, price, lots, "OPEN");
   }
   else
   {
      Print("OrderSend failed: error=", GetLastError(), " sig=", sigId);
      AppendTradeResult(sigId, -1, price, lots, "ERROR_" + IntegerToString(GetLastError()));
   }
}

//+------------------------------------------------------------------+
//  Monitor open position — apply break-even, or write result when closed.
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(g_ticket <= 0) return;
   if(!OrderSelect(g_ticket, SELECT_BY_TICKET)) return;

   if(OrderCloseTime() == 0)
   {
      // Position still open — manage break-even
      ApplyBreakeven();
      return;
   }

   // Position closed — record result
   string outcome = (OrderProfit() >= 0) ? "WIN" : "LOSS";
   double rMult = 0;
   double risk  = MathAbs(OrderOpenPrice() - OrderStopLoss());
   if(risk > 0)
      rMult = OrderProfit() / (risk / MarketInfo(InpSymbol, MODE_TICKSIZE) *
              MarketInfo(InpSymbol, MODE_TICKVALUE) * OrderLots());
   rMult = NormalizeDouble(rMult, 2);

   Print("Trade closed: ticket=", g_ticket, " outcome=", outcome, " R=", rMult);
   UpdateTradeResult(g_ticket, outcome, OrderClosePrice(), OrderProfit(), rMult);
   g_ticket = 0;
}

//+------------------------------------------------------------------+
//  Break-even: when price covers InpBE_TriggerPct% of the entry→TP
//  distance, move SL to entry (+ optional offset points).
//+------------------------------------------------------------------+
void ApplyBreakeven()
{
   if(!InpUseBreakeven) return;

   int type = OrderType();
   if(type != OP_BUY && type != OP_SELL) return;

   double openPrice = OrderOpenPrice();
   double tp        = OrderTakeProfit();
   double sl        = OrderStopLoss();
   if(tp <= 0) return;   // no target → cannot compute % distance

   double point     = MarketInfo(InpSymbol, MODE_POINT);
   double digits    = MarketInfo(InpSymbol, MODE_DIGITS);
   double stopsLvl  = MarketInfo(InpSymbol, MODE_STOPLEVEL) * point;

   double triggerPrice = 0;
   double beSl         = 0;

   if(type == OP_BUY)
   {
      double distToTp = tp - openPrice;
      if(distToTp <= 0) return;

      triggerPrice = openPrice + distToTp * (InpBE_TriggerPct / 100.0);
      beSl         = openPrice + InpBE_OffsetPoints * point;

      // Not yet at trigger
      if(Bid < triggerPrice) return;
      // SL already at/above the desired BE
      if(sl > 0 && sl >= beSl) return;
      // Respect broker minimum stop distance
      if(Bid - beSl < stopsLvl) return;
   }
   else // OP_SELL
   {
      double distToTp = openPrice - tp;
      if(distToTp <= 0) return;

      triggerPrice = openPrice - distToTp * (InpBE_TriggerPct / 100.0);
      beSl         = openPrice - InpBE_OffsetPoints * point;

      if(Ask > triggerPrice) return;
      if(sl > 0 && sl <= beSl) return;
      if(beSl - Ask < stopsLvl) return;
   }

   beSl = NormalizeDouble(beSl, (int)digits);

   bool ok = OrderModify(g_ticket, openPrice, beSl, tp, 0, clrYellow);
   if(ok)
      Print("Break-even applied: ticket=", g_ticket, " newSL=", beSl);
   else
      Print("Break-even modify failed: error=", GetLastError(), " ticket=", g_ticket);
}

//+------------------------------------------------------------------+
//  Append new row to trades CSV.
//+------------------------------------------------------------------+
void AppendTradeResult(int sigId, int ticket, double price, double lots, string status)
{
   int fh = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE)
      fh = FileOpen(FILE_TRADES, FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) return;

   if(FileTell(fh) == 0)
      FileWrite(fh, "signal_id,ticket,entry_price,lots,status,close_price,pnl,r_multiple,timestamp");

   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, sigId, ticket, price, lots, status, 0, 0, 0,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   FileClose(fh);
}

void UpdateTradeResult(int ticket, string outcome, double closePrice, double pnl, double rMult)
{
   int fh = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, 0, ticket, 0, 0, outcome, closePrice, pnl, rMult,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   FileClose(fh);
}

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