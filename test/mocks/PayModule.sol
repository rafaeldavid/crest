// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ICrestVault} from "../../src/ICrestVault.sol";

interface IReceiveWithAuthorization {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
}

/// Test-only module for a venue that takes ERC-3009 payments directly: it is its own pinned payee, charges the
/// vault, pulls the payment with the vault's approval, and ends commitments on request.
contract PayModule {
    address public immutable TOKEN;
    uint256 internal _n;

    constructor(address token) {
        TOKEN = token;
    }

    function pay(ICrestVault vault, address controller, uint256 amount, bytes32 counterparty)
        external
        returns (bytes32 commitment)
    {
        commitment = keccak256(abi.encode(address(vault), _n++));
        uint256 validBefore = block.timestamp + 1 hours;
        vault.charge(controller, amount, counterparty, commitment, validBefore, commitment);
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(
            address(vault), address(this), amount, 0, validBefore, commitment, ""
        );
    }

    function end(ICrestVault vault, bytes32 commitment) external {
        vault.endCommitment(commitment);
    }
}
