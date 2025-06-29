# EulerSwap Rebalancing System Design

This document describes the mathematical and logical framework for the EulerSwap Just-in-Time (JIT) liquidity pool rebalancing system, implemented fully on-chain. The system tracks two metrics—Health Factor (HF) and Yield—as sliding window time-weighted averages (TWA) over a window of 100 blocks for each liquidity provider (LP).

## 1. Health Factor Calculation and Normalization

### 1.1 Health Factor (HF)

The Health Factor for block \( t \), denoted \($\text{HF}_t$), measures vault safety based on the Loan-to-Value (LTV) ratio:

$$
\text{HF}_t = \frac{\text{allowed\_LTV}}{\text{current\_LTV}_t}
$$

- \($\text{allowed\_LTV}$): Maximum LTV allowed by the vault.
- \($\text{current\_LTV}_t$): Current LTV of the vault at block \( t \).

### 1.2 Sliding Time-Weighted Average Health Factor (TWA_HF)

The Time-Weighted Average Health Factor is calculated over a 100-block window. For a current block \( n \):

- If \($n \leq 100$), the average is over blocks 1 to \( n \):
  $$
  \text{TWA\_HF} = \frac{1}{n} \sum_{t=1}^{n} \text{HF}_t
  $$
- If \( n > 100 \), the average is over blocks \( n-99 \) to \( n \):
  $$
  \text{TWA\_HF} = \frac{1}{100} \sum_{t=n-99}^{n} \text{HF}_t
  $$


### 1.3 Normalization

The TWA_HF is normalized to a [0,1] range:

$$
\text{normalized\_HF} = \min\left( \max\left( \frac{\text{TWA\_HF} - \text{HF}_{\text{min}}}{\text{HF}_{\text{desired}} - \text{HF}_{\text{min}}}, 0 \right), 1 \right)
$$

- \($\text{HF}_{\text{min}}$): Liquidation threshold.
- \($\text{HF}_{\text{desired}}$): Target health factor set by the LP.

## 2. Yield Calculation and Normalization

### 2.1 Yield

The Yield for block \( t \), \($\text{yield}_t$), measures net profitability:

$$
\text{yield}_t = \frac{\text{swap\_fees}_t - \text{net\_interest}_t}{\text{deposit\_value}}
$$

- \($\text{swap\_fees}_t$): Fees earned from swaps at block t.
- \($\text{net\_interest}_t = \text{debt\_interest}_t - \text{collateral\_interest}_t$): Net interest paid or earned.
- \($\text{deposit\_value}$): Value of the LP's initial deposit.

### 2.2 Sliding Time-Weighted Average Yield (TWA_Y)

The Time-Weighted Average Yield is calculated over a 100-block window. For a current block \(n \):

- If \($n \leq 100$), the average is over blocks 1 to \( n \):
  $$
  \text{TWA\_Y} = \frac{1}{n} \sum_{t=1}^{n} \text{yield}_t
  $$
- If \( n > 100 \), the average is over blocks \( n-99 \) to \( n \):
  $$
  \text{TWA\_Y} = \frac{1}{100} \sum_{t=n-99}^{n} \text{yield}_t
  $$

### 3.3 Normalization

The TWA_Y is normalized to [0,1]:

$$
\text{normalized\_Y} = \min\left( \max\left( \frac{\text{TWA\_Y}}{\text{Y}_{\text{target}}}, 0 \right), 1 \right)
$$

- \( \text{Y}_{\text{target}} \): Target yield set by the LP.

## 4. Composite Score

The normalized HF and Yield are combined into a single score:

$$
\text{score} = w_1 \times \text{normalized\_HF} + w_2 \times \text{normalized\_Y}
$$

- \( w_1, w_2 \): Weights where \( w_1 + w_2 = 1 \).

## 5. Rebalancing Logic

Rebalancing is triggered if the composite score is below a predefined threshold.

