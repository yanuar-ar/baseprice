// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseToken} from "./BaseToken.sol";
import {TickMath} from "./libraries/TickMath.sol";

contract BasePrice {
    using SafeERC20 for IERC20;

    event MintAnchor(uint256 anchorTokenId, int24 anchorTickLower, int24 anchorTickUpper);
    event MintDiscovery(uint256 discoveryTokenId, int24 discoveryTickLower, int24 discoveryTickUpper);
    event MintFloor(uint256 floorTokenId, int24 floorTickLower, int24 floorTickUpper);

    error NotEnoughPriceChange(int24 currentTick, int24 triggerTick);
    error AnchorAndDiscoveryOverlap(int24 anchorTickUpper, int24 discoveryTickLower);
    // uniswap v3

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    // positions
    int24 public immutable ANCHOR_LEFT_LENGTH;
    int24 public immutable ANCHOR_RIGHT_LENGTH;
    int24 public immutable DISCOVERY_LENGTH;
    uint256 public immutable DISCOVERY_TOKEN_PER_TICK;

    // position configs
    int24 public snapshotMarketTick;
    uint256 public floorTokenId;
    uint256 public initialFloorAmount;
    int24 public floorTickLower;
    int24 public floorTickUpper;

    uint256 public anchorTokenId;
    int24 public anchorTickLower;
    int24 public anchorTickUpper;
    int24 public immutable ANCHOR_TRIGGERED_TICK_LENGTH;

    uint256 public discoveryTokenId;
    int24 public discoveryTickLower;
    int24 public discoveryTickUpper;
    int24 public immutable DISCOVERY_TRIGGERED_TICK_LENGTH;

    // strategy
    uint256 public lastDropTimestamp;
    int24 public immutable DROP_TRIGGERED_TICK_LENGTH;

    // pool configs
    address public pool;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable UNISWAP_FEE_TIER;
    int24 public immutable TICK_SPACING;

    IERC20 public immutable baseToken;

    constructor(address _baseToken, address _token1, address _nonfungiblePositionManager) {
        token0 = _baseToken;
        token1 = _token1;
        baseToken = IERC20(_baseToken);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager); // 0xC36442b4a4522E871399CD717aBDD847Ab11FE88

        //TODO: make it constructor
        ANCHOR_LEFT_LENGTH = 20;
        ANCHOR_RIGHT_LENGTH = 20;
        DISCOVERY_LENGTH = 20;
        UNISWAP_FEE_TIER = 3000;
        TICK_SPACING = 60;
        DISCOVERY_TOKEN_PER_TICK = 100e18;

        DISCOVERY_TRIGGERED_TICK_LENGTH = 240; // 2,4%
        ANCHOR_TRIGGERED_TICK_LENGTH = 200; // 2%
        DROP_TRIGGERED_TICK_LENGTH = 2000; // 20%
    }

    function initPoolAndPosition(uint160 sqrtPriceX96, int24 floorTick, uint256 floorAmount, uint256 anchorAmount)
        external
    {
        uint256 totalToken1Amount = floorAmount + anchorAmount;
        IERC20(token1).safeTransferFrom(msg.sender, address(this), totalToken1Amount);

        // [1] create and init pool
        pool = nonfungiblePositionManager.createAndInitializePoolIfNecessary(
            token0, token1, UNISWAP_FEE_TIER, sqrtPriceX96
        );

        // [2] mint floor
        _mintFloor(floorAmount, floorTick);

        // [3] mint anchor and discovery
        _mintAnchorAndDiscovery(anchorAmount);

        // [4] zero approve
        IERC20(token0).approve(address(nonfungiblePositionManager), 0);
        IERC20(token1).approve(address(nonfungiblePositionManager), 0);
    }

    function sweep() external {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 triggerTick = discoveryTickLower + DISCOVERY_TRIGGERED_TICK_LENGTH;

        if (currentTick < triggerTick) revert NotEnoughPriceChange(currentTick, triggerTick);

        // [1] Anchor and Discovery : collect fee as surplus
        (, uint256 collectedAmount1Anchor) = _collect(anchorTokenId);
        (, uint256 collectedAmount1Discovery) = _collect(discoveryTokenId);

        // [2] Anchor : empty liquidity
        (, uint256 liquidityAmount1Anchor) = _emptyLiquidity(anchorTokenId);

        // [3] Anchor : calculate surplus
        // can't further more than discoveryTickUpper
        if (currentTick > discoveryTickUpper) currentTick = discoveryTickUpper;
        uint24 furtherTick = uint24(currentTick) - uint24(discoveryTickLower); // skipped tick from discoveryTickLower
        uint24 anchorTickLength = uint24(anchorTickUpper - anchorTickLower);
        uint256 anchorLiquiditySurplus = liquidityAmount1Anchor * uint256(uint24(furtherTick)) / anchorTickLength;

        // [4] Increase Floor liquidity with surplus
        uint256 totalSurplus = collectedAmount1Anchor + collectedAmount1Discovery + anchorLiquiditySurplus;
        _increaseLiquidity(floorTokenId, 0, totalSurplus);

        // [5] Discovery : empty liquidity
        _emptyLiquidity(discoveryTokenId);

        // [6] mint Anchor and Discovery
        uint256 token1Balance = IERC20(token1).balanceOf(address(this));
        _mintAnchorAndDiscovery(token1Balance);

        // [7make zero approve
        IERC20(token0).approve(address(nonfungiblePositionManager), 0);
        IERC20(token1).approve(address(nonfungiblePositionManager), 0);
    }

    function slide() external {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 triggerTick = snapshotMarketTick - ANCHOR_TRIGGERED_TICK_LENGTH;
        if (currentTick >= triggerTick) revert NotEnoughPriceChange(currentTick, triggerTick);

        // [1] Anchor : empty liquidity
        _emptyLiquidity(anchorTokenId);

        // [2] Anchor : calculate surplus
        uint256 token1Balance = IERC20(token1).balanceOf(address(this));
        _mintAnchor(token1Balance);

        // [3] make zero approve
        IERC20(token0).approve(address(nonfungiblePositionManager), 0);
        IERC20(token1).approve(address(nonfungiblePositionManager), 0);
    }

    function drop() external {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 triggerTick = discoveryTickLower - DROP_TRIGGERED_TICK_LENGTH;
        if (currentTick >= triggerTick) revert NotEnoughPriceChange(currentTick, triggerTick);

        // [1] Discovery : empty liquidity
        _emptyLiquidity(discoveryTokenId);

        // [2] Discovery : calculate surplus
        _mintDiscovery();

        // [3] Anchor and Discovery : check overlap
        // if (discoveryTickLower <= anchorTickUpper) {
        //     revert AnchorAndDiscoveryOverlap(anchorTickUpper, discoveryTickLower);
        // }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                     Read Functions                                        //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function getCurrentTick() public view returns (int24) {
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        return currentTick;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   Internal Functions                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _mintAnchorAndDiscovery(uint256 anchorAmount) internal {
        _mintAnchor(anchorAmount);
        _mintDiscovery();
    }

    function _mintFloor(uint256 floorAmount, int24 floorTick) internal {
        floorTickLower = floorTick;
        floorTickUpper = floorTick + int24(TICK_SPACING);

        // floor position
        INonfungiblePositionManager.MintParams memory floorMintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: UNISWAP_FEE_TIER,
            tickLower: floorTickLower,
            tickUpper: floorTickUpper,
            amount0Desired: 0,
            amount1Desired: floorAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        initialFloorAmount = floorAmount;
        IERC20(token1).approve(address(nonfungiblePositionManager), floorAmount);
        (floorTokenId,,,) = nonfungiblePositionManager.mint(floorMintParams);

        emit MintFloor(floorTokenId, floorTickLower, floorTickUpper);
    }

    function _mintAnchor(uint256 anchorAmount) internal {
        // max mint
        uint256 maxMint = type(uint128).max - IERC20(token0).totalSupply();
        BaseToken(token0).mint(address(this), maxMint);

        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        // take snapshot of current tick
        snapshotMarketTick = currentTick;

        int24 liquidityTick = (currentTick / TICK_SPACING) * TICK_SPACING;
        anchorTickLower = liquidityTick - (ANCHOR_LEFT_LENGTH * TICK_SPACING);
        anchorTickUpper = liquidityTick + (ANCHOR_RIGHT_LENGTH * TICK_SPACING);

        INonfungiblePositionManager.MintParams memory mintAnchorParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: UNISWAP_FEE_TIER,
            tickLower: anchorTickLower,
            tickUpper: anchorTickUpper,
            amount0Desired: IERC20(token0).balanceOf(address(this)),
            amount1Desired: anchorAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        IERC20(token0).approve(address(nonfungiblePositionManager), IERC20(token0).balanceOf(address(this)));
        IERC20(token1).approve(address(nonfungiblePositionManager), anchorAmount);
        (anchorTokenId,,,) = nonfungiblePositionManager.mint(mintAnchorParams);

        BaseToken(token0).burn(IERC20(baseToken).balanceOf(address(this)));

        emit MintAnchor(anchorTokenId, anchorTickLower, anchorTickUpper);
    }

    function _mintDiscovery() internal {
        discoveryTickLower = anchorTickUpper;
        discoveryTickUpper = discoveryTickLower + (DISCOVERY_LENGTH * TICK_SPACING);

        uint256 discoveryAmount = uint256(uint24(DISCOVERY_LENGTH)) * DISCOVERY_TOKEN_PER_TICK;
        uint256 mustMintedAmount = discoveryAmount - IERC20(token0).balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory mintDiscoveryParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: UNISWAP_FEE_TIER,
            tickLower: discoveryTickLower,
            tickUpper: discoveryTickUpper,
            amount0Desired: discoveryAmount,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        BaseToken(token0).mint(address(this), mustMintedAmount);
        IERC20(token0).approve(address(nonfungiblePositionManager), discoveryAmount);
        (discoveryTokenId,,,) = nonfungiblePositionManager.mint(mintDiscoveryParams);
        BaseToken(token0).burn(IERC20(baseToken).balanceOf(address(this)));

        emit MintDiscovery(discoveryTokenId, discoveryTickLower, discoveryTickUpper);
    }

    function _emptyLiquidity(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (,,,,,,, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
        (amount0, amount1) = _decreaseLiquidity(tokenId, liquidity);
        _collect(tokenId);
        // burn position
        nonfungiblePositionManager.burn(tokenId);
    }

    function _increaseLiquidity(uint256 tokenId, uint256 amount0Desired, uint256 amount1Desired) internal {
        IERC20(token1).approve(address(nonfungiblePositionManager), amount0Desired);
        IERC20(token1).approve(address(nonfungiblePositionManager), amount1Desired);
        nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _collect(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }
}
