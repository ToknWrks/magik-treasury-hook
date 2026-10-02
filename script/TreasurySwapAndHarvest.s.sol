// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TestERC20} from "../src/mocks/TestERC20.sol";
import {GraduatedSellTaxTreasuryHook} from "../src/GraduatedSellTaxTreasuryHook.sol";
import {BaseSepoliaAddresses} from "./BaseSepoliaAddresses.sol";

/// @notice Sells `SELL_AMOUNT_WEI` of tMAGIK into the treasury pool (collecting a real fee
/// claim), then calls `harvest()` to convert + burn/treasury/dev split it.
///
/// Usage: set TMAGIK_ADDRESS, TREASURY_HOOK_ADDRESS, SELL_AMOUNT_WEI in .env, then:
///   forge script script/TreasurySwapAndHarvest.s.sol --rpc-endpoint base_sepolia --broadcast -vvvv
contract TreasurySwapAndHarvestScript is Script {
    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function run() external {
        address token = vm.envAddress("TREASURY_TOKEN_ADDRESS");
        address hook = vm.envAddress("TREASURY_HOOK_ADDRESS");
        uint256 sellAmount = vm.envUint("SELL_AMOUNT_WEI");

        PoolSwapTest swapRouter = PoolSwapTest(BaseSepoliaAddresses.POOL_SWAP_TEST);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        TestERC20(token).approve(address(swapRouter), sellAmount);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, // tMAGIK (currency1) -> ETH (currency0) is the sell direction
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // 0 = no slippage protection — fine for this single-controlled-actor testnet script,
        // not for a real caller (see harvest()'s own comment).
        GraduatedSellTaxTreasuryHook(hook).harvest(0);

        vm.stopBroadcast();

        console2.log("Sold tMAGIK amount:", sellAmount);
    }
}
