// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IMaglevLens {
    struct VaultGlobal {
        uint256 packed1; // cash, borrows, supply cap, borrow cap
        uint256 packed2; // shares, supply APY, borrow APY
    }

    function vaultsGlobal(address[] calldata vaults) external view returns (VaultGlobal[] memory output);
}
