// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BaseToken is ERC20 {
    error BasePriceAddressCannotBeZero();
    error OnlyBasePriceCanMint();
    error InsufficientBalance();

    address public basePrice;

    constructor(string memory name, string memory symbol, address _basePrice) ERC20(name, symbol) {
        if (_basePrice == address(0)) revert BasePriceAddressCannotBeZero();
        basePrice = _basePrice;
    }

    function mint(address to, uint256 amount) public {
        if (msg.sender != basePrice) revert OnlyBasePriceCanMint();
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _burn(msg.sender, amount);
    }
}
