// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TestERC20} from "../src/mocks/TestERC20.sol";

/// @notice Deploys a fresh, burnable tMAGIK for the treasury-hook ecosystem. Separate from the
/// tMAGIK used by the LP-fee hook, which was deployed before `TestERC20` gained `ERC20Burnable` --
/// that older token has no `burn()`, and `GraduatedSellTaxTreasuryHook.harvest()` requires one.
///
/// Usage: forge script script/DeployTreasuryToken.s.sol --rpc-endpoint base_sepolia --broadcast -vvvv
contract DeployTreasuryTokenScript is Script {
    function run() external returns (TestERC20 token) {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        token = new TestERC20("Testnet Magik (Treasury)", "tMAGIK2", 1_000_000e18, deployer);
        vm.stopBroadcast();

        console2.log("tMAGIK2 token:", address(token));
    }
}
