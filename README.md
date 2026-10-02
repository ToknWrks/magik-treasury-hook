# magik-treasury-hook

A Uniswap v4 hook that charges a **graduated sell tax** on a token and actually *collects* it —
converting it to the token and splitting it burn / treasury / dev — with an optional standing
one-sided "bid" that supports the token's price.

> **WARNING: experimental, unaudited, testnet-only.** This is a prototype for a future token.
> Do not point it at a token or pool that holds real value. `src/mocks/TestERC20.sol` has an
> unrestricted `mint` and exists only for testnets.

Built on [OpenZeppelin's audited `BaseHookFee`](https://github.com/OpenZeppelin/uniswap-hooks)
(pinned as a git submodule) rather than hand-rolling ERC-6909 / `afterSwap` delta plumbing.

Intended treasury destination: the sibling ERC-4626 staking vault,
[`magik-staking-vault`](https://github.com/ToknWrks/magik-staking-vault) (to be created). The hook
only ever does a plain `transfer()` to `treasury`, so any address works.

## How the tax works

Sell size is measured as a fraction of the pool's reserve, in basis points, and looked up in an
owner-configurable bracket ladder (`minSellBps` thresholds ascending, each with a `feePpm`).
Example ladder used by `script/DeployTreasuryHook.s.sol`:

| Sell size (of reserve) | Tax |
|---|---|
| < 1% | 0% |
| ≥ 1% | 1% |
| ≥ 3% | 3% |
| ≥ 5% | 5% |

- **A "sell" is detected in `afterSwap`** from the real settled `BalanceDelta`: the token's delta
  is negative. So **exact-output sells are sized at their true amount**, not a worst-case guess
  (a limitation of `beforeSwap`-based fee overrides).
- Buys are never taxed.
- `BaseHookFee` takes the fraction of the swap's *unspecified* currency as an **ERC-6909 claim**
  held by the hook. Exact-in sells therefore accrue ETH-side claims; exact-out sells accrue
  token-side claims.
- Fee computation needs state writes, which `BaseHookFee._getHookFee` (a `view`) can't do, so the
  hook computes the fee in its own `_afterSwap`, stashes it, then calls `super._afterSwap`.

### Manipulation mitigations

- **Reserve inflation:** the reserve used for bracketing is the PoolManager's token balance,
  lagged by one block (`_snapshotReserve`), so adding tokens to the pool just before selling
  doesn't shrink the apparent sell size.
- **Split sells:** cumulative sold amount per `tx.origin` is tracked in transient storage within
  a transaction (`_accumulateSellAmount`), so splitting one big sell into many small swaps in the
  same tx still lands in the combined bracket.

## Fee flow: `harvest(uint256 minTokenOut)`

Collected claims sit in the hook until **anyone** calls `harvest(minTokenOut)`. This is
permissionless by design: destinations and ratios are owner-controlled, not caller-controlled, so
there is nothing to gain by calling it. Inside one `unlock`:

1. **Pull the standing bid** (if any) back: its liquidity is removed, whatever it holds (ETH,
   token, or a mix) is credited as claims.
2. **Carve `priceSupportBps`** off the ETH-denominated claims only (see below).
3. **Convert** the remaining ETH claims into the token via the same pool (funded by burning the
   claim), reverting with `InsufficientHarvestOutput` if output is below `minTokenOut`.
4. **Redeem** any token-denominated claims directly (burn the claim, then `take()`).
5. **Split** the real token balance: `burnBps` is burned (real `burn()`, reducing `totalSupply`),
   `treasuryBps` goes to `treasury`, the remainder (default ~10%, absorbing rounding dust) goes to
   `dev`. Emits `Harvested(total, burned, toTreasury, toDev)`.
6. **Re-mint a fresh bid** with the carved-out ETH.

The nested swap re-enters the hook's own `afterSwap` harmlessly: from the hook's side it's a buy,
which is never taxed.

### Price support: the standing bid

A `priceSupportBps` slice of ETH-denominated tax is parked as a resting, one-sided, ETH-only
concentrated-liquidity position just below spot. It only converts into the token passively, if the
market actually falls into it. This was chosen over "buyback + deposit as LP" to avoid adding to a
harvest-amplification feedback loop seen on testnet (a handful of sells ended in a burn of ~9.9%
of supply).

- Disabled by default (`priceSupportBps = 0`).
- Draws from **ETH-denominated tax only** (exact-in sells). Exact-out sells' tax is collected in
  the token with no ETH side, so a run of exact-out-only sells adds nothing to the bid that round.
  That is why it is its own knob rather than a fourth slice of `setSplit`'s ratio, which applies
  to a different base (the post-conversion token total).
- Range = current tick (via `StateLibrary.getSlot0`) offset by `bidTicksBelowSpot`, `bidWidthTicks`
  wide, aligned to tick spacing. Rounds-to-zero liquidity is skipped; the ETH just carries to the
  next harvest.
- Which raw tick direction is "below spot" depends on whether ETH sorted as `currency0` or
  `currency1` (fixed at pool creation). A one-sided position is pure token1 entirely below the
  price and pure token0 entirely above; a boundary landing *inside* the current tick would need
  both currencies and break settlement. See `_bidBoundsAt`.

## Owner-tunable parameters

| Function | Controls |
|---|---|
| `setBrackets(minSellBps[], feePpm[])` | Tax ladder. Thresholds must ascend; fee ≤ `MAX_HOOK_FEE` (1e6 ppm). |
| `setSplit(burnBps, treasuryBps)` | Burn / treasury ratio; dev gets the remainder. Reverts if sum > 10,000. Default 50/40/10. |
| `setPriceSupportBps(bps)` | Share of ETH-side tax diverted to the bid. ≤ 10,000. |
| `setBidRange(ticksBelowSpot, widthTicks)` | Bid placement. |
| `setTreasury(addr)` / `setDev(addr)` | Destinations. Zero address rejected. |
| `handleHookFees(Currency[])` | Owner-only escape hatch: redeems arbitrary claims straight to the owner. |

Ownership uses OpenZeppelin `Ownable`. The pool key is bound on `afterInitialize` and can only be
set once.

## Threat model & known limitations

Disclosed, not hidden:

- **`harvest()` sandwichability — mitigated, not eliminated.** Its internal conversion swap had no
  price limit; because `harvest()` is permissionless, anyone could skew price before calling it.
  `minTokenOut` is now required, so callers must pass a real quote minus tolerance (never `0`).
  A very large accrued fee harvested in one shot can still move price; batching would be needed at
  scale. Covered by `test_harvest_revertsWhenOutputBelowMinTokenOut`.
- **Reserve math is per-token, not per-pool.** Bracketing uses the PoolManager's *global* balance
  of the token across every pool it's in. Fine for a single-pool token (the intended setup); a trap
  if the same token is paired into several pools.
- **Mitigated, not eliminated:** reserve manipulation and cross-transaction split sells (the
  accumulator is per-transaction), plus the `tx.origin` / bundler conflation gap.
- **`treasury` and `dev` are plain owner-settable addresses** with no on-chain check that they are
  what they claim to be (e.g. that `treasury` is a compatible vault). A bad value leaves tokens
  inert there.
- **Redundant bid churn:** every `harvest()` pulls and re-mints the bid even if price hasn't
  moved. Safe, but wasteful gas.
- **Immutability:** deployed contracts can't be patched. An older Base Sepolia deployment of this
  hook predates the `minTokenOut` fix; fixes require a fresh deploy.
- **Unaudited.** Get a real audit before any real value touches it.

### Gotchas this code hit (worth not relearning)

- Redeeming a *pre-existing* ERC-6909 claim into real tokens requires **burning the claim first**
  (`settle(..., burn: true)`) and then `take()`. A bare `take()` only debits the transient delta,
  leaves the claim balance untouched, and reverts the call with `CurrencyNotSettled`.
- Test fixtures can't assume which currency sorts as `currency0`; helpers derive `zeroForOne`
  dynamically.
- `vm.prank` followed by an inline external-call argument consumes the prank on the inner call;
  compute such values into locals before pranking.
- If you add a one-sided position, write a test that actually *fills* it, not just mints and
  un-mints it.

## Repository layout

| Path | Contents |
|---|---|
| `src/GraduatedSellTaxTreasuryHook.sol` | The hook. |
| `src/mocks/TestERC20.sol` | Testnet-only burnable ERC-20 stand-in (unrestricted `mint`). |
| `test/GraduatedSellTaxTreasuryHook.t.sol` | 24 unit tests: brackets, exact-out sizing, mitigations, `harvest`, `setSplit`, standing bid, access control. |
| `test/GraduatedSellTaxTreasuryHook.invariant.t.sol` | 4 stateful invariants driven by a bounded `Handler` (128,000 calls each, with price support enabled). |
| `script/` | Base Sepolia deploy/interact scripts and `BaseSepoliaAddresses.sol`. |
| `lib/` | Submodules: `forge-std`, `uniswap-hooks` (which nests `v4-core`, `v4-periphery`, `openzeppelin-contracts`). |

The earlier, simpler LP-fee sibling hook (`GraduatedSellTaxHook`, where tax becomes extra LP fee)
is intentionally **not** in this repo.

## Build & test

```bash
git clone --recurse-submodules https://github.com/ToknWrks/magik-treasury-hook
cd magik-treasury-hook
forge build
forge test          # 28 tests (24 unit + 4 invariant); the invariant suite takes a couple of minutes
forge test -vvv     # traces
```

`foundry.toml` sets `bytecode_hash = "none"`, solc 0.8.26, optimizer 200 runs, `evm_version = "cancun"`.
`forge build` prints informational `forge-lint` notes; they don't fail the build.

## Deploying to Base Sepolia

Copy `.env.example` to `.env` and fill it in. `PRIVATE_KEY` should be a throwaway testnet key.
Every script must be run with `--broadcast` to send transactions, and each prints addresses to copy
back into `.env` before the next step:

```bash
set -a && source .env && set +a
forge script script/<Name>.s.sol --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast -vv
```

1. `DeployTreasuryToken.s.sol` → `TREASURY_TOKEN_ADDRESS` (burnable test token).
2. Deploy the treasury/vault (e.g. `magik-staking-vault`) → `VAULT_ADDRESS`. Any address works as
   `treasury`.
3. `DeployTreasuryHook.s.sol` → `TREASURY_HOOK_ADDRESS` (mines a CREATE2 salt for the
   `afterInitialize | afterSwap | afterSwapReturnDelta` flags; optional `PRICE_SUPPORT_BPS`,
   `BID_TICKS_BELOW_SPOT`, `BID_WIDTH_TICKS`).
4. `CreateTreasuryPoolAndAddLiquidity.s.sol` → initializes the ETH/token pool and seeds liquidity.
5. `TreasurySwapAndHarvest.s.sol` → sells (`SELL_AMOUNT_WEI`) then `harvest()` in one script.

Note: in `CreateTreasuryPoolAndAddLiquidity.s.sol`, `ETH_AMOUNT`/`TOKEN_AMOUNT` are *desired*
amounts fed to `LiquidityAmounts.getLiquidityForAmounts`; at a 1:1 start with a full-range position
the smaller side binds and the deposited amount can be far below the constant. Trust the script's
logged "held by PoolManager" output.

Contracts are immutable once deployed: editing the source doesn't fix a live instance (e.g. a token
deployed before it gained `ERC20Burnable` makes `harvest()` revert on `burn()` with an opaque error).

## License

SPDX identifier in all source files: `MIT`.
