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

contract OrderBookHook is BaseHook, ERC1155 {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    mapping(PoolId => mapping(int24 => mapping(bool => uint256)))
        public pendingOrders;

    mapping(uint256 _positionId => uint256 _inputTokens)
        public claimTokensSupply;

    constructor(
        IPoolManager manager,
        string memory uri,
        string memory symbol
    ) BaseHook(manager) ERC1155(uri) {}

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

    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        int24 tickSpacing,
        bool zeroForOne,
        uint256 inputAmount
    ) public returns (int24) {
        int24 tick = _validTickToSellAt(tickToSellAt, tickSpacing);

        //Holds the pending order inputToken's value for this particular tick & id
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

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

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public {}

    function _validTickToSellAt(
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
    ) public returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }
}
