//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrderBookHook} from "src/OrderBookHook.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "@uniswap/v4-core/lib/forge-gas-snapshot/lib/forge-std/src/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {console} from "forge-std/console.sol";

contract OrderBookHookTest is Test, Deployers, ERC1155Holder {
    OrderBookHook orderBookContract;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    Currency token0;
    Currency token1;

    uint24 gasFee = 3000;
    int24 tickLower1 = -60;
    int24 tickUpper1 = 60;
    int24 tickLower2 = -120;
    int24 tickUpper2 = 120;
    int256 liquidityDelta = 10 ether;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address orderBookHookAddress = address(flags);
        deployCodeTo(
            "OrderBookHook.sol",
            abi.encode(manager, ""),
            orderBookHookAddress
        );
        orderBookContract = OrderBookHook(orderBookHookAddress);
        MockERC20(Currency.unwrap(token0)).approve(
            address(orderBookContract),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(orderBookContract),
            type(uint256).max
        );

        (key, ) = initPool(
            token0,
            token1,
            orderBookContract,
            gasFee,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower1,
                tickUpper: tickUpper1,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower2,
                tickUpper: tickUpper2,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(tickUpper1),
                tickUpper: TickMath.maxUsableTick(tickUpper1),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function test_placeAnOrder() public {
        int24 tickToSellAt = 100;
        int24 tickSpacing = 60;
        bool zeroForOne = true;
        uint256 inputAmount = 1 ether;

        uint256 balanceBeforeOrder = token0.balanceOfSelf();

        int24 actualTick = orderBookContract.placeOrder(
            key,
            tickToSellAt,
            tickSpacing,
            zeroForOne,
            inputAmount
        );
        uint256 balanceAfterOrder = token0.balanceOfSelf();
        uint256 positionId = orderBookContract._getPositionId(
            key,
            actualTick,
            zeroForOne
        );
        uint256 claimTokenEquivalent = orderBookContract.balanceOf(
            address(this),
            positionId
        );
        uint256 expectedInputAmount = orderBookContract.claimTokensSupply(
            positionId
        );
        assertEq(balanceBeforeOrder - balanceAfterOrder, inputAmount);
        assertEq(inputAmount, claimTokenEquivalent);
        assertEq(expectedInputAmount, inputAmount);
    }

    function test_placeAnOrderAndCancel() public {
        int24 tickToSellAt = 100;
        bool zeroForOne = true;
        test_placeAnOrder();
        uint256 amountToCancel = 0.5 ether;

        uint256 positionId = orderBookContract._getPositionId(
            key,
            60,
            zeroForOne
        );
        uint256 claimTokensSupplyBeforeCancelling = orderBookContract
            .claimTokensSupply(positionId);
        uint256 token0BalanceBeforeCancelling = token0.balanceOfSelf();
        uint256 claimTokenBalanceBeforeCancelling = orderBookContract.balanceOf(
            address(this),
            positionId
        );

        orderBookContract.cancelOrder(
            key,
            tickToSellAt,
            zeroForOne,
            amountToCancel
        );
        uint256 claimTokensSupplyAfterCancelling = orderBookContract
            .claimTokensSupply(positionId);
        uint256 token0BalanceAfterCancelling = token0.balanceOfSelf();
        uint256 claimTokenBalanceAfterCancelling = orderBookContract.balanceOf(
            address(this),
            positionId
        );

        assertEq(
            claimTokensSupplyBeforeCancelling -
                claimTokensSupplyAfterCancelling,
            1 ether
        );
        assertEq(
            token0BalanceAfterCancelling - token0BalanceBeforeCancelling,
            1 ether
        );
        assertEq(
            claimTokenBalanceBeforeCancelling -
                claimTokenBalanceAfterCancelling,
            1 ether
        );
    }

    function test_executeOrder_forZeroForOne() public {
        test_placeAnOrder();
        bool zeroForOne = true;
        int256 amountSepcified = 1 ether;
        int24 tickToSellAt = 100;
        uint256 positionId = orderBookContract._getPositionId(
            key,
            tickUpper1,
            zeroForOne
        );
        uint256 initialClaimTokenBalance = orderBookContract.balanceOf(
            address(this),
            positionId
        );

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -amountSepcified,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory test = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        uint256 token1BalanceBeforeSwap = MockERC20(Currency.unwrap(token1))
            .balanceOf(address(this));
        console.log("token1BalanceBefore:", token1BalanceBeforeSwap);

        swapRouter.swap(key, params, test, ZERO_BYTES);

        orderBookContract.redeemSwappeTokens(
            key,
            tickToSellAt,
            zeroForOne,
            uint256(amountSepcified)
        );
        uint256 token1BalanceAfter = MockERC20(Currency.unwrap(token1))
            .balanceOf(address(this));

        console.log("token1BalanceAfter:", token1BalanceAfter);

        uint256 claimTokenBalanceAfterRedemption = orderBookContract.balanceOf(
            address(this),
            positionId
        );
        assertEq(
            initialClaimTokenBalance - claimTokenBalanceAfterRedemption,
            uint256(amountSepcified)
        );
        assertEq(token1BalanceAfter, token1BalanceBeforeSwap);
    }

    function test_executeOrder_forOneForZero() public {
        bool _zeroForOne = false;
        int24 tickToSellAt = 100;
        int24 tickSpacing = 60;
        uint256 inputAmount = 1 ether;
        orderBookContract.placeOrder(
            key,
            tickToSellAt,
            tickSpacing,
            _zeroForOne,
            inputAmount
        );
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !_zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory test = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(key, params, test, ZERO_BYTES);
        orderBookContract.redeemSwappeTokens(
            key,
            tickToSellAt,
            _zeroForOne,
            inputAmount
        );
    }
}
