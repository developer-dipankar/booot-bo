//+------------------------------------------------------------------+
//|                                      TelegramTradeNotifier.mq5   |
//|                         Sends trade alerts to Telegram           |
//+------------------------------------------------------------------+
#property copyright "Trade Notifier"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input string InpBotToken = "8238574819:AAFrTdkYxvB3aBReLF2cSmXr6Hu_jA64qDE"; // Bot Token
input string InpChatId   = "-1003656505797";                                  // Chat ID

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpBotToken) == 0 || StringLen(InpChatId) == 0)
   {
      Print("ERROR: Bot Token or Chat ID not configured!");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Print("TelegramTradeNotifier started - monitoring all symbols");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      ProcessDeal(trans.deal);
}

//+------------------------------------------------------------------+
//| Process deal                                                      |
//+------------------------------------------------------------------+
void ProcessDeal(ulong dealTicket)
{
   if(dealTicket == 0) return;

   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   if(!HistoryDealSelect(dealTicket)) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) return;

   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(entry == DEAL_ENTRY_IN)
   {
      double sl = 0, tp = 0;
      if(PositionSelectByTicket(posId))
      {
         sl = PositionGetDouble(POSITION_SL);
         tp = PositionGetDouble(POSITION_TP);
      }

      string dir = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      string emoji = (dealType == DEAL_TYPE_BUY) ? "📈" : "📉";

      string msg = emoji + " " + symbol + ": " + dir + ": OP - " + DoubleToString(price, digits);
      if(tp > 0) msg += ": TP - " + DoubleToString(tp, digits);
      if(sl > 0) msg += ": SL - " + DoubleToString(sl, digits);

      SendTelegram(msg);
   }
   else if(entry == DEAL_ENTRY_OUT)
   {
      string msg = "";
      if(reason == DEAL_REASON_TP)
         msg = "🎯 TP Hit to " + DoubleToString(price, digits);
      else if(reason == DEAL_REASON_SL)
         msg = "🛑 SL Hit to " + DoubleToString(price, digits);
      else
         msg = "📊 Closed at " + DoubleToString(price, digits);

      SendTelegram(msg);
   }
}

//+------------------------------------------------------------------+
//| Send Telegram message                                             |
//+------------------------------------------------------------------+
bool SendTelegram(string message)
{
   string url = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
   string params = "chat_id=" + InpChatId + "&text=" + UrlEncode(message);

   char post[], result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   StringToCharArray(params, post, 0, StringLen(params), CP_UTF8);

   int res = WebRequest("POST", url, headers, 5000, post, result, headers);
   return (res == 200);
}

//+------------------------------------------------------------------+
//| URL encode - properly handles UTF-8 and emojis                   |
//+------------------------------------------------------------------+
string UrlEncode(string text)
{
   string result = "";

   // Convert entire string to UTF-8 bytes first
   uchar bytes[];
   int len = StringToCharArray(text, bytes, 0, -1, CP_UTF8);

   for(int i = 0; i < len - 1; i++)  // -1 to skip null terminator
   {
      uchar ch = bytes[i];

      // Safe characters that don't need encoding
      if((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
         (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == ':')
      {
         result += CharArrayToString(bytes, i, 1);
      }
      else if(ch == ' ')
      {
         result += "+";
      }
      else
      {
         // Percent-encode the byte
         result += "%" + ByteToHex(ch);
      }
   }
   return result;
}

//+------------------------------------------------------------------+
//| Byte to hex                                                       |
//+------------------------------------------------------------------+
string ByteToHex(uchar b)
{
   string hex = "0123456789ABCDEF";
   return StringSubstr(hex, (b >> 4) & 0x0F, 1) + StringSubstr(hex, b & 0x0F, 1);
}

void OnTick() {}
void OnDeinit(const int reason) { Print("TelegramTradeNotifier stopped"); }
//+------------------------------------------------------------------+



//+https://api.telegram.org
