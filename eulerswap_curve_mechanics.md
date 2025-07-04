# EulerSwap Curve Mechanics and Mathematical Framework

## 5. Curve Mechanics and Virtual Reserves

While the operator logic manages execution and capital flow, the behaviour of swaps is ultimately governed by a customisable AMM curve. EulerSwap features a unique curve that allows different amounts of liquidity and different concentrations of liquidity on different sides of the pool based on the reserves available. The space of possible reserves is determined by how much real liquidity an LP has and how much debt their operator is allowed to hold.

Since EulerSwap AMMs do not always hold the assets used to service swaps at all times, they perform calculations based on **virtual reserves and debt limits**, rather than on strictly real reserves. Each EulerSwap LP can independently configure virtual reserve levels. These reserves define the maximum debt exposure an AMM will take on. Note that the effective LTV must always remain below the borrowing LTV of the lending vault to prevent liquidation.

### Key Considerations

- EulerSwap account owners are responsible for monitoring the health of their vaults
- Proactive steps should be taken if collateral accrues bad debt or drops in value
- Liquidation can occur independently of swap activity if someone performs a large swap on their curve
- Different AMM curves influence whether the maximum virtual reserves are achievable

### Equilibrium Point and Pricing

The EulerSwap curve passes through a reserve equilibrium point (x₀, y₀), at which the marginal price is defined by:

```
dy/dx|(x₀,y₀) = -px/py
```

where px and py are pricing parameters that determine the exchange rate at equilibrium.

### Piecewise Curve Definition

Unlike most AMM curves, which are usually defined by a single convex function, EulerSwap uses a **piecewise-defined curve**, with different functions guiding trading behaviour either side of the equilibrium point.

#### Left Side (0 < x ≤ x₀)
In the domain 0 < x ≤ x₀, the curve is defined by:

```
y = y₀ + (px/py)(x₀ - x)[cx + (1 - cx)(x₀/x)]
```

where y depends on x.

#### Right Side (x₀ < x)
In the region x₀ < x, we let x become the dependent variable, so that the domain is 0 < y ≤ y₀, and the curve is defined by:

```
x = x₀ + (py/px)(y₀ - y)[cy + (1 - cy)(y₀/y)]
```

where x depends on y.

### Concentration Parameters

The cx, cy parameters in the equations are **liquidity concentration parameters** that control how liquidity is distributed along the curve:

- **Values closer to 1**: Concentrate liquidity around the equilibrium point, similar to a Curve StableSwap pool
- **Values closer to 0**: Distribute liquidity across a wider price range, similar to a classic Bancor or Uniswap v2 pool
- **When cx = cy = 1**: The AMM becomes a constant-sum AMM
- **When cx = cy = 0**: The AMM becomes a constant-product AMM

### 5.1 Novel Use-Cases

This flexibility enables EulerSwap to be used for entirely new use cases or to simulate the behaviour of atypical AMM protocols, such as Maker's peg stability module. 

#### Token Launchpad Configuration
By configuring asymmetric liquidity curves, EulerSwap can be used as a launchpad for new tokens:
- **Concentrate liquidity on the quote asset side** (e.g., USDC)
- **Distribute broadly on the base asset side** (e.g., a new token)
- This allows projects to establish a price floor while supporting price discovery
- Proceeds from sales can immediately begin earning yield
- AMM's debt mechanics enable community-backed liquidity bootstrapping without requiring large treasury allocations upfront

---

## 7. Appendix

### 7.1 Curve Description

This section describes how the EulerSwap curve generalises the behaviours of both the constant-sum (CSMM) and constant-product market maker (CPMM) curves using liquidity concentration parameters.

We begin with an automated market maker (AMM) holding initial liquidity reserves of two assets, X and Y, denoted as x₀ and y₀, respectively. In the absence of trading, the AMM remains at equilibrium at the point (x₀, y₀).

#### Design Goals

Our goal is to find a curve for a constant-function trading market maker (CFMM) that supports swaps between the two assets with the following properties:

- Passes through the equilibrium point (x₀, y₀)
- Maintains an exchange rate, given by the slope of the AMM curve, of -px/py at (x₀, y₀)
- Allows liquidity concentration to be adjusted via parameters cx and cy, which control the liquidity available for swaps to the left and right of the equilibrium point

### 7.1.1 Constant-Sum and Constant-Product Curves

The canonical CSMM and CPMM curves are given by:

**Constant-Sum (CSMM):**
```
x + y = x₀ + y₀
```

**Constant-Product (CPMM):**
```
xy = x₀y₀
```

#### Characteristics
- **CSMM**: Simply a line - concentrates liquidity at a single exchange rate
- **CPMM**: A hyperbola - distributes liquidity across a wide range of different exchange rates

By default, these curves intersect at the equilibrium point (x₀, y₀), where their slopes are:

**CSMM slope:**
```
dy/dx = -1
```

**CPMM slope:**
```
dy/dx = -y/x
```

#### Custom Pricing Parameters

Since real-world markets often operate at variable exchange rates at equilibrium, we introduce custom pricing parameters px and py to allow flexibility in defining the slope at the equilibrium point:

**Weighted CSMM:**
```
px·x + py·y = px·x₀ + py·y₀
```

**Weighted CPMM:**
```
x^(py·y₀) · y^(px·x₀) = x₀^(py·y₀) · y₀^(px·x₀)
```

Taking the derivatives of these equations with respect to x:

**CSMM derivative:**
```
dy/dx = -px/py
```

**CPMM derivative:**
```
dy/dx = -(px/py) · (x₀/y) · (y₀/x)
```

At equilibrium (x₀, y₀), both functions have the slope:
```
dy/dx|(x₀,y₀) = -px/py
```

### 7.1.2 Introducing Artificial Reserves

The weighted CPMM introduces significant computational complexity due to exponential forms involving power functions of reserves, which are expensive to compute on-chain in the EVM. To address this, we construct an alternative using **artificial reserves**.

#### Domain Splitting Strategy

In the interval 0 < x ≤ x₀, swaps should only increase liquidity beyond y₀ and deplete x₀ liquidity. This suggests that we can split the domain of the AMM curves into two, and replace the real reserve y₀ in the interval 0 < x ≤ x₀ with a carefully chosen artificial reserve yᵥ.

Re-arranging the weighted curves into explicit functions of y:

**CSMM explicit form:**
```
y = y₀ + (px/py)(x₀ - x)
```

**CPMM explicit form:**
```
y = y₀ · (x₀/x)^(py·y₀)/(px·x₀)
```

#### Artificial Reserve Substitution

A substitution of y₀ → yᵥ, given by:
```
yᵥ = x₀ · px/py
```

eliminates the exponential form. This leads to:

**Simplified CSMM:**
```
y = (px/py)(2x₀ - x)
```

**Simplified CPMM:**
```
y = (px/py) · x₀²/x
```

#### Correction for Equilibrium Point

Since these curves no longer pass through (x₀, y₀), we correct them by adding back the difference y₀ - (px/py)x₀:

**Corrected CSMM:**
```
y = y₀ + (px/py)(x₀ - x)
```

**Corrected CPMM:**
```
y = y₀ + (px/py)(x₀ - x)(x₀/x)
```

### 7.1.3 Unified Curve for Region 0 < x ≤ x₀

To create a single unified curve, we introduce a liquidity concentration parameter cx ∈ [0, 1]:

- **cx = 1**: AMM functions as a constant-sum AMM
- **cx = 0**: AMM behaves as a constant-product-like AMM  
- **Intermediate values**: Create a hybrid trading function with liquidity more or less concentrated around the equilibrium point

#### Unified Equation

This parameterisation leads to:

```
y = y₀ + (px/py)(x₀ - x)[cx + (1 - cx)(x₀/x)]
```

#### Marginal Price

The marginal price anywhere along the curve is given by:

```
dy/dx = -(px/py)[cx + (1 - cx)(x₀/x)]²
```

#### Price-to-Coordinate Mapping

The equation can be re-arranged to solve for the x-coordinate corresponding to a particular price p = dy/dx:

```
x = x₀ / √[-(py/px) · (p - cx)/(1 - cx)]
```

#### Inverse Function

To perform as a complete trading function, the equation can be inverted to compute x given y using the quadratic formula:

```
cx·x² + [(py/px)(y - y₀) - (2cx - 1)x₀]·x - (1 - cx)x₀² = 0
```

**Quadratic components:**
- A = cx
- B = (py/px)(y - y₀) - (2cx - 1)x₀  
- C = -(1 - cx)x₀²

**Numerically stable solution:**
```
x = {
    (B + √(B² + 4AC))/(2A),     if B ≤ 0
    2C/(B + √(B² + 4AC)),       if B > 0
}
```

### 7.1.4 Extending the Curve to x ≥ x₀ Region

To support swaps where the input token lies in the region x ≥ x₀, we need a symmetric extension. Rather than defining a new function, we reflect the existing function by interchanging the roles of x and y with appropriate reparameterisation:

```
x = x₀ + (py/px)(y₀ - y)[cy + (1 - cy)(y₀/y)]
```

This provides pricing for swaps where x is given and y is unknown, in the domain 0 < y ≤ y₀ (corresponding to x ≥ x₀).

### 7.2 Invariant

In traditional AMM protocols, the curve is typically defined as an implicit function. For example, the classic Uniswap AMM follows:

```
xy = x₀y₀
```

This defines an invariant condition ensuring any valid swap must satisfy:
```
xy ≥ x₀y₀
```

#### EulerSwap Invariant Extension

For EulerSwap, we apply a similar principle with piecewise conditions:

**For 0 < x ≤ x₀:**
```
y ≥ y₀ + (px/py)(x₀ - x)[cx + (1 - cx)(x₀/x)]
```

**For 0 < y ≤ y₀ (equivalent to x > x₀):**
```
x ≥ x₀ + (py/px)(y₀ - y)[cy + (1 - cy)(y₀/y)]
```

These conditions together define the valid liquidity states in EulerSwap, ensuring that the AMM remains balanced while allowing for greater flexibility in liquidity provisioning.

---

## Mathematical Implementation Notes

### Solidity Implementation

The mathematical functions are implemented in Solidity within the 'CurveLib.sol' contract:

- **f()**: Implements the main curve equation for swap quoting and system invariant
- **fInverse()**: Implements the inverse function for providing quotes to swappers
- **Citardauq formula**: Alternative numerically stable form of the quadratic equation used when B ≥ 0

### Computational Efficiency

The artificial reserves approach significantly reduces computational complexity compared to the weighted CPMM with exponential forms, making the system practical for on-chain deployment while maintaining the desired mathematical properties.

### Visual Representation

The EulerSwap curve can be visualized as two connected pieces:
- Left side: Controlled by cx parameter
- Right side: Controlled by cy parameter  
- Both sides meeting at equilibrium point (x₀, y₀)
- Pricing parameters px, py determining the slope at equilibrium

This piecewise design enables asymmetric liquidity distribution, allowing different concentration levels on each side of the equilibrium point.