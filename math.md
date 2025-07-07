<!-- monitoring_and_triggering_formulas.md -->

## Monitoring & Triggering Rebalancing — Core Metrics  

### 1. Time-Weighted Health Factor and Yield  

$$
\boxed{
\overline{HF}_t \;=\;
\frac{\displaystyle\sum_{k=0}^{B-1} w_k \;
        \dfrac{C_{t-k}}{L_{t-k}}}
     {\displaystyle\sum_{k=0}^{B-1} w_k}
}
\qquad
\bigl(w_k = \lambda^{k},\; \lambda\!\in\!(0,1],\; B = \text{window size}\bigr)
$$

$$
\boxed{
\overline{Y}_t \;=\;
\frac{\displaystyle\sum_{k=0}^{B-1} w_k \; Y_{t-k}}
     {\displaystyle\sum_{k=0}^{B-1} w_k}
}
$$

with  
$C_{t-k}$ = collateral value,  
$L_{t-k}$ = liability value,  
$Y_{t-k} = r^{\text{sup}}_{t-k} - r^{\text{brw}}_{t-k}$ = net APY differential.

---

### 2. Normalisation of Time-Weighted Metrics  

$$
\hat{HF}_t \;=\;
\operatorname{clip}
\!\Bigl(
\frac{\overline{HF}_t - HF_{\min}}
     {HF_{\max} - HF_{\min}},
\,0,1
\Bigr),
\qquad
\hat{Y}_t \;=\;
\operatorname{clip}
\!\Bigl(
\frac{\overline{Y}_t - Y_{\min}}
     {Y_{\max} - Y_{\min}},
\,0,1
\Bigr)
$$

where $\operatorname{clip}(x,0,1)=\max\bigl(0,\min(x,1)\bigr)$.

---

### 3. Composite Rebalancing Score  

$$
\boxed{
S_t \;=\;
\alpha\,\hat{HF}_t \;+\; (1-\alpha)\,\hat{Y}_t
}
\qquad
\bigl(\alpha = 0.6,\; 1-\alpha = 0.4\bigr)
$$

Rebalancing is triggered whenever $S_t < S_{\text{th}}$; the keeper targets
$S_t \ge S_{\text{des}}$ after intervention.

---

## Rebalancing Parameter Calculation  

### 1. Required Debt Reduction  

$$
\boxed{
\Delta L = \frac{HF^* \cdot L/\text{LLTV} - C}{HF^*/\text{LLTV} - 1}
}
$$

where  
$HF^*$ = target health factor after rebalancing,  
$C$ = current collateral value,  
$L$ = current liability value,  
$\text{LLTV}$ = liquidation loan-to-value ratio.

---

### 2. Balanced Equilibrium Reserves  

Let $V_0$ be the total deposit value expressed in units of the collateral asset (asset0). The balanced equilibrium reserve is:

$$
\boxed{
\text{balEqRsv}_0 = \frac{V_0}{1 - \text{LLTV}}
}
$$

A symmetric expression holds for asset1: $\text{balEqRsv}_1 = \frac{V_1}{1 - \text{LLTV}}$

---

### 2. Equilibrium Reserve Targets  

$$
\boxed{
\begin{aligned}
R^{\text{eq}}_{\text{coll}} &= \frac{V_0}{1 - \text{LLTV}} \\
R^{\text{eq}}_{\text{debt}} &= \kappa\,\Delta L
\end{aligned}}
$$

Here $\kappa>1$ is a liquidity-buffer coefficient (empirically $\kappa\!\approx\!3$) chosen to seed sufficient baseline liquidity on the debt side while avoiding over-leverage.

---

### 3. Reserve Differential  

$$
\boxed{
\Delta R = \frac{\Delta L}{P_m}
}
$$

where $P_m$ is the market mid-price quoted as $\text{asset1}/\text{asset0}$. 
The debt asset is identified such that $\Delta R$ is measured in its units.

---

### 4. Target Equilibrium Reserves for the New Curve  

$$
\boxed{
\begin{aligned}
R^{\text{eq}}_{\text{coll}} &= \frac{V_0}{1 - \text{LLTV}} \\
R^{\text{eq}}_{\text{debt}} &= \kappa\,\Delta L
\end{aligned}}
$$

The notation is consistent with §2. These targets are fed into the pool constructor as `equilibriumReserveCollateralAsset` and `equilibriumReserveDebtAsset`.  

---

### 5. Centre Price Encoding  

$$
\boxed{
\begin{aligned}
p_x &= 10^{18} \\
p_y &= \frac{10^{18}}{P_m}
\end{aligned}
}
\qquad
\text{such that}\quad \frac{p_x}{p_y} = P_m
$$

These integers encode the market price in the curve parameters.

---

### 6. Initial Pool State  

$$
\boxed{
\begin{aligned}
currentReserve_{\text{0}} &= R^{\text{eq}}_{\text{coll}} - \Delta L \\
currentReserve_{\text{1}} &= f(currentReserve_{\text{0}})
\end{aligned}
}
$$

where $f(\cdot)$ is `CurveLib.f()`

The system reaches equilibrium after $\Delta R$ debt asset inflow:
$$(x_{\text{init}} + \Delta R,\, y_{\text{init}} - \Delta R) \;\longrightarrow\; (R^{\text{eq}}_{\text{coll}},\, R^{\text{eq}}_{\text{debt}})$$

---