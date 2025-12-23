//+------------------------------------------------------------------+
//|                                           CopyTradingScript.mq5  |
//|                   Copy Trading - Signal Queue (SQLite-Based)     |
//+------------------------------------------------------------------+
#property copyright "CopyTrading Script"
#property version   "3.00"
#property strict

//--- Signal Types
#define SIGNAL_OPEN      1
#define SIGNAL_CLOSE     2
#define SIGNAL_MODIFY    3

//--- Input Parameters
input group "=== Mode ==="
input bool     InpIsMaster        = true;               // Is Master? (false = Slave)
input string   InpMasterIDs       = "12345";            // Master Account IDs to follow (comma sep)

input group "=== Filters ==="
input string   InpSymbols         = "";                 // Symbols to copy (empty = ALL)
input double   InpLotMultiplier   = 1.0;                // Lot Multiplier (Slave only)
input double   InpMaxLot          = 10.0;               // Max Lot Size

input group "=== Settings ==="
input int      InpSyncMs          = 100;                // Sync Interval (ms)
input int      InpSlippage        = 20;                 // Max Slippage (points)
input int      InpMagicNumber     = 123456;             // Magic Number for copied trades
input string   InpDBName          = "CopyTrading.db";   // Database Name

//--- Global Variables
string         g_masters[];
string         g_symbols[];
int            g_masterCount = 0;
int            g_symbolCount = 0;
int            g_db = INVALID_HANDLE;                   // Database handle
long           g_accountId;

//--- Position tracking for slave (maps master PosID to slave PosID)
ulong          g_masterPosIds[];
ulong          g_slavePosIds[];
long           g_masterIds[];      // Which master each position belongs to
int            g_posMapCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_accountId = AccountInfoInteger(ACCOUNT_LOGIN);

   // Parse master IDs
   if(InpMasterIDs != "")
      g_masterCount = StringSplit(InpMasterIDs, ',', g_masters);

   // Parse symbol filter
   if(InpSymbols != "")
      g_symbolCount = StringSplit(InpSymbols, ',', g_symbols);

   // Open/Create SQLite database
   g_db = DatabaseOpen(InpDBName, DATABASE_OPEN_READWRITE | DATABASE_OPEN_CREATE | DATABASE_OPEN_COMMON);
   if(g_db == INVALID_HANDLE)
   {
      Print("[ERROR] Cannot open database: ", GetLastError());
      return INIT_FAILED;
   }

   // Create tables
   if(!CreateTables())
   {
      Print("[ERROR] Cannot create tables");
      DatabaseClose(g_db);
      return INIT_FAILED;
   }

   string mode = InpIsMaster ? "MASTER" : "SLAVE";
   PrintFormat("CopyTrading Started | Mode: %s | Account: %d | DB: %s", mode, g_accountId, InpDBName);

   if(!InpIsMaster)
   {
      EventSetMillisecondTimer(InpSyncMs);
      LoadPositionMap(); // Load existing mappings
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Create database tables                                            |
//+------------------------------------------------------------------+
bool CreateTables()
{
   // Signal queue table - real-time signals from master
   string sql1 = "CREATE TABLE IF NOT EXISTS signals ("
                 "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                 "master_id INTEGER NOT NULL,"
                 "signal_type INTEGER NOT NULL,"  // 1=OPEN, 2=CLOSE, 3=MODIFY
                 "pos_id INTEGER NOT NULL,"
                 "symbol TEXT NOT NULL,"
                 "trade_type INTEGER NOT NULL,"   // 0=BUY, 1=SELL
                 "volume REAL NOT NULL,"
                 "sl REAL NOT NULL,"
                 "tp REAL NOT NULL,"
                 "created_at INTEGER NOT NULL)";

   // Position mapping table (master pos -> slave pos)
   string sql2 = "CREATE TABLE IF NOT EXISTS pos_map ("
                 "master_id INTEGER NOT NULL,"
                 "master_pos_id INTEGER NOT NULL,"
                 "slave_id INTEGER NOT NULL,"
                 "slave_pos_id INTEGER NOT NULL,"
                 "symbol TEXT NOT NULL,"
                 "PRIMARY KEY (master_id, master_pos_id, slave_id))";

   if(!DatabaseExecute(g_db, sql1))
   {
      Print("[ERROR] Create signals table: ", GetLastError());
      return false;
   }

   if(!DatabaseExecute(g_db, sql2))
   {
      Print("[ERROR] Create pos_map table: ", GetLastError());
      return false;
   }

   // Create index for faster signal queries
   DatabaseExecute(g_db, "CREATE INDEX IF NOT EXISTS idx_signals_master ON signals(master_id)");

   return true;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(g_db != INVALID_HANDLE)
      DatabaseClose(g_db);

   Print("CopyTrading Stopped");
}

//+------------------------------------------------------------------+
//| Timer - Slave reads and executes                                  |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpIsMaster) return;
   SlaveProcessSignals();
}

//+------------------------------------------------------------------+
//| OnTick - Not used for signal queue approach                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // Signals are created in OnTradeTransaction, not OnTick
}

//+------------------------------------------------------------------+
//| Trade Transaction - Master creates signals on trade events       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(!InpIsMaster) return;

   // New position opened (deal executed)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      MasterProcessDeal(trans.deal);
   }

   // SL/TP changed
   if(trans.type == TRADE_TRANSACTION_REQUEST && request.action == TRADE_ACTION_SLTP)
   {
      MasterCreateModifySignal(request.position, request.sl, request.tp);
   }
}

//+------------------------------------------------------------------+
//| Check if symbol is allowed                                        |
//+------------------------------------------------------------------+
bool IsSymbolAllowed(string symbol)
{
   if(g_symbolCount == 0) return true; // No filter = all allowed
   
   for(int i = 0; i < g_symbolCount; i++)
   {
      string s = g_symbols[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(symbol == s) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| MASTER: Process deal and create appropriate signal               |
//+------------------------------------------------------------------+
void MasterProcessDeal(ulong dealTicket)
{
   if(dealTicket == 0 || g_db == INVALID_HANDLE) return;

   HistorySelect(TimeCurrent() - 300, TimeCurrent());
   if(!HistoryDealSelect(dealTicket)) return;

   long posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(posId == 0) return; // Skip invalid PosID

   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(!IsSymbolAllowed(symbol)) return;

   long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   double volume  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double sl      = HistoryDealGetDouble(dealTicket, DEAL_SL);
   double tp      = HistoryDealGetDouble(dealTicket, DEAL_TP);

   int signalType = 0;
   int tradeType = (dealType == DEAL_TYPE_BUY) ? 0 : 1;

   if(dealEntry == DEAL_ENTRY_IN)
   {
      signalType = SIGNAL_OPEN;
      PrintFormat("[MASTER] OPEN Signal | PosID: %d | %s | %s | %.2f lots",
                  posId, symbol, (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL", volume);
   }
   else if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
   {
      signalType = SIGNAL_CLOSE;
      PrintFormat("[MASTER] CLOSE Signal | PosID: %d | %s", posId, symbol);
   }
   else
   {
      return; // Ignore other entry types
   }

   // Insert signal into queue
   string sql = StringFormat(
      "INSERT INTO signals (master_id,signal_type,pos_id,symbol,trade_type,volume,sl,tp,created_at) "
      "VALUES (%d,%d,%d,'%s',%d,%.2f,%.5f,%.5f,%d)",
      g_accountId, signalType, posId, symbol, tradeType, volume, sl, tp, GetTickCount());

   DatabaseExecute(g_db, sql);
}

//+------------------------------------------------------------------+
//| MASTER: Create modify signal for SL/TP change                    |
//+------------------------------------------------------------------+
void MasterCreateModifySignal(ulong posId, double sl, double tp)
{
   if(posId == 0 || g_db == INVALID_HANDLE) return;
   if(!PositionSelectByTicket(posId)) return;

   string symbol = PositionGetString(POSITION_SYMBOL);
   if(!IsSymbolAllowed(symbol)) return;

   long posType = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   int tradeType = (posType == POSITION_TYPE_BUY) ? 0 : 1;

   PrintFormat("[MASTER] MODIFY Signal | PosID: %d | SL: %.5f | TP: %.5f", posId, sl, tp);

   string sql = StringFormat(
      "INSERT INTO signals (master_id,signal_type,pos_id,symbol,trade_type,volume,sl,tp,created_at) "
      "VALUES (%d,%d,%d,'%s',%d,%.2f,%.5f,%.5f,%d)",
      g_accountId, SIGNAL_MODIFY, posId, symbol, tradeType, volume, sl, tp, GetTickCount());

   DatabaseExecute(g_db, sql);
}

//+------------------------------------------------------------------+
//| SLAVE: Process signals from all masters                          |
//+------------------------------------------------------------------+
void SlaveProcessSignals()
{
   if(g_db == INVALID_HANDLE) return;

   for(int m = 0; m < g_masterCount; m++)
   {
      string masterId = g_masters[m];
      StringTrimLeft(masterId);
      StringTrimRight(masterId);
      long masterIdNum = StringToInteger(masterId);

      // Query signals for this master, ordered by ID (oldest first)
      string sql = StringFormat(
         "SELECT id,signal_type,pos_id,symbol,trade_type,volume,sl,tp FROM signals "
         "WHERE master_id=%d ORDER BY id ASC", masterIdNum);
      int request = DatabasePrepare(g_db, sql);
      if(request == INVALID_HANDLE) continue;

      // Collect signal IDs to delete after processing
      ulong signalIdsToDelete[];
      int deleteCount = 0;

      while(DatabaseRead(request))
      {
         long signalId, signalType, posId, tradeType;
         string symbol;
         double volume, sl, tp;

         DatabaseColumnLong(request, 0, signalId);
         DatabaseColumnLong(request, 1, signalType);
         DatabaseColumnLong(request, 2, posId);
         DatabaseColumnText(request, 3, symbol);
         DatabaseColumnLong(request, 4, tradeType);
         DatabaseColumnDouble(request, 5, volume);
         DatabaseColumnDouble(request, 6, sl);
         DatabaseColumnDouble(request, 7, tp);

         if(posId == 0) continue;
         if(!IsSymbolAllowed(symbol)) continue;

         bool processed = false;

         if(signalType == SIGNAL_OPEN)
         {
            // Check if we already have this position (avoid duplicate)
            ulong slavePosId = GetSlavePosition(masterIdNum, posId);
            if(slavePosId == 0)
            {
               processed = OpenPosition(masterIdNum, posId, symbol, (int)tradeType, volume, sl, tp);
            }
            else
            {
               processed = true; // Already exists, consider processed
            }
         }
         else if(signalType == SIGNAL_CLOSE)
         {
            ulong slavePosId = GetSlavePosition(masterIdNum, posId);
            if(slavePosId > 0)
            {
               processed = ClosePosition(slavePosId, masterIdNum, posId);
               if(processed) UnmapPosition(masterIdNum, posId);
            }
            else
            {
               processed = true; // No position to close, consider processed
            }
         }
         else if(signalType == SIGNAL_MODIFY)
         {
            ulong slavePosId = GetSlavePosition(masterIdNum, posId);
            if(slavePosId > 0)
            {
               processed = UpdatePosition(slavePosId, sl, tp);
            }
            else
            {
               processed = true; // No position to modify, consider processed
            }
         }

         // Mark signal for deletion
         if(processed)
         {
            ArrayResize(signalIdsToDelete, deleteCount + 1);
            signalIdsToDelete[deleteCount] = signalId;
            deleteCount++;
         }
      }
      DatabaseFinalize(request);

      // Delete processed signals
      for(int i = 0; i < deleteCount; i++)
      {
         string delSql = StringFormat("DELETE FROM signals WHERE id=%d", signalIdsToDelete[i]);
         DatabaseExecute(g_db, delSql);
      }
   }
}

//+------------------------------------------------------------------+
//| Load position map from database on startup                       |
//+------------------------------------------------------------------+
void LoadPositionMap()
{
   if(g_db == INVALID_HANDLE) return;

   string sql = StringFormat("SELECT master_id, master_pos_id, slave_pos_id FROM pos_map WHERE slave_id=%d", g_accountId);
   int request = DatabasePrepare(g_db, sql);
   if(request == INVALID_HANDLE) return;

   while(DatabaseRead(request))
   {
      long masterId, masterPosId, slavePosId;
      DatabaseColumnLong(request, 0, masterId);
      DatabaseColumnLong(request, 1, masterPosId);
      DatabaseColumnLong(request, 2, slavePosId);

      // Verify the slave position still exists
      if(!PositionSelectByTicket(slavePosId))
      {
         // Position no longer exists, remove stale mapping
         string delSql = StringFormat("DELETE FROM pos_map WHERE slave_id=%d AND slave_pos_id=%d",
                                      g_accountId, slavePosId);
         DatabaseExecute(g_db, delSql);
         continue;
      }

      ArrayResize(g_masterIds, g_posMapCount + 1);
      ArrayResize(g_masterPosIds, g_posMapCount + 1);
      ArrayResize(g_slavePosIds, g_posMapCount + 1);
      g_masterIds[g_posMapCount] = masterId;
      g_masterPosIds[g_posMapCount] = masterPosId;
      g_slavePosIds[g_posMapCount] = slavePosId;
      g_posMapCount++;
   }
   DatabaseFinalize(request);

   PrintFormat("[LOADED] %d position mappings from database", g_posMapCount);
}

//+------------------------------------------------------------------+
//| Get slave position ID for master position                        |
//+------------------------------------------------------------------+
ulong GetSlavePosition(long masterId, long masterPosId)
{
   // Check in-memory cache
   for(int i = 0; i < g_posMapCount; i++)
   {
      if(g_masterIds[i] == masterId && g_masterPosIds[i] == masterPosId)
         return g_slavePosIds[i];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Map master position to slave position                            |
//+------------------------------------------------------------------+
void MapPosition(long masterId, ulong masterPosId, ulong slavePosId, string symbol)
{
   // Save to database
   string sql = StringFormat(
      "INSERT OR REPLACE INTO pos_map (master_id,master_pos_id,slave_id,slave_pos_id,symbol) VALUES (%d,%d,%d,%d,'%s')",
      masterId, masterPosId, g_accountId, slavePosId, symbol);
   DatabaseExecute(g_db, sql);

   // Update in-memory cache
   ArrayResize(g_masterIds, g_posMapCount + 1);
   ArrayResize(g_masterPosIds, g_posMapCount + 1);
   ArrayResize(g_slavePosIds, g_posMapCount + 1);
   g_masterIds[g_posMapCount] = masterId;
   g_masterPosIds[g_posMapCount] = masterPosId;
   g_slavePosIds[g_posMapCount] = slavePosId;
   g_posMapCount++;
}

//+------------------------------------------------------------------+
//| Remove position from map                                         |
//+------------------------------------------------------------------+
void UnmapPosition(long masterId, ulong masterPosId)
{
   // Remove from database
   string sql = StringFormat("DELETE FROM pos_map WHERE master_id=%d AND master_pos_id=%d AND slave_id=%d",
                             masterId, masterPosId, g_accountId);
   DatabaseExecute(g_db, sql);

   // Remove from in-memory cache
   for(int i = 0; i < g_posMapCount; i++)
   {
      if(g_masterIds[i] == masterId && g_masterPosIds[i] == masterPosId)
      {
         for(int j = i; j < g_posMapCount - 1; j++)
         {
            g_masterIds[j] = g_masterIds[j + 1];
            g_masterPosIds[j] = g_masterPosIds[j + 1];
            g_slavePosIds[j] = g_slavePosIds[j + 1];
         }
         g_posMapCount--;
         ArrayResize(g_masterIds, g_posMapCount);
         ArrayResize(g_masterPosIds, g_posMapCount);
         ArrayResize(g_slavePosIds, g_posMapCount);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Open a new position                                               |
//+------------------------------------------------------------------+
bool OpenPosition(long masterId, ulong masterPosId, string symbol, int posType, double volume, double sl, double tp)
{
   // Calculate lot size
   double lots = NormalizeDouble(volume * InpLotMultiplier, 2);
   if(lots < SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN))
      lots = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(lots > InpMaxLot)
      lots = InpMaxLot;

   // Get current price
   double price = (posType == 0) ?  // 0=BUY, 1=SELL
                  SymbolInfoDouble(symbol, SYMBOL_ASK) :
                  SymbolInfoDouble(symbol, SYMBOL_BID);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = symbol;
   request.volume    = lots;
   request.type      = (posType == 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price     = price;
   request.sl        = sl;
   request.tp        = tp;
   request.deviation = InpSlippage;
   request.magic     = InpMagicNumber;
   request.comment   = StringFormat("Copy:%d:%d", masterId, masterPosId);

   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
      {
         // Map the position
         ulong slavePosId = result.order;
         MapPosition(masterId, masterPosId, slavePosId, symbol);

         PrintFormat("[SLAVE COPIED] Master: %d PosID: %d -> Slave: %d | %s | %s | %.2f lots",
                     masterId, masterPosId, slavePosId, symbol,
                     (posType == 0) ? "BUY" : "SELL", lots);
         return true;
      }
   }

   PrintFormat("[ERROR] Failed to copy Master: %d PosID: %d | %s | Error: %d",
               masterId, masterPosId, symbol, result.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Update position SL/TP                                             |
//+------------------------------------------------------------------+
bool UpdatePosition(ulong slavePosId, double sl, double tp)
{
   if(!PositionSelectByTicket(slavePosId)) return true; // Position gone, consider success

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   // Only update if changed
   if(MathAbs(currentSL - sl) < 0.00001 && MathAbs(currentTP - tp) < 0.00001)
      return true; // No change needed

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action   = TRADE_ACTION_SLTP;
   request.position = slavePosId;
   request.symbol   = PositionGetString(POSITION_SYMBOL);
   request.sl       = sl;
   request.tp       = tp;

   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         PrintFormat("[SLAVE SL/TP] PosID: %d | SL: %.5f | TP: %.5f", slavePosId, sl, tp);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close a position                                                  |
//+------------------------------------------------------------------+
bool ClosePosition(ulong slavePosId, long masterId, ulong masterPosId)
{
   if(!PositionSelectByTicket(slavePosId)) return true; // Already closed

   string symbol = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   int posType = (int)PositionGetInteger(POSITION_TYPE);

   double price = (posType == POSITION_TYPE_BUY) ?
                  SymbolInfoDouble(symbol, SYMBOL_BID) :
                  SymbolInfoDouble(symbol, SYMBOL_ASK);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = symbol;
   request.volume    = volume;
   request.type      = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price     = price;
   request.position  = slavePosId;
   request.deviation = InpSlippage;
   request.magic     = InpMagicNumber;

   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         PrintFormat("[SLAVE CLOSED] Master: %d PosID: %d | Slave PosID: %d | %s", masterId, masterPosId, slavePosId, symbol);
         return true;
      }
   }
   return false;
}
