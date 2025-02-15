// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BasePrice {
    // 1 kali bump sama dengan 1000 tick
    uint256 public constant BUMP_TICK = 1000;

    // 1 kali sweep sama dengan 1000 tick
    uint256 public constant SWEEP_TICK = 1000;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    // liquidity
    address public weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public usdc = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    uint24 public feeTier = 3000;

    // floor
    int24 public floorLowerTick;
    int24 public floorUpperTick;
    uint256 public floorTokenId;

    // discovery
    int24 public discoveryLowerTick;
    int24 public discoveryUpperTick;
    uint256 public discoveryTokenId;

    constructor(
        int24 initialFloorLowerTick,
        int24 initialFloorUpperTick,
        int24 initialDiscoveryLowerTick,
        int24 initialDiscoveryUpperTick
    ) {
        floorLowerTick = initialFloorLowerTick; // -207240
        floorUpperTick = initialFloorUpperTick; // -207180
        discoveryLowerTick = initialDiscoveryLowerTick; // -191150
        discoveryUpperTick = initialDiscoveryUpperTick; // -191140
    }

    function mintFloor(uint256 amount) public {
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);

        // jika belum ada posisi ya gak perlu collect dan withdraw
        if (floorTokenId != 0) {
            // collect dulu
            nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: floorTokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            // withdraw semua
            (,,,,,,, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(floorTokenId);

            nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: floorTokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );

            // burn
            // nonfungiblePositionManager.burn(floorTokenId);
        }

        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: weth,
            token1: usdc,
            fee: feeTier,
            tickLower: floorLowerTick,
            tickUpper: floorUpperTick,
            amount0Desired: 0,
            amount1Desired: usdcBalance,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
        IERC20(usdc).approve(address(nonfungiblePositionManager), usdcBalance);
        (uint256 tokenId,,,) = nonfungiblePositionManager.mint(params);

        floorTokenId = tokenId;
    }

    function mintDiscovery(uint256 amount) public {
        IERC20(weth).transferFrom(msg.sender, address(this), amount);

        // jika belum ada posisi ya gak perlu collect dan withdraw
        if (discoveryTokenId != 0) {
            // collect dulu
            nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: discoveryTokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            // withdraw semua
            (,,,,,,, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(discoveryTokenId);

            nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: discoveryTokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );

            // burn
            // nonfungiblePositionManager.burn(floorTokenId);
        }

        uint256 wethBalance = IERC20(weth).balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: weth,
            token1: usdc,
            fee: feeTier,
            tickLower: discoveryLowerTick,
            tickUpper: discoveryUpperTick,
            amount0Desired: wethBalance,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
        IERC20(weth).approve(address(nonfungiblePositionManager), wethBalance);
        (uint256 tokenId,,,) = nonfungiblePositionManager.mint(params);

        discoveryTokenId = tokenId;
    }
}
