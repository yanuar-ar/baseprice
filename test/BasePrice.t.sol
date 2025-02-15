// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {BasePrice} from "../src/BasePrice.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BasePriceTest is Test {
    address public weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public usdc = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

    BasePrice public basePrice;

    function setUp() public {
        vm.createSelectFork("https://arb-mainnet.g.alchemy.com/v2/Ea4M-V84UObD22z2nNlwDD9qP8eqZuSI", 306368675);
        basePrice = new BasePrice(int24(-207240), int24(-207180));
        deal(usdc, address(this), 2000e6);
    }

    function test_floor() public {
        IERC20(usdc).approve(address(basePrice), 1000e6);

        // skenario 1: mint pertama
        basePrice.mintFloor(1000e6);
        // floorTokendId tidak boleh 0
        assertNotEq(basePrice.floorTokenId(), 0);
        console.log("floorTokenId", basePrice.floorTokenId());

        // skenario 2: mint kedua misal dapat 1000e6 dari treasury
        uint256 floorTokenIdBefore = basePrice.floorTokenId();
        IERC20(usdc).approve(address(basePrice), 1000e6);
        basePrice.mintFloor(1000e6);

        // floorTokendId tidak boleh sama dengan sebelumnya
        assertNotEq(basePrice.floorTokenId(), floorTokenIdBefore);
        console.log("floorTokenId", basePrice.floorTokenId());
    }
}
