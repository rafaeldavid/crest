// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";

import {CrestVault} from "./CrestVault.sol";
import {ICrestFactory} from "./ICrestFactory.sol";

/// @title CrestFactory
/// @notice Creates Crest vaults and child vaults. `ICrestFactory` describes every function, event and error.
contract CrestFactory is ICrestFactory {
    address public immutable IMPLEMENTATION;
    mapping(address vault => bool) public isVault;

    /// @param feeBps The fee every vault from this factory owes on a payment, in basis points; 0 for none.
    /// @param feeSweeper The contract every vault from this factory pays its fees to; may be 0 when `feeBps` is 0.
    constructor(uint256 feeBps, address feeSweeper) {
        IMPLEMENTATION = address(new CrestVault(feeBps, feeSweeper));
    }

    /// @inheritdoc ICrestFactory
    function create(address principal, address token, bytes32 salt) external returns (address vault) {
        bytes32 s = keccak256(abi.encode(principal, token, salt));
        vault = LibClone.predictDeterministicAddress(IMPLEMENTATION, s, address(this));
        if (vault.code.length != 0) return vault;
        isVault[vault] = true;
        emit VaultCreated(vault, principal, token, salt);
        vault = LibClone.cloneDeterministic(IMPLEMENTATION, s);
        CrestVault(vault).initialize(principal, token, address(0), 0);
    }

    /// @inheritdoc ICrestFactory
    function createChild(address principal, uint256 parentGrant, bytes32 salt) external returns (address child) {
        if (!isVault[msg.sender]) revert NotAVault();
        bytes32 s = keccak256(abi.encode(msg.sender, principal, parentGrant, salt));
        child = LibClone.predictDeterministicAddress(IMPLEMENTATION, s, address(this));
        if (child.code.length != 0) return child;
        address token = CrestVault(msg.sender).token();
        isVault[child] = true;
        emit ChildVaultCreated(child, msg.sender, principal, parentGrant);
        child = LibClone.cloneDeterministic(IMPLEMENTATION, s);
        CrestVault(child).initialize(principal, token, msg.sender, parentGrant);
    }

    /// @inheritdoc ICrestFactory
    function addressOf(address principal, address token, bytes32 salt) external view returns (address) {
        return LibClone.predictDeterministicAddress(
            IMPLEMENTATION, keccak256(abi.encode(principal, token, salt)), address(this)
        );
    }

    /// @inheritdoc ICrestFactory
    function childAddressOf(address parent, address principal, uint256 parentGrant, bytes32 salt)
        external
        view
        returns (address)
    {
        return LibClone.predictDeterministicAddress(
            IMPLEMENTATION, keccak256(abi.encode(parent, principal, parentGrant, salt)), address(this)
        );
    }
}
