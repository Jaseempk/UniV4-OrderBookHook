//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title OrderBookHook
 * @notice A hook for Uniswap V4 that implements an order book functionality
 * @dev This contract allows users to place limit orders on Uniswap V4 pools
 */
contract OrderBookHook is BaseHook, ERC1155 {
    //Custom Errors
    error OBH__NoClaimableOutputTokenAvailable();
    error OBH__InsufficientInputBalanceToRedeem();
    error OBH__OverKillNotEnoughInputFoundInPM();

    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    /// @notice Stores pending orders for each pool, tick, and direction
    mapping(PoolId => mapping(int24 => mapping(bool => uint256)))
        public pendingOrders;

    /// @notice Tracks the supply of claim tokens for each position
    mapping(uint256 _positionId => uint256 _inputTokens)
        public claimTokensSupply;

    /// @notice Tracks the claimable output tokens for each position
    mapping(uint256 positionId => uint256) public claimableOutputTokens;

    /// @notice Stores the last tick for each pool
    mapping(PoolId => int24 lastTick) public lastTicks;

    /// @notice Emitted when an order is cancelled
    event OrderCancelled(
        PoolKey key,
        int24 tick,
        bool zeroForOne,
        address caller
    );

    /**
     * @notice Constructor for OrderBookHook
     * @param manager The address of the Uniswap V4 pool manager
     * @param uri The URI for the ERC1155 tokens
     */
    constructor(
        IPoolManager manager,
        string memory uri
    ) BaseHook(manager) ERC1155(uri) {}

    /**
     * @notice Returns the hook's permissions
     * @return Hooks.Permissions The permissions for this hook
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @notice Places a limit order
     * @param key The pool key
     * @param tickToSellAt The tick at which to sell
     * @param tickSpacing The tick spacing of the pool
     * @param zeroForOne Whether the order is selling token0 for token1
     * @param inputAmount The amount of input tokens to sell
     * @return The actual tick at which the order was placed
     */
    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        int24 tickSpacing,
        bool zeroForOne,
        uint256 inputAmount
    ) public returns (int24) {
        int24 tick = _validTickToSwapAt(tickToSellAt, tickSpacing);

        //Holds the pending order inputToken's value for this particular tick & id
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        console.log(
            "inputAmountaaaaa:",
            pendingOrders[key.toId()][tick][zeroForOne]
        );

        //This is an identifier for orders with this key,tick & zeroForOne
        uint256 positionId = _getPositionId(key, tick, zeroForOne);

        claimTokensSupply[positionId] += inputAmount;

        _mint(msg.sender, positionId, inputAmount, "");

        //If zeroForOne is true then the token will be ETH in this case as this involves ETH pair,
        //in other cases it differs based on the context of address values
        address token = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        IERC20(token).transferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }

    /**
     * @notice Cancels an existing order
     * @param key The pool key
     * @param tickToSellAt The tick at which the order was placed
     * @param zeroForOne Whether the order is selling token0 for token1
     * @param amountToCancel The amount of the order to cancel
     */
    function cancelOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 amountToCancel
    ) public {
        int24 tick = _validTickToSwapAt(tickToSellAt, key.tickSpacing);

        uint256 positionId = _getPositionId(key, tick, zeroForOne);

        uint256 tokenAmount = balanceOf(msg.sender, positionId);
        if (amountToCancel > tokenAmount)
            revert OBH__OverKillNotEnoughInputFoundInPM();

        claimTokensSupply[positionId] -= amountToCancel;

        _burn(msg.sender, positionId, amountToCancel);

        Currency tokenToSend = zeroForOne ? key.currency0 : key.currency1;

        tokenToSend.transfer(msg.sender, amountToCancel);
        emit OrderCancelled(key, tick, zeroForOne, msg.sender);
    }

    /**
     * @notice Redeems swapped tokens for a filled order
     * @param key The pool key
     * @param tickToSellAt The tick at which the order was placed
     * @param zeroForOne Whether the order was selling token0 for token1
     * @param inputAmountToClaimFor The amount of input tokens to claim for
     */
    function redeemSwappeTokens(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) public {
        int24 tick = _validTickToSwapAt(tickToSellAt, key.tickSpacing);

        uint256 positionId = _getPositionId(key, tick, zeroForOne);
        if (claimableOutputTokens[positionId] == 0)
            revert OBH__NoClaimableOutputTokenAvailable();

        uint256 userInputAmount = balanceOf(msg.sender, positionId);
        if (inputAmountToClaimFor > userInputAmount)
            revert OBH__InsufficientInputBalanceToRedeem();

        //totalClaimable Reward for userInput= totalClaimableOutput*inputAmountOfUser/totalInputAmount for this partcicular positionId
        uint256 totalOutputTokensAvailableAtThisPosition = claimableOutputTokens[
                positionId
            ];

        uint256 totalInputAmountsAtThisPosition = claimTokensSupply[positionId];

        _burn(msg.sender, positionId, userInputAmount);

        uint256 thisUserClaimableOutput = (
            totalOutputTokensAvailableAtThisPosition.mulDivDown(
                userInputAmount,
                totalInputAmountsAtThisPosition
            )
        );

        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        claimableOutputTokens[positionId] -= thisUserClaimableOutput;

        Currency outputTokenAddress = zeroForOne
            ? key.currency1
            : key.currency0;

        outputTokenAddress.transfer(msg.sender, thisUserClaimableOutput);
    }

    /**
     * @notice Performs a swap and settles balances with the pool
     * @param key The pool key
     * @param params The swap parameters
     * @return The balance delta resulting from the swap
     */
    function swapAndSettleBalances(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        BalanceDelta swapDelta = poolManager.swap(key, params, "");
        if (params.zeroForOne) {
            if (swapDelta.amount0() < 0) {
                _settle(key.currency0, uint128(-swapDelta.amount0()));
            }
            if (swapDelta.amount1() > 0) {
                _take(key.currency1, uint128(swapDelta.amount1()));
            }
        } else {
            if (swapDelta.amount1() < 0) {
                _settle(key.currency1, uint128(-swapDelta.amount1()));
            }
            if (swapDelta.amount0() > 0) {
                _take(key.currency0, uint128(swapDelta.amount0()));
            }
        }
        return swapDelta;
    }

    /**
     * @notice Executes a single order
     * @param key The pool key
     * @param tickToSellAt The tick at which to sell
     * @param zeroForOne Whether the order is selling token0 for token1
     * @param inputAmount The amount of input tokens to sell
     */
    function executeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        int24 tick = _validTickToSwapAt(tickToSellAt, key.tickSpacing);

        uint256 positionId = _getPositionId(key, tick, zeroForOne);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = swapAndSettleBalances(key, params);

        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 outputToken = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
        console.log("outputAmounteeeee:", outputToken);

        claimableOutputTokens[positionId] += outputToken;
    }

    /**
     * @notice Attempts to execute orders for a given pool and direction
     * @param key The pool key
     * @param zeroForOne Whether to execute orders selling token0 for token1
     * @return A boolean indicating if an order was executed and the current tick
     */
    function tryExecutingOrders(
        PoolKey calldata key,
        bool zeroForOne
    ) internal returns (bool, int24) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        if (currentTick > lastTick) {
            for (
                int24 tick = lastTick;
                tick < currentTick;
                tick += key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    zeroForOne
                ];

                console.log(
                    "inputeeeeeAmount1:",
                    pendingOrders[key.toId()][tick][zeroForOne]
                );
                console.log("tick:", tick);
                console.log("currentTick:", currentTick);
                if (inputAmount > 0) {
                    executeOrder(key, tick, zeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            for (
                int24 tick = lastTick;
                tick > currentTick;
                tick -= key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    zeroForOne
                ];
                console.log(
                    "inputeeeeeAmount2:",
                    pendingOrders[key.toId()][tick][zeroForOne]
                );
                console.log("tick:", tick);
                console.log("currentTick:", currentTick);

                if (inputAmount > 0) {
                    executeOrder(key, tick, zeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }
        return (false, currentTick);
    }

    /**
     * @notice Hook called after pool initialization
     * @param key The pool key
     * @param tick The initial tick
     * @return The function selector
     */
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    /**
     * @notice Hook called after a swap
     * @param sender The address initiating the swap
     * @param key The pool key
     * @param params The swap parameters
     * @return The function selector and a zero int128
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        if (sender == address(this)) return (this.afterSwap.selector, 0);
        int24 currentTick;
        bool tryMore = true;

        while (tryMore) {
            (tryMore, currentTick) = tryExecutingOrders(
                key,
                !params.zeroForOne //inverting the value because the swap which invoked afterSwap will be having opposite "zeroForOne" value of what we need in our swap
            );
        }
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    //Settle balances with Pool by paying off all unsettled amounts during the swap
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    //Helper function for taking out the swapped amount from Pool
    function _take(Currency currency, uint256 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    function _validTickToSwapAt(
        int24 tickToSellAt,
        int24 tickSpacing
    ) internal pure returns (int24) {
        //This basically rounds to the lowest&closest integer
        int24 tick = tickToSellAt / tickSpacing;
        //In the case of negative "tick" value, if the above division output contains decimal value then we decrement again
        //so that we get lowest & closest of the integer as the tick.
        if (tick < 0 && tickToSellAt % tickSpacing != 0) tick--;

        //Eg: if above tickToSellAt=-100 & tickSpacing=60, then tick=-1. Now we decrement this -1 => -2
        // final returned tick value will be -2*60=-120(i.e closest&lowest integer to -100)
        return tick * tickSpacing;
    }

    function _getPositionId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }
}
