// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ICrestAllowList} from "./ICrestAllowList.sol";
import {ICrestList, ICrestVault} from "./ICrestVault.sol";

/// @title CrestAllowList
/// @notice The default merchant list. `ICrestAllowList` describes it.
contract CrestAllowList is ICrestAllowList {
    mapping(address vault => mapping(uint256 grant => mapping(bytes32 counterparty => bool))) public allowed;

    /// @inheritdoc ICrestAllowList
    function set(ICrestVault vault, uint256 grant, bytes32 counterparty, bool ok, bytes calldata note) external {
        if (!vault.isAbove(msg.sender, grant)) revert NotAuthorized();
        allowed[address(vault)][grant][counterparty] = ok;
        emit Allowed(address(vault), grant, counterparty, ok, msg.sender, note);
    }

    /// @inheritdoc ICrestList
    function allows(address vault, uint256 grant, bytes32 counterparty) external view returns (bytes4) {
        return allowed[vault][grant][counterparty] ? ICrestList.allows.selector : bytes4(0);
    }
}
