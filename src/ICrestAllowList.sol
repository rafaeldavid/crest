// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ICrestList, ICrestVault} from "./ICrestVault.sol";

/// @title ICrestAllowList
/// @notice The default merchant list: what a vault's own allow list did before lists left the vault. One contract
///         serves every vault, with no owner. Each vault's entries are written only by that vault's authority above the
///         grant they belong to, as `allow` was, so whoever points a grant here trusts that vault's tree and no one else.
interface ICrestAllowList is ICrestList {
    event Allowed(
        address indexed vault, uint256 indexed grant, bytes32 indexed counterparty, bool allowed, address by, bytes note
    );

    error NotAuthorized();

    /// @notice Lists or unlists `counterparty` for `vault`'s grant `grant`. By anyone `vault` says is above that grant.
    function set(ICrestVault vault, uint256 grant, bytes32 counterparty, bool ok, bytes calldata note) external;

    function allowed(address vault, uint256 grant, bytes32 counterparty) external view returns (bool);
}
