# D-01 — Morpheus Distributor Donation Attack (Yield Inflation) — PoC

Foundry proof-of-concept for a High-severity issue in the Morpheus
`Distributor` contract (Ethereum Mainnet): `distributeRewards()` measures
yield as the raw `balanceOf` delta of the yield token against
`lastUnderlyingBalance`, without checking where the balance increase came
from. Anyone can donate aTokens to the Distributor (e.g. via
`Aave Pool.supply(token, amount, distributor, 0)`), and the donation is
credited as yield at the next `distributeRewards()` call. Because MOR
emission per period is fixed and much larger than honest yield, the donation
shifts emission share toward the donated pool, letting the attacker capture
extra MOR at the expense of honest stakers in other pools.

**Local mainnet fork only.** No mainnet/testnet transactions, no real funds,
no private keys.

## Target (Ethereum Mainnet, Morpheus bug bounty Appendix A)

| Contract | Address |
|---|---|
| Distributor (ERC1967 proxy, `DistributorV2`) | `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A` |
| DepositPool USDT | `0x3B51989212BEdaB926794D6bf8e9E991218cf116` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| aUSDT | `0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a` |
| Aave Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |

Fork pinned to block **26427438** (2026-11-16). MOR price used for USD
figures: **$0.7175** (CoinGecko, 2026-11-16).

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`)
- An Ethereum RPC URL with archive state at block 26427438, e.g.
  `https://eth.drpc.org` (the only free public RPC that served archive state
  for this block when tested; `eth.llamarpc.com`, `cloudflare-eth.com`,
  `rpc.ankr.com/eth`, `ethereum.publicnode.com` failed or required a key)

`forge-std` is vendored under `lib/` so the test runs straight from a clean
clone — no `forge install` needed.

## Run (one command)

```bash
MAINNET_RPC_URL=https://eth.drpc.org forge test --match-contract DistributorDonationTest
```

## Expected results (4 passed, 0 failed)

| Test | What it proves |
|---|---|
| `testControl` | Honest baseline: attacker with ~50% virtual share and **no** donation captures only 1,453 MOR over 15 days; claim, sweep and withdraw work normally |
| `testAttackF05` | Donation of $3,464 → attacker captures **17,531 MOR** (vs 1,453 control); fork profit ~$8,072/cycle |
| `testAttackF09` | Donation of $6,370 → attacker captures **34,578 MOR**; fork profit ~$16,563/cycle |
| `testOracleStalenessForkArtifact` | Without the Chainlink freshness mock, `distributeRewards` reverts after the warp (pure fork artifact, documented below) |

## Realistic mainnet figures (fork numbers are an upper bound)

The fork understates honest yield `T` (stETH rebase and Aave interest in other
reserves do not accrue without on-chain interaction at the pinned block), so
fork profit overstates mainnet profit. Honest yield measured from on-chain
state across two blocks ~1 day apart: **T15 ≈ $7,105** (stETH rebase 2.38% APR
dominates). With R15 = 42,783 MOR ≈ $30,697 emission per 15-day cycle:

| Scenario | Stake | Donation | MOR captured | Net profit / 15-day cycle |
|---|---|---|---|---|
| f ≈ 0.5 | 36,729 USDT | $3,464 | ~7,011 MOR | **~$1,567** |
| f ≈ 0.9 | 330,564 USDT | $6,370 | ~18,203 MOR | **~$6,690** |

Formula: captured ≈ f·R·X/(T+X); profit = captured·$0.7175 − donation.
Realistic run-rate ≈ **$38k–$163k/year**; the program's High threshold
($10,000) is passed in ~2–7 cycles. The attack repeats every 15 days and the
stake is returned in full after the 7-day lock. Victims: honest stakers in
other pools, whose MOR emission share is stolen (per-period emission is
zero-sum).

## Methodology notes / caveats

1. **Chainlink freshness mock (fork artifact only):** after `vm.warp(+15 days)`
   the pinned-block feed data is stale (allowed delays 3600s/86400s) and
   `updateDepositTokensPrices()` reverts `DR: price for pair is zero`. On
   mainnet feeds update continuously, so this never happens. The mock only
   refreshes `updatedAt` to the warped timestamp; the price **answers** are
   the real fork-block values, unchanged. No Morpheus contract logic is
   touched.
2. **`vm.warp` stands in for the attacker simply waiting 15 days on mainnet**
   (14-day claim lock + 1-day minimum distribute period).
3. **Claim goes through LayerZero `EndpointV1.send` on the fork** and
   succeeds; the test contract needs a `receive()` because LayerZero refunds
   excess native fee (~0.0494 ETH) to the caller — a test artifact, not a
   protocol failure (an EOA attacker receives the refund normally).
4. **USDT quirk:** Tether's `approve`/`transfer` return no data, so the test
   declares them without a return value (Morpheus uses SafeERC20 for the same
   reason).
5. **Stake approval:** `Distributor.supply()` pulls tokens from the staker, so
   the Distributor (not only the DepositPool) needs allowance; the test
   approves both.
6. USD figures use spot MOR $0.7175; on-chain MOR liquidity is thin
   (~$7,982 Uniswap pool), so selling 17–35k MOR at once would move the
   price. Token amounts are unaffected by slippage.
