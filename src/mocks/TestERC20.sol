// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice Testnet-only stand-in for the real project token. Unrestricted `mint` —
/// never deploy this to a network where the token is expected to have real value.
/// `ERC20Burnable` gives it real `burn`/`burnFrom` since the treasury hook needs to
/// actually burn its share, not just move it to a dead address.
contract TestERC20 is ERC20, ERC20Burnable {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address recipient)
        ERC20(name_, symbol_)
    {
        _mint(recipient, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
