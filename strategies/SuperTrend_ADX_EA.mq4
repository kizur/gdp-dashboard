//+------------------------------------------------------------------+
//|                                              SuperTrend_ADX_EA.mq4|
//|                         SuperTrend + ADX trend follower (EA)     |
//|   Trend following entries are driven by a SuperTrend flip and    |
//|   confirmed by ADX/DI strength. Stop-loss and trailing stop use  |
//|   ATR-based distances for volatility-aware risk management.      |
//+------------------------------------------------------------------+
#property copyright "OpenAI"
#property link      "https://openai.com"
#property version   "2.00"
#property strict

input double InpLots               = 0.10;   // Default lot size
input int    InpSuperTrendPeriod   = 10;     // SuperTrend ATR period
input double InpSuperTrendMult     = 3.0;    // SuperTrend multiplier
input int    InpADXPeriod          = 14;     // ADX period
input double InpADXThreshold       = 20.0;   // ADX minimum threshold
input int    InpATRPeriodSL        = 14;     // ATR period for stop-loss
input double InpATRMultiplierSL    = 2.5;    // ATR multiplier for stop-loss
input bool   InpUseTrailingStop    = true;   // Enable trailing stop
input double InpTrailingMultiplier = 1.5;    // ATR multiplier for trailing stop
input int    InpSlippage           = 3;      // Max slippage (points)
input bool   InpAllowNewPositions  = true;   // Allow opening new positions
input int    InpMagicNumber        = 4242;   // Magic number

#define MAX_CALC_BARS 500
#define ORDER_TYPE_BUY  0
#define ORDER_TYPE_SELL 1

double   g_upperBand[];
double   g_lowerBand[];
double   g_superTrend[];
int      g_trendDir[];

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   ArrayResize(g_upperBand, MAX_CALC_BARS);
   ArrayResize(g_lowerBand, MAX_CALC_BARS);
   ArrayResize(g_superTrend, MAX_CALC_BARS);
   ArrayResize(g_trendDir, MAX_CALC_BARS);

   ArraySetAsSeries(g_upperBand, true);
   ArraySetAsSeries(g_lowerBand, true);
   ArraySetAsSeries(g_superTrend, true);
   ArraySetAsSeries(g_trendDir, true);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(Bars <= InpSuperTrendPeriod + 5)
      return;

   bool isNewBar = (Time[0] != g_lastBarTime);
   if(isNewBar)
     {
      g_lastBarTime = Time[0];
      UpdateSuperTrend();
      ManageSignals();
     }

   if(InpUseTrailingStop)
      ApplyTrailingStop();
  }

//+------------------------------------------------------------------+
//| Calculate SuperTrend values                                      |
//+------------------------------------------------------------------+
void UpdateSuperTrend()
  {
   int limit = MathMin(Bars - 1, MAX_CALC_BARS - 1);

   for(int i = limit; i >= 0; i--)
     {
      double atr = iATR(Symbol(), PERIOD_CURRENT, InpSuperTrendPeriod, i);
      double hl2 = (High[i] + Low[i]) / 2.0;
      double upperBasic = hl2 + InpSuperTrendMult * atr;
      double lowerBasic = hl2 - InpSuperTrendMult * atr;

      if(i == limit)
        {
         g_upperBand[i] = upperBasic;
         g_lowerBand[i] = lowerBasic;
         g_trendDir[i] = (Close[i] >= hl2 ? 1 : -1);
        }
      else
        {
         int next = i + 1;

         if(Close[next] > g_upperBand[next])
            g_upperBand[i] = MathMin(upperBasic, g_upperBand[next]);
         else
            g_upperBand[i] = upperBasic;

         if(Close[next] < g_lowerBand[next])
            g_lowerBand[i] = MathMax(lowerBasic, g_lowerBand[next]);
         else
            g_lowerBand[i] = lowerBasic;

         if(g_trendDir[next] == 1)
           {
            if(Close[i] < g_lowerBand[i])
               g_trendDir[i] = -1;
            else
               g_trendDir[i] = 1;
           }
         else
           {
            if(Close[i] > g_upperBand[i])
               g_trendDir[i] = 1;
            else
               g_trendDir[i] = -1;
           }
        }

      g_superTrend[i] = (g_trendDir[i] == 1 ? g_lowerBand[i] : g_upperBand[i]);
     }
  }

//+------------------------------------------------------------------+
//| Manage entry/exit signals                                        |
//+------------------------------------------------------------------+
void ManageSignals()
  {
   int trendNow = g_trendDir[0];
   int trendPrev = g_trendDir[1];

   double adxValue = iADX(Symbol(), PERIOD_CURRENT, InpADXPeriod, PRICE_CLOSE, MODE_MAIN, 0);
   double plusDI   = iADX(Symbol(), PERIOD_CURRENT, InpADXPeriod, PRICE_CLOSE, MODE_PLUSDI, 0);
   double minusDI  = iADX(Symbol(), PERIOD_CURRENT, InpADXPeriod, PRICE_CLOSE, MODE_MINUSDI, 0);

   bool adxStrong = (adxValue >= InpADXThreshold);

   int signal = 0;
   if(trendPrev == -1 && trendNow == 1 && adxStrong && plusDI > minusDI)
      signal = ORDER_TYPE_BUY;
   else if(trendPrev == 1 && trendNow == -1 && adxStrong && minusDI > plusDI)
      signal = ORDER_TYPE_SELL;

   if(signal == ORDER_TYPE_BUY)
     {
      ClosePositions(OP_SELL);
      if(InpAllowNewPositions)
         OpenPosition(OP_BUY);
     }
   else if(signal == ORDER_TYPE_SELL)
     {
      ClosePositions(OP_BUY);
      if(InpAllowNewPositions)
         OpenPosition(OP_SELL);
     }
  }

//+------------------------------------------------------------------+
//| Open a market position                                           |
//+------------------------------------------------------------------+
void OpenPosition(int orderType)
  {
   if(CountOpenPositions(orderType) > 0)
      return;

   RefreshRates();

   double lotSize = NormalizeLot(InpLots);
   if(lotSize <= 0.0)
      return;

   double atr = iATR(Symbol(), PERIOD_CURRENT, InpATRPeriodSL, 0);
   double slDistance = atr * InpATRMultiplierSL;
   double price = (orderType == OP_BUY ? Ask : Bid);
   double stopLoss = 0.0;

   if(slDistance > 0.0)
      stopLoss = (orderType == OP_BUY ? price - slDistance : price + slDistance);

   stopLoss = (stopLoss > 0.0 ? NormalizeDouble(stopLoss, Digits) : 0.0);

   int ticket = OrderSend(Symbol(), orderType, lotSize, price, InpSlippage,
                          stopLoss, 0.0, "SuperTrendADX", InpMagicNumber, 0,
                          clrDodgerBlue);
   if(ticket < 0)
      Print("OrderSend failed: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Close positions of a specific type                               |
//+------------------------------------------------------------------+
void ClosePositions(int orderType)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagicNumber)
         continue;

      if(OrderType() != orderType)
         continue;

      bool closed = OrderClose(OrderTicket(), OrderLots(),
                               (orderType == OP_BUY ? Bid : Ask),
                               InpSlippage, clrRed);
      if(!closed)
         Print("OrderClose failed: ", GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Apply ATR trailing stop                                          |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
  {
   double atr = iATR(Symbol(), PERIOD_CURRENT, InpATRPeriodSL, 0);
   double trailDistance = atr * InpTrailingMultiplier;

   if(trailDistance <= 0.0)
      return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagicNumber)
         continue;

      if(OrderType() == OP_BUY)
        {
         double newSL = Bid - trailDistance;
         newSL = NormalizeDouble(newSL, Digits);
         if(newSL > OrderStopLoss())
            ModifyOrderStopLoss(newSL);
        }
      else if(OrderType() == OP_SELL)
        {
         double newSL = Ask + trailDistance;
         newSL = NormalizeDouble(newSL, Digits);
         if(OrderStopLoss() == 0.0 || newSL < OrderStopLoss())
            ModifyOrderStopLoss(newSL);
        }
     }
  }

//+------------------------------------------------------------------+
//| Modify stop loss                                                 |
//+------------------------------------------------------------------+
void ModifyOrderStopLoss(double newSL)
  {
   bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL,
                               OrderTakeProfit(), 0, clrYellow);
   if(!modified)
      Print("OrderModify failed: ", GetLastError());
  }

//+------------------------------------------------------------------+
//| Count open positions by type                                     |
//+------------------------------------------------------------------+
int CountOpenPositions(int orderType)
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol() || OrderMagicNumber() != InpMagicNumber)
         continue;

      if(OrderType() == orderType)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Normalize lot size                                               |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
  {
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   lots = MathMax(minLot, MathMin(maxLot, lots));
   int steps = (int)MathFloor((lots - minLot) / lotStep + 0.5);
   double normalized = minLot + steps * lotStep;
   normalized = NormalizeDouble(normalized, 2);

   double marginCheck = AccountFreeMarginCheck(Symbol(), OP_BUY, normalized);
   if(marginCheck <= 0)
     {
      Print("Not enough free margin for lot size ", normalized);
      return(0.0);
     }

   return(normalized);
  }
//+------------------------------------------------------------------+
