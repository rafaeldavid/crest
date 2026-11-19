// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ICrestFeeSweeper} from "./ICrestFeeSweeper.sol";
import {ICrestVault} from "./ICrestVault.sol";

/// @title CrestFeeSweeper
/// @notice Collects vaults' fees and forwards them to a fixed destination. `ICrestFeeSweeper` describes it.
contract CrestFeeSweeper is ICrestFeeSweeper {
    address public immutable DESTINATION;

    constructor(address destination) {
        if (destination == address(0)) revert ZeroDestination();
        DESTINATION = destination;
    }

    /// @inheritdoc ICrestFeeSweeper
    function sweep(ICrestVault vault) external returns (uint256 amount) {
        address token = vault.token();
        vault.collectFee();
        amount = SafeTransferLib.balanceOf(token, address(this));
        emit Swept(address(vault), token, amount, msg.sender);
        if (amount != 0) SafeTransferLib.safeTransfer(token, DESTINATION, amount);
    }
}
