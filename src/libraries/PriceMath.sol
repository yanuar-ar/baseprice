// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.17;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

library PriceMath {
    function sqrtPriceX96toPrice(uint256 sqrtPriceX96, uint8 token0Decimals) external pure returns (uint256) {
        // reference https://ethereum.stackexchange.com/questions/98685/computing-the-uniswap-v3-pair-price-from-q64-96-number
        // uint256 sqrtPriceX96 = 3592095024408263703440281;
        // uint8 token0Decimals = 18;

        // price
        return (sqrtPriceX96 * sqrtPriceX96 * (10 ** token0Decimals)) >> (192);
    }

    function priceToSqrtPriceX96(uint256 price, uint256 token0Decimals) external pure returns (uint160) {
        uint256 numerator = price * (1 << 192); // price * 2^192
        uint256 adjustedPrice = numerator / (10 ** token0Decimals);
        return uint160(FixedPointMathLib.sqrt(adjustedPrice));
    }
}
