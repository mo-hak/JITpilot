# JIT-Pilot Re-balancing Framework  
*Designing a one-shot EulerSwap reinstall that attracts arbitrage to pay down debt*

---

## 1. Problem Statement  

Given an LP that is over-leveraged (high debt, low Health Factor), we want to:
1. Re-deploy the EulerSwap pool with a **new curve** whose quoted price makes it profitable for arbitrageurs to trade *against* the LP’s debt side.  
2. Allow those incoming trades to deliver the asset we owe (reduce liability), thereby:
   • decreasing LTV → raising Health Factor  
   • raising net interest (less borrow, more supply) → improving Yield  
   • pushing the composite score up to the stored `rebalanceDesired` target.

We assume the LP has two assets  
`asset0  ≡  collateralVault0`  
`asset1  ≡  collateralVault1`  

and that the *debt* is denominated in `asset1` (w.l.o.g. – swap x/y if opposite).

---

## 2. EulerSwap Parameters Recap  

```solidity
struct Params {
    // Entities
    address vault0;          // asset0 supply vault
    address vault1;          // asset1 supply vault
    address eulerAccount;    // LP’s sub-account
    // Curve
    uint112 equilibriumReserve0; // x₀
    uint112 equilibriumReserve1; // y₀
    uint256 priceX;              // pₓ  (numerator)
    uint256 priceY;              // p_y (denominator)
    uint256 concentrationX;      // cₓ ∈ [0,1]
    uint256 concentrationY;      // c_y ∈ [0,1]
    // Fees
    uint256 fee;
    uint256 protocolFee;
    address protocolFeeRecipient;
}
```

Mathematically the **equilibrium slope** of the piece-wise curve is  
\($\frac{dy}{dx}\Big|_{(x₀,y₀)} = -\,\frac{p_x}{p_y}.$)

Changing $p_x/p_y$ therefore changes the *quoted* cross price at the pool's centre.  
Changing $c_x,c_y$ changes **how quickly price moves** away from the centre (liquidity concentration).

---

## 3. High-Level Algorithm  

1. **Input data**
   * Market mid-price $P_m = \frac{\text{price(asset1)}}{\text{price(asset0)}}$  
   * Current debt $D$ in asset1 units  
   * Desired post-rebalance debt $D^*$ (derived from `rebalanceDesired` HF target)  
     Required incoming asset1 volume  
     $Q = D - D^*\,(>0)$

2. **Choose price premium $\epsilon$** so that arbitrageurs are incented to *sell* `asset1` into the pool:
   $P_{eq} = P_m \,(1 + \epsilon),\qquad 0 < \epsilon \ll 1$
   
   Typical $\epsilon$ range: 0.2–1 %.  
   Larger $\epsilon$ ⇒ faster fill, higher divergence loss; smaller $\epsilon$ ⇒ slower/uncertain fill.

3. **Pick pricing integers**  
   Let $p_x = 10^{18}$, $p_y = \frac{10^{18}}{P_{eq}}$ (scaled for 18 decimals).  
   This sets the *centre* price.

4. **Compute equilibrium reserves**  
   Keep $x_0,y_0$ close to *current real reserves* $R_x,R_y$ but adjust $y_0$ upward so that
   the first $Q$ of `asset1` can be absorbed before price returns to $P_m$.  
   For the left-hand piece (users selling asset1 to pool) we use the closed-form derived in §7.1.3:

   For $0 < x \le x_0$
   $y = y_0 + \frac{p_x}{p_y}(x_0 - x)\,\big[ c_x + (1 - c_x)\frac{x_0}{x} \big]$

   Invert the marginal price formula
   $\frac{dy}{dx} = -\frac{p_x}{p_y}\,[\,c_x + (1-c_x)\frac{x_0}{x}\,]^2$
   
   to find the **x-coordinate** $x_Q$ where price re-hits $P_m$:
   $x_Q = \frac{x_0}{\sqrt{1+\epsilon}}
           \quad (\text{for } c_x \approx 1)$
   
   The asset1 inflow volume is then $Q = x_0 - x_Q$.  
   Solve numerically (cheap off-chain) for the smallest $x_0 \geq R_x$ that satisfies this $Q$.

5. **Set concentration**
   * Use **high $c_x$ (≈0.9)** on the *debt* side → near-linear curve ⇒ low slippage until $Q$ filled.  
   * Keep $c_y$ as previous value (or symmetrical choice) to avoid breaking LP's profitability on the opposite side.

6. **Fees**  
   Optionally set a *temporary* maker fee rebate (lower `fee`) to further attract volume.

7. **Reinstall Pool**  
   * Close old instance (or withdraw/rescind operator).  
   * Deploy new Params with computed $x_0,y_0,p_x,p_y,c_x,c_y$.  
   * Once $Q$ is filled (monitored via Health Factor), operator can revert to neutral parameters.

---

## 4. Mathematical Derivations  

### 4.1 Price Premium → Required Reserve Shift  

Assuming $c_x \approx 1$ (constant-sum like), the price along the left piece is:

$P(x) = -\frac{dy}{dx} = \frac{p_x}{p_y}$

Because slope is constant, any $x < x_0$ still quotes $P_{eq}$.  
Thus we **must** move along the curve into the **right** piece (or relax $c_x$) to allow price to decay back to $P_m$.

With $c_x < 1$ the decay factor becomes  
$P(x) = \frac{p_x}{p_y}\left[\,c_x + (1-c_x)\frac{x_0}{x}\,\right]^2$

Set $P(x_Q)=P_m$ ⇒  
$\left[\,c_x + (1-c_x)\frac{x_0}{x_Q}\,\right] = \sqrt{1+\epsilon}$

Given a chosen $c_x$ we solve for $x_Q$.  
Volume $Q = x_0 - x_Q$ as above.

### 4.2 Impact on Health Factor  

Let collateral value $C$, liability value $L$.  
HF ≈ $\frac{C}{L}$  
Debt reduction $ΔL = Q·P_m$ implies new HF  

$HF' = \frac{C}{L - ΔL}$

We pre-compute $Q$ such that  
$HF' \geq HF_{desired}$ (stored in LP configuration).

### 4.3 Impact on Yield  

Yield improvement comes from:
1. Lower borrow APY (less debt).  
2. Increased supply APY (larger net deposit after arbitrage).  

Since both APYs are approximately linear in notional, composite score rises.

---

## 5. Practical Parameter Selection Cheat-Sheet  

| Situation | Goal | Suggested Tweaks |
|-----------|------|------------------|
| High debt, small shortfall (HF just below threshold) | Small $Q$ | $\epsilon \approx 0.25\%$, $c_x = 0.8$ |
| High debt, large shortfall | Large $Q$ | $\epsilon \approx 1\%$, $c_x = 0.95$ (flatten) |
| Need to pull in *other* asset | Swap roles of x/y + mirror logic |

---

## 6. Monitoring & Exit Criteria  

* **Trigger**: Contract already triggers when `compositeScore < rebalanceThreshold`.  
* **Exit**: Watch `compositeScore ≥ rebalanceDesired` OR elapsed blocks/time-window.  
* Fallback: Manual override by LP owner.

---

## 7. Limitations & Further Research  

1. Accurate market price $P_m$ feed is critical (oracle lag risk).  
2. Numerical solve for $x_0$ can be done off-chain and passed as calldata.  
3. The effect of $c_y$ when arbitrage swings to the opposite side needs more simulation.  
4. Multi-hop arbitrage paths (via other DEXs) could require larger $\epsilon$.  
5. Gas cost of re-deploying pool vs. adjusting in-place parameters (future EulerSwap versions may allow).

---

## 8. Summary Flowchart  

1. `updateMetrics()` detects score < threshold → emits `RebalanceTriggered`.  
2. Off-chain keeper:
   * Reads LP config & current market data  
   * Computes $(x_0,y_0,p_x,p_y,c_x,c_y)$ using §3 algorithm  
   * Calls `rebalance(lp, data.rebalanceDesired)` which  
     – closes old pool, installs new Params  
3. Arbitrageurs trade → debt asset flows into LP  
4. Composite score crosses `rebalanceDesired` → keeper restores neutral Params.

---

*Prepared for JIT-Pilot research – v0.1*