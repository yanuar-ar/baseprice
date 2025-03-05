// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {BasePrice} from "../src/BasePrice.sol";
import {BaseToken} from "../src/BaseToken.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract BasePriceTest is Test {
    address nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    ISwapRouter public swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    MockUSDC public usdc;
    BaseToken public baseToken;
    BasePrice public basePrice;
    address expectedBaseTokenAddress;
    address expectedBasePriceAddress;

    function setUp() public {
        vm.createSelectFork("https://arb-mainnet.g.alchemy.com/v2/IpWFQVx6ZTeZyG85llRd7h6qRRNMqErS", 312501782);

        usdc = new MockUSDC();

        uint64 nonce = vm.getNonce(address(this));
        expectedBaseTokenAddress = computeCreateAddress(address(this), nonce);
        expectedBasePriceAddress = computeCreateAddress(address(this), nonce + 1);

        baseToken = new BaseToken("BaseToken", "BASET", expectedBasePriceAddress);
        vm.setNonce(address(this), nonce + 1);
        basePrice = new BasePrice(address(baseToken), address(usdc), nonfungiblePositionManager);

        // +++ SCENARIO +++
        // current Price = 1 USDC
        // floor price =  0.2 USDC
        // floor amount = 1000e6 USDC
        // anchor amount = 100e6 USDC

        uint160 sqrtPriceX96 = PriceMath.priceToSqrtPriceX96(1e6, 18);

        uint160 floorSqrtPriceX96 = PriceMath.priceToSqrtPriceX96(0.2e6, 18);
        int24 unnormalizedFloorTick = TickMath.getTickAtSqrtRatio(floorSqrtPriceX96);
        int24 floorTick = unnormalizedFloorTick / basePrice.TICK_SPACING() * basePrice.TICK_SPACING();

        usdc.mint(address(this), 1100e6);
        IERC20(usdc).approve(address(basePrice), 1100e6);
        basePrice.initPoolAndPosition(sqrtPriceX96, floorTick, 1000e6, 100e6);
    }

    function test_deploy() public {
        assertEq(address(baseToken), expectedBaseTokenAddress);
        assertEq(address(basePrice), expectedBasePriceAddress);
    }

    function test_sweep() public {
        console.log("before getCurrentTick", basePrice.getCurrentTick());
        console.log("before floorTickLower", basePrice.floorTickLower());
        console.log("before floorTickUpper", basePrice.floorTickUpper());
        console.log("before anchorTickLower", basePrice.anchorTickLower());
        console.log("before anchorTickUpper", basePrice.anchorTickUpper());
        console.log("before discoveryTickLower", basePrice.discoveryTickLower());
        console.log("before discoveryTickUpper", basePrice.discoveryTickUpper());

        usdc.mint(address(this), 1100e6);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(baseToken),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: 600e6,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        IERC20(usdc).approve(address(swapRouter), 750e6);
        swapRouter.exactInputSingle(params);

        assertGt(
            basePrice.getCurrentTick(), basePrice.discoveryTickLower() + basePrice.DISCOVERY_TRIGGERED_TICK_LENGTH()
        );

        basePrice.sweep();

        console.log("after getCurrentTick", basePrice.getCurrentTick());
        console.log("after floorTickLower", basePrice.floorTickLower());
        console.log("after floorTickUpper", basePrice.floorTickUpper());
        console.log("after anchorTickLower", basePrice.anchorTickLower());
        console.log("after anchorTickUpper", basePrice.anchorTickUpper());
        console.log("after discoveryTickLower", basePrice.discoveryTickLower());
        console.log("after discoveryTickUpper", basePrice.discoveryTickUpper());
    }
}
