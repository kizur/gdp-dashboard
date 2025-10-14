"""Trading strategy utilities for the triple moving-average + CCI setup.

This module implements the strategy requested in the user instructions. It is
not tied to any specific trading platform; instead it exposes pure Python
functions that can be wired into MT4/MT5, a backtesting engine, or a Streamlit
prototype.  Configuration is loaded from ``config.ini`` using
``configparser.ConfigParser`` and the strategy operates on pandas ``DataFrame``
objects with OHLC data.
"""

from __future__ import annotations

from configparser import ConfigParser
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np
import pandas as pd


class MovingAverageType(str, Enum):
    """Supported moving average types."""

    SMA = "sma"
    EMA = "ema"
    WMA = "wma"

    @classmethod
    def from_string(cls, value: str) -> "MovingAverageType":
        try:
            return cls(value.lower())
        except ValueError as exc:
            valid = ", ".join(m.value for m in cls)
            raise ValueError(f"Unknown MA type '{value}'. Valid values: {valid}") from exc


def _weighted_moving_average(series: pd.Series, period: int) -> pd.Series:
    weights = np.arange(1, period + 1)
    return series.rolling(period).apply(lambda prices: np.dot(prices, weights) / weights.sum(), raw=True)


def moving_average(series: pd.Series, period: int, ma_type: MovingAverageType) -> pd.Series:
    """Calculate a moving average with the requested type."""

    if ma_type is MovingAverageType.SMA:
        return series.rolling(period).mean()
    if ma_type is MovingAverageType.EMA:
        return series.ewm(span=period, adjust=False).mean()
    if ma_type is MovingAverageType.WMA:
        return _weighted_moving_average(series, period)
    raise ValueError(f"Unsupported moving average type: {ma_type}")


def commodity_channel_index(df: pd.DataFrame, period: int) -> pd.Series:
    """Calculate the Commodity Channel Index (CCI)."""

    typical_price = (df["high"] + df["low"] + df["close"]) / 3
    sma = typical_price.rolling(period).mean()
    mean_deviation = typical_price.rolling(period).apply(lambda x: np.mean(np.abs(x - np.mean(x))), raw=True)
    cci = (typical_price - sma) / (0.015 * mean_deviation)
    return cci


@dataclass
class PartialCloseRule:
    rr_multiple: float
    fraction: float
    triggered: bool = False


@dataclass
class StrategyConfig:
    ma_periods: Tuple[int, int, int]
    ma_type: MovingAverageType
    cci_period: int
    cci_upper: float
    cci_lower: float
    spread: float
    stop_buffer: float
    stop_lookback: int
    risk_percent: float
    account_balance: float
    contract_size: float
    pip_value: float
    reward_risk_levels: Tuple[float, ...]
    break_even_steps: Tuple[float, ...]
    partial_close_rules: Tuple[PartialCloseRule, ...]
    allow_new_trades: bool
    max_concurrent_trades: int

    @classmethod
    def from_file(cls, path: Path) -> "StrategyConfig":
        parser = ConfigParser()
        if not parser.read(path):
            raise FileNotFoundError(f"Unable to read configuration file: {path}")

        ma_periods = tuple(int(x.strip()) for x in parser.get("moving_average", "periods").split(","))
        if len(ma_periods) != 3:
            raise ValueError("Exactly three moving average periods are required.")

        ma_type = MovingAverageType.from_string(parser.get("moving_average", "ma_type", fallback="sma"))

        partial_close_rules = []
        if parser.has_option("partial_close", "levels"):
            raw_levels = parser.get("partial_close", "levels")
            if raw_levels:
                for chunk in raw_levels.split(","):
                    chunk = chunk.strip()
                    if not chunk:
                        continue
                    rr, fraction = chunk.split("@")
                    partial_close_rules.append(PartialCloseRule(float(rr), float(fraction)))

        return cls(
            ma_periods=ma_periods,  # type: ignore[arg-type]
            ma_type=ma_type,
            cci_period=parser.getint("cci", "period"),
            cci_upper=parser.getfloat("cci", "upper_threshold"),
            cci_lower=parser.getfloat("cci", "lower_threshold"),
            spread=parser.getfloat("general", "spread"),
            stop_buffer=parser.getfloat("general", "stop_buffer"),
            stop_lookback=parser.getint("general", "stop_lookback", fallback=3),
            risk_percent=parser.getfloat("risk", "risk_percent"),
            account_balance=parser.getfloat("risk", "account_balance"),
            contract_size=parser.getfloat("risk", "contract_size", fallback=100000),
            pip_value=parser.getfloat("risk", "pip_value", fallback=1.0),
            reward_risk_levels=tuple(float(x.strip()) for x in parser.get("targets", "reward_risk_levels").split(",")),
            break_even_steps=tuple(float(x.strip()) for x in parser.get("targets", "break_even_steps", fallback="1").split(",")),
            partial_close_rules=tuple(partial_close_rules),
            allow_new_trades=parser.getboolean("general", "allow_new_trades", fallback=True),
            max_concurrent_trades=parser.getint("general", "max_concurrent_trades", fallback=1),
        )


@dataclass
class Trade:
    direction: str
    entry_price: float
    stop_loss: float
    lot_size: float
    reward_risk_levels: Tuple[float, ...]
    break_even_steps: Tuple[float, ...]
    partial_closes: Tuple[PartialCloseRule, ...]
    initial_risk: float
    take_profits: Tuple[float, ...] = field(default_factory=tuple)
    active: bool = True
    break_even_index: int = 0

    def __post_init__(self) -> None:
        if self.direction.lower() != "long":
            raise ValueError("This strategy currently supports long positions only.")
        self.take_profits = tuple(self.entry_price + self.initial_risk * level for level in self.reward_risk_levels)

    def current_stop(self) -> float:
        return self.stop_loss

    def update_stop(self, new_stop: float) -> None:
        self.stop_loss = max(self.stop_loss, new_stop)


class StrategyState:
    """In-memory state of the running strategy."""

    def __init__(self, config: StrategyConfig):
        self.config = config
        self.open_trades: List[Trade] = []

    # ------------------------------------------------------------------
    # Signal evaluation

    def _calculate_indicators(self, df: pd.DataFrame) -> pd.DataFrame:
        ma_type = self.config.ma_type
        periods = self.config.ma_periods
        enriched = df.copy()

        for period in periods:
            enriched[f"ma_{period}"] = moving_average(enriched["close"], period, ma_type)

        enriched["cci"] = commodity_channel_index(enriched, self.config.cci_period)
        return enriched

    def evaluate_long_signal(self, df: pd.DataFrame) -> Optional[Trade]:
        """Check the latest candle for a long signal."""

        if df.empty or len(df) < max(self.config.ma_periods) + 1:
            return None

        enriched = self._calculate_indicators(df)
        last_row = enriched.iloc[-1]
        previous_rows = enriched.iloc[-(self.config.stop_lookback + 1):-1]

        mas = [last_row[f"ma_{period}"] for period in self.config.ma_periods]
        if any(np.isnan(value) for value in mas):
            return None

        close_price = last_row["close"]

        if not all(close_price > value for value in mas):
            return None

        if last_row["cci"] <= self.config.cci_upper:
            return None

        lowest_low = previous_rows["low"].min()
        stop_loss = lowest_low - self.config.spread - self.config.stop_buffer
        if not np.isfinite(stop_loss) or stop_loss >= close_price:
            return None

        risk_per_unit = close_price - stop_loss
        risk_amount = self.config.account_balance * (self.config.risk_percent / 100)
        if risk_per_unit <= 0:
            return None

        risk_per_lot = risk_per_unit * self.config.contract_size * self.config.pip_value
        if risk_per_lot <= 0:
            return None

        lot_size = risk_amount / risk_per_lot
        if lot_size <= 0:
            return None

        trade = Trade(
            direction="long",
            entry_price=close_price,
            stop_loss=stop_loss,
            lot_size=lot_size,
            reward_risk_levels=self.config.reward_risk_levels,
            break_even_steps=self.config.break_even_steps,
            partial_closes=self.config.partial_close_rules,
            initial_risk=risk_per_unit,
        )

        return trade

    # ------------------------------------------------------------------
    # Trade management

    def _apply_break_even_rules(self, trade: Trade, candle_high: float) -> None:
        for step in trade.break_even_steps[trade.break_even_index:]:
            trigger = trade.entry_price + trade.initial_risk * step
            if candle_high >= trigger:
                new_stop = trade.entry_price + trade.initial_risk * max(step - 1, 0)
                trade.update_stop(new_stop)
                trade.break_even_index += 1
            else:
                break

    def _apply_partial_closes(self, trade: Trade, candle_high: float) -> float:
        realized = 0.0
        for rule in trade.partial_closes:
            if rule.triggered:
                continue
            trigger = trade.entry_price + trade.initial_risk * rule.rr_multiple
            if candle_high >= trigger:
                realized += rule.fraction
                rule.triggered = True
        return realized

    def manage_open_trade(self, trade: Trade, candle: Dict[str, float], cci_value: float) -> str:
        """Update stops, partial closes and exit rules.

        Returns a string describing the resulting action.
        """

        if not trade.active:
            return "trade_inactive"

        candle_low = candle["low"]
        candle_high = candle["high"]

        # Check for CCI-based exit first.
        if cci_value <= self.config.cci_lower:
            trade.active = False
            return "exit_cci"

        # Break-even adjustments.
        self._apply_break_even_rules(trade, candle_high)

        # Partial closes (expressed as fraction of remaining position). We simply
        # report them; the integration layer is responsible for actual order
        # execution.
        partial_fraction = self._apply_partial_closes(trade, candle_high)
        if partial_fraction:
            action = f"partial_close_{partial_fraction:.2f}"
        else:
            action = "hold"

        # Stop-loss check.
        if candle_low <= trade.stop_loss:
            trade.active = False
            return "stopped_out"

        # Take-profit check at the final RR level.
        if trade.take_profits and candle_high >= trade.take_profits[-1]:
            trade.active = False
            return "take_profit"

        return action

    # ------------------------------------------------------------------

    def can_open_new_trade(self) -> bool:
        if not self.config.allow_new_trades:
            return False
        return len([trade for trade in self.open_trades if trade.active]) < self.config.max_concurrent_trades

    def register_trade(self, trade: Trade) -> None:
        self.open_trades.append(trade)


def load_price_data(source: Iterable[Dict[str, float]]) -> pd.DataFrame:
    """Load OHLC data from an iterable of dictionaries.

    Each item in ``source`` must include ``open``, ``high``, ``low`` and
    ``close`` keys. Additional keys are ignored.
    """

    return pd.DataFrame(list(source))


def load_config(path: Optional[Path] = None) -> StrategyConfig:
    """Helper to load the default configuration file."""

    path = path or Path("config.ini")
    return StrategyConfig.from_file(path)


def prepare_strategy(path: Optional[Path] = None) -> StrategyState:
    """Convenience helper used by the Streamlit demo or unit tests."""

    config = load_config(path)
    return StrategyState(config)


__all__ = [
    "MovingAverageType",
    "StrategyConfig",
    "StrategyState",
    "Trade",
    "load_config",
    "prepare_strategy",
    "load_price_data",
]
