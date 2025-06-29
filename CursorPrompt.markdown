# Prompt for Cursor: EulerSwap Rebalancing Smart Contract

## Overview

We are developing a Solidity smart contract for the EulerSwap Just-in-Time (JIT) liquidity pool rebalancing system. The contract tracks two metrics—Health Factor (HF) and Yield—as sliding time-weighted averages (TWA) over a window of 100 blocks for each liquidity provider (LP). These averages are stored in mappings tied to LP addresses, updated every block with current data, and used to calculate a composite score. If the score falls below a threshold, the contract triggers rebalancing via the `rebalance` function.

**Important**: The TWA is calculated over a 100-block window. For a current block \( n \):
- If \($n \leq 100$), the average is over blocks 1 to \(n \).
- If \( n > 100 \), the average is over blocks \( n-99 \) to \( n \), effectively sliding the window forward.
- `fetchData` function provides required data for the current block fetched from euler contracts(dont implement this function now just call it to get the data when `updatemetrics` function is called).
- `rebalance` function rebalances and called in the `updatemetrics` function when the conditions meet.(dont implement this too)
- **Process**: the function is called each block, fetch current block data from fetch function and the average stored for the previous blocks, calculate new averages, update the average in the variable, calculate the score, and check for rebalancing conditions.

Please provide the Solidity code with the logic for `updateMetrics` function and necessary state variables and data structure. I’ll add more functions later.