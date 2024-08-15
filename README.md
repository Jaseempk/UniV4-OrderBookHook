OrderBookHook

**Overview**
OrderBookHook is a Solidity smart contract designed to provide an order book functionality for Uniswap V4. By integrating with Uniswap V4 pools, this contract allows users to place and manage limit orders directly on the blockchain. It uses the ERC1155 standard for token management and offers a range of features to enable complex trading strategies.

**Features:**

Place Limit Orders: Users can set limit orders to buy or sell tokens at specific price levels on Uniswap V4 pools.
Cancel Orders: Provides the ability to cancel existing limit orders before they are filled.
Redeem Swapped Tokens: Once a limit order is fulfilled, users can redeem the output tokens that were swapped in the transaction.
Automated Order Execution: The contract automatically executes orders when the specified conditions are met in the pool.
ERC1155 Integration: The contract uses ERC1155 tokens to represent positions and claims, providing a flexible and efficient way to manage orders.
