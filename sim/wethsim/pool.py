"""Single-static-range concentrated-liquidity pool — EXACT in-range Uniswap v3/v4 math.

For one position [p_lower, p_upper], v3/v4 concentrated liquidity IS constant product on
virtual reserves while price stays in range; this model reproduces the swap math exactly
(the only fidelity dropped vs the chain: tick-spacing rounding of the range edges and
fee-growth rounding dust — irrelevant for relative parameter comparison).

Convention: price P = wstGBP per WETH (the venue's quote convention, matching OracleLib).
WETH plays x (base), wstGBP plays y (quote): x_v = L / sqrt(P), y_v = L * sqrt(P).
Selling WETH into the pool (redeem-side flow) pushes P DOWN; selling wstGBP pushes P UP.

NOTE the sign vs deviation: d = pool/fair - 1. d > 0 (pool price high = more wstGBP per
WETH = WETH rich) is closed by selling WETH. Mirrors the contract exactly.
"""

from dataclasses import dataclass, field
import math

PPM = 1_000_000


@dataclass
class SwapResult:
    amount_in: float  # gross input (fee-inclusive)
    amount_out: float
    fee_paid: float  # in the input token
    fee_ppm: int
    partial: bool  # clamped at a range edge


@dataclass
class Pool:
    liquidity: float  # L, in sqrt(wstGBP*WETH) units
    sqrt_price: float  # sqrt(P), P in wstGBP per WETH
    sqrt_lower: float
    sqrt_upper: float
    # accounting
    fees_weth: float = 0.0
    fees_wsg: float = 0.0
    fees_weth_base: float = 0.0  # base-fee component split (surcharge = total - base)
    fees_wsg_base: float = 0.0
    breach_bars: int = 0

    @classmethod
    def make(cls, price: float, liquidity: float, width: float = 1.75) -> "Pool":
        s = math.sqrt(price)
        return cls(
            liquidity=liquidity,
            sqrt_price=s,
            sqrt_lower=s / math.sqrt(width),
            sqrt_upper=s * math.sqrt(width),
        )

    @property
    def price(self) -> float:
        return self.sqrt_price**2

    def in_range(self) -> bool:
        return self.sqrt_lower < self.sqrt_price < self.sqrt_upper

    def reserves(self) -> tuple[float, float]:
        """(weth, wsg) REAL reserves of the single position at the current price."""
        s = min(max(self.sqrt_price, self.sqrt_lower), self.sqrt_upper)
        weth = self.liquidity * (1 / s - 1 / self.sqrt_upper)
        wsg = self.liquidity * (s - self.sqrt_lower)
        return weth, wsg

    def value_wsg(self, fair: float) -> float:
        """Position value (wstGBP terms) at fair price, fees included."""
        weth, wsg = self.reserves()
        return (weth + self.fees_weth) * fair + wsg + self.fees_wsg

    # ---------------------------------------------------------------- swaps (exact in)

    def swap_weth_in(self, amount_in: float, fee_ppm: int, base_ppm: int) -> SwapResult:
        """Sell WETH for wstGBP: sqrt(P) decreases. Exact-in with fee on input."""
        net = amount_in * (PPM - fee_ppm) / PPM
        L, s = self.liquidity, self.sqrt_price
        # x-in: 1/s' = 1/s + dx/L  =>  s' = L*s / (L + dx*s)
        s_new = L * s / (L + net * s)
        partial = False
        if s_new < self.sqrt_lower:  # clamp at the lower edge, fill partially
            s_new = self.sqrt_lower
            net_used = L * (1 / s_new - 1 / s)
            gross_used = net_used * PPM / (PPM - fee_ppm)
            partial = True
        else:
            net_used, gross_used = net, amount_in
        out = L * (s - s_new)  # wstGBP out
        fee = gross_used - net_used
        self.sqrt_price = s_new
        self.fees_weth += fee
        self.fees_weth_base += fee * base_ppm / fee_ppm if fee_ppm else 0.0
        return SwapResult(gross_used, out, fee, fee_ppm, partial)

    def swap_wsg_in(self, amount_in: float, fee_ppm: int, base_ppm: int) -> SwapResult:
        """Sell wstGBP for WETH: sqrt(P) increases. Exact-in with fee on input."""
        net = amount_in * (PPM - fee_ppm) / PPM
        L, s = self.liquidity, self.sqrt_price
        # y-in: s' = s + dy/L
        s_new = s + net / L
        partial = False
        if s_new > self.sqrt_upper:
            s_new = self.sqrt_upper
            net_used = L * (s_new - s)
            gross_used = net_used * PPM / (PPM - fee_ppm)
            partial = True
        else:
            net_used, gross_used = net, amount_in
        out = L * (1 / s - 1 / s_new)  # WETH out
        fee = gross_used - net_used
        self.sqrt_price = s_new
        self.fees_wsg += fee
        self.fees_wsg_base += fee * base_ppm / fee_ppm if fee_ppm else 0.0
        return SwapResult(gross_used, out, fee, fee_ppm, partial)

    # ---------------------------------------------------------------- sizing helpers

    def weth_in_to_reach(self, target_price: float) -> float:
        """Net WETH input that moves the pool down to target_price (clamped to range)."""
        s_t = max(math.sqrt(target_price), self.sqrt_lower)
        if s_t >= self.sqrt_price:
            return 0.0
        return self.liquidity * (1 / s_t - 1 / self.sqrt_price)

    def wsg_in_to_reach(self, target_price: float) -> float:
        """Net wstGBP input that moves the pool up to target_price (clamped to range)."""
        s_t = min(math.sqrt(target_price), self.sqrt_upper)
        if s_t <= self.sqrt_price:
            return 0.0
        return self.liquidity * (s_t - self.sqrt_price)
