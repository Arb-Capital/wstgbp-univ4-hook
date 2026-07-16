"""Gold-in-sterling fair-price series for the XAUT/wstGBP venue.

Composes TWO Dukascopy minute series (XAU/USD spot gold + GBP/USD cable) into the venue's
two-feed fair, mirroring the hook's `x*WAD^2/(g*nav)` composition (wstGBP-per-XAUT):

- fair_true(i) = xau(i)*(1 - basis) / (gbpusd(i) * nav(t_i)) — the TOKEN-market fair.
  Chainlink XAU/USD prices the METAL; XAUt persistently trades ~0.5% below it (custody/
  redemption friction, ROADMAP.md 2026-07-11), so the true series carries `basis_bps`
  while the oracle series does NOT — that gap IS the venue's rest state (the pool sits at
  d_oracle ≈ -basis, and the fee model's threshold must be sized around it; this sweep's
  reason for existing).
- fair_oracle(i) = xau_committed(i) / (gbp_committed(i) * nav(t_i)) — what the hook
  computes: BOTH feeds pass through their own Chainlink deadband model (XAU/USD 0.3%/24h,
  coarser than GBP/USD's 0.15%/24h — the deviation signal steps chunkier on this venue).
- NAV is cablesim's weekly discrete ratchet, imported unchanged: each step lowers fair
  and re-arms the buy-then-redeem conveyor exactly as on the USDC venue.
- NUMERAIRE PLUMBING (the structural delta vs cablesim): cablesim valued wstGBP in USD as
  1/fair only because USDC = $1.00. Here both USD legs are explicit —
  `usd_per_wsg(i) = gbp*nav` (NAV-anchored) and `usd_per_xaut(i) = xau*(1 - basis)`
  (token-market) — and `fair_true == usd_per_xaut / usd_per_wsg` by construction.

Weekend/holiday handling: gold observes the FX close (plus a daily 22:00-23:00 UTC
break); both inputs are forward-filled flat by the frozen wethsim loader, reproducing
what two frozen on-chain Chainlink feeds report over a close. `compose` trims both
series to their overlapping window and asserts the shared 60s grid.
"""

from cablesim.bars import DAY, NavStepModel, OracleSeries  # noqa: F401  (re-exported)
from wethsim.bars import BarSeries, load_csv  # noqa: F401  (load_csv re-exported)


def compose(xau: BarSeries, gbp: BarSeries) -> tuple[BarSeries, BarSeries]:
    """Trim both strict-60s-grid series to their overlapping window, index-aligned.

    The frozen loader emits minute-boundary timestamps with bounded forward-fill, so
    after trimming, equal timestamp vectors are guaranteed unless the inputs are broken —
    asserted, not assumed.
    """
    if (xau.timestamps[0] - gbp.timestamps[0]) % 60 != 0:
        raise ValueError("XAU and GBP series are not on the same minute grid")
    t0 = max(xau.timestamps[0], gbp.timestamps[0])
    t1 = min(xau.timestamps[-1], gbp.timestamps[-1])
    if t1 <= t0:
        raise ValueError("XAU and GBP series do not overlap")
    xi = (t0 - xau.timestamps[0]) // 60
    gi = (t0 - gbp.timestamps[0]) // 60
    n = (t1 - t0) // 60 + 1
    x_out = BarSeries(xau.timestamps[xi : xi + n], xau.ethgbp[xi : xi + n])
    g_out = BarSeries(gbp.timestamps[gi : gi + n], gbp.ethgbp[gi : gi + n])
    if x_out.timestamps != g_out.timestamps:
        raise ValueError("XAU/GBP grid mismatch after trim (broken input series)")
    return x_out, g_out


class GoldFair:
    """Composes the two bar series + nav steps + two oracle models + the token-metal
    basis into the fair/numeraire series the sim consumes, plus the ratchet indices the
    runner uses for conveyor-lag telemetry."""

    def __init__(
        self,
        xau: BarSeries,
        gbp: BarSeries,
        nav_model: NavStepModel | None = None,
        basis_bps: float = 50.0,
        xau_oracle_deviation: float = 0.003,
        gbp_oracle_deviation: float = 0.0015,
        oracle_heartbeat: int = DAY,
    ):
        self.xau, self.gbp = compose(xau, gbp)
        self.nav_model = nav_model or NavStepModel(t0=self.xau.timestamps[0])
        self.xau_oracle = OracleSeries(self.xau, xau_oracle_deviation, oracle_heartbeat)
        self.gbp_oracle = OracleSeries(self.gbp, gbp_oracle_deviation, oracle_heartbeat)
        self.basis = basis_bps / 1e4
        # Bar indices at which a ratchet has occurred since the previous bar.
        self.ratchet_indices: list[int] = []
        prev = self.nav_model.count(self.xau.timestamps[0])
        for i, t in enumerate(self.xau.timestamps):
            k = self.nav_model.count(t)
            if k > prev:
                self.ratchet_indices.append(i)
            prev = k

    def __len__(self) -> int:
        return len(self.xau)

    def nav(self, i: int) -> float:
        return self.nav_model.nav(self.xau.timestamps[i])

    def fair_true(self, i: int) -> float:
        return self.xau.ethgbp[i] * (1 - self.basis) / (self.gbp.ethgbp[i] * self.nav(i))

    def fair_oracle(self, i: int) -> float:
        return self.xau_oracle.committed[i] / (self.gbp_oracle.committed[i] * self.nav(i))

    def usd_per_wsg(self, i: int) -> float:
        return self.gbp.ethgbp[i] * self.nav(i)

    def usd_per_xaut(self, i: int) -> float:
        return self.xau.ethgbp[i] * (1 - self.basis)
