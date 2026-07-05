"""Cable (GBP/USD) fair-price series for the wstGBP/USDC venue.

Reuses wethsim's CSV loader (schema unchanged); everything else diverges from the WETH
venue on purpose:

- fair_true(i) = 1 / (gbpusd(i) * nav(t_i)) — wstGBP-per-USDC under the venue's
  USDC = $1.00 assumption, matching the hook's `1e8*WAD^2/(g*nav)` composition.
- NAV is a **weekly discrete ratchet**, not a smooth drift: nav(t) = (1+step)^k with k the
  number of ratchet instants <= t. The step IS this venue's flow driver (each ratchet
  drops fair ~step below the pool and re-arms the buy-then-redeem conveyor), so modeling
  it as continuous drift would erase the phenomenon being tuned for.
- The hook prices deviation off Chainlink GBP/USD, which only commits on a 0.15% move or
  the 24h heartbeat — a deadband LARGER than the wrapper's 12.5bps half-band, so it is
  modeled explicitly: `fair_oracle` uses the committed feed value, `fair_true` the live
  bar. Fees are charged at oracle-fair deviation; arb profit is real at true fair; the
  wrapper leg (navprice) is read live on-chain and steps instantly in both.
"""

from dataclasses import dataclass

from wethsim.bars import BarSeries, load_csv  # noqa: F401  (load_csv re-exported for callers)

DAY = 86_400


@dataclass(frozen=True)
class NavStepModel:
    """nav(t) = (1 + step_bps/1e4)^k, k = ratchets at t0 + phase + n*period that are <= t.

    Defaults: 9 bps weekly ((1.0009)^52 ~ 4.8% APY, mid of the observed 8-10 bps range),
    first step landing `phase_days` into the series (mid-week-one; phase is immaterial
    over the ~17-26 steps of a regime). Deterministic and reproducible by design — the
    on-chain ratchet history is too shallow to fit a distribution; `step_bps` is the
    sensitivity knob.
    """

    t0: int
    step_bps: float = 9.0
    period_days: float = 7.0
    phase_days: float = 3.0

    def count(self, t: int) -> int:
        first = self.t0 + int(self.phase_days * DAY)
        if t < first:
            return 0
        return 1 + int((t - first) / (self.period_days * DAY))

    def nav(self, t: int) -> float:
        return (1 + self.step_bps / 1e4) ** self.count(t)


class OracleSeries:
    """Chainlink-style deadband commitment of a bar series: the committed value updates
    when the live price moves >= `deviation` from the last commit, or `heartbeat` seconds
    elapse. Weekend forward-fills naturally reproduce the frozen on-chain feed."""

    def __init__(self, bars: BarSeries, deviation: float = 0.0015, heartbeat: int = DAY):
        self.committed: list[float] = []
        last_px = bars.ethgbp[0]
        last_t = bars.timestamps[0]
        for t, px in zip(bars.timestamps, bars.ethgbp):
            if abs(px / last_px - 1.0) >= deviation or t - last_t >= heartbeat:
                last_px, last_t = px, t
            self.committed.append(last_px)


class CableFair:
    """Composes bars + nav steps + the oracle model into the two fair series the sim
    consumes, plus the ratchet indices the runner uses for conveyor-lag telemetry."""

    def __init__(
        self,
        bars: BarSeries,
        nav_model: NavStepModel | None = None,
        oracle_deviation: float = 0.0015,
        oracle_heartbeat: int = DAY,
    ):
        self.bars = bars
        self.nav_model = nav_model or NavStepModel(t0=bars.timestamps[0])
        self.oracle = OracleSeries(bars, oracle_deviation, oracle_heartbeat)
        # Bar indices at which a ratchet has occurred since the previous bar.
        self.ratchet_indices: list[int] = []
        prev = self.nav_model.count(bars.timestamps[0])
        for i, t in enumerate(bars.timestamps):
            k = self.nav_model.count(t)
            if k > prev:
                self.ratchet_indices.append(i)
            prev = k

    def __len__(self) -> int:
        return len(self.bars)

    def nav(self, i: int) -> float:
        return self.nav_model.nav(self.bars.timestamps[i])

    def fair_true(self, i: int) -> float:
        return 1.0 / (self.bars.ethgbp[i] * self.nav(i))

    def fair_oracle(self, i: int) -> float:
        return 1.0 / (self.oracle.committed[i] * self.nav(i))
