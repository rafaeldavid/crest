// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ICrestVault} from "./ICrestVault.sol";

/// @title ICrestFeeSweeper
/// @notice Collects the fees Crest vaults owe and forwards them to one destination fixed when the sweeper is deployed.
///         It has no owner and no setter, and anyone may call it. A vault pays it only what the vault owes, on its own
///         `collectFee`, and never calls it, so a sweeper that fails or misbehaves can neither block a payment, a
///         withdrawal or a stop, nor take more than the fee owed.
interface ICrestFeeSweeper {
    event Swept(address indexed vault, address indexed token, uint256 amount, address indexed by);

    error ZeroDestination();

    /// @notice Has `vault` pay what it owes to this sweeper, then forwards this sweeper's whole balance of the
    ///         vault's token to `DESTINATION`. A vault whose fees go to another sweeper pays that one.
    /// @return amount What was forwarded.
    function sweep(ICrestVault vault) external returns (uint256 amount);

    function DESTINATION() external view returns (address);
}
