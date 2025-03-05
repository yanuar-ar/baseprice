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

    error NotEnoughPriceChange(int24 currentTick, int24 triggerTick);

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

    uint256 public discoveryTokenId;
    int24 public discoveryTickLower;
    int24 public discoveryTickUpper;
    int24 public immutable DISCOVERY_TRIGGERED_TICK_LENGTH;

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

        // [1] Anchor and Discovery : collect fee and deposit to floor
        _collectFeeAndDepositToFloor(anchorTokenId);
        _collectFeeAndDepositToFloor(discoveryTokenId);

        // [2] Anchor : empty liquidity
        (, uint256 amount1) = _emptyLiquidity(anchorTokenId);

        // [3] Anchor surplus to Floor
        // cant further more than discoveryTickUpper
        if (currentTick > discoveryTickUpper) currentTick = discoveryTickUpper;
        uint24 furtherTick = uint24(currentTick) - uint24(discoveryTickLower); // skipped tick
        uint24 anchorTickLength = uint24(anchorTickUpper - anchorTickLower);
        uint256 anchorLiquiditySurplus = amount1 * uint256(uint24(furtherTick)) / anchorTickLength;

        // increase Floor liquidity
        _increaseLiquidity(floorTokenId, 0, anchorLiquiditySurplus);

        // [4] Discovery : empty liquidity]
        (, amount1) = _emptyLiquidity(discoveryTokenId);

        // [5] Discovery surplus to Floor
        // calculate Discovery surplus
        uint24 discoveryTickLength = uint24(discoveryTickUpper) - uint24(discoveryTickLower);
        uint256 discoveryLiquiditySurplus = amount1 * uint256(uint24(furtherTick)) / discoveryTickLength;

        _increaseLiquidity(floorTokenId, 0, discoveryLiquiditySurplus);

        // [6] mint Anchor and Discovery
        uint256 anchorAmount = IERC20(token1).balanceOf(address(this));
        _mintAnchorAndDiscovery(anchorAmount);

        // [7make zero approve
        IERC20(token0).approve(address(nonfungiblePositionManager), 0);
        IERC20(token1).approve(address(nonfungiblePositionManager), 0);
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
    }

    function _mintAnchorAndDiscovery(uint256 anchorAmount) internal {
        // anchor position
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
            amount1Min: anchorAmount,
            recipient: address(this),
            deadline: block.timestamp
        });

        IERC20(token0).approve(address(nonfungiblePositionManager), IERC20(token0).balanceOf(address(this)));
        IERC20(token1).approve(address(nonfungiblePositionManager), anchorAmount);
        (anchorTokenId,,,) = nonfungiblePositionManager.mint(mintAnchorParams);

        // discovery position

        discoveryTickLower = anchorTickUpper;
        discoveryTickUpper = discoveryTickLower + (DISCOVERY_LENGTH * TICK_SPACING);

        uint256 discoveryAmount = uint256(uint24(DISCOVERY_LENGTH)) * DISCOVERY_TOKEN_PER_TICK;

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

        IERC20(token0).approve(address(nonfungiblePositionManager), discoveryAmount);
        (discoveryTokenId,,,) = nonfungiblePositionManager.mint(mintDiscoveryParams);

        BaseToken(token0).burn(IERC20(baseToken).balanceOf(address(this)));
    }

    function _collectFeeAndDepositToFloor(uint256 tokenId) internal {
        (uint256 amount0, uint256 amount1) = _collect(tokenId);
        _increaseLiquidity(floorTokenId, 0, amount1);
    }

    function _emptyLiquidity(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (,,,,,,, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(tokenId);
        (amount0, amount1) = _decreaseLiquidity(tokenId, liquidity);
        _collect(tokenId);
    }

    function _increaseLiquidity(uint256 tokenId, uint256 amount0Desired, uint256 amount1Desired) internal {
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
