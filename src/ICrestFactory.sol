// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title ICrestFactory
/// @notice Creates vaults as minimal clones of one implementation, each at an address that follows from its principal, its
///         token and a salt, and child vaults at an address that follows from the parent vault, the child's principal, the
///         parent grant and a salt. Anyone may create a vault and pay the gas; the creator gets no role. A second
///         creation at the same address returns the vault that is there.
/// @dev The implementation is deployed by the factory's constructor and can never be initialized. Clones have fixed
///      code: there is no upgrade.
interface ICrestFactory {
    event VaultCreated(address indexed vault, address indexed principal, address indexed token, bytes32 salt);
    event ChildVaultCreated(
        address indexed child, address indexed parent, address indexed principal, uint256 parentGrant
    );

    error NotAVault();

    /// @notice The code every vault runs.
    function IMPLEMENTATION() external view returns (address);

    /// @notice Whether `vault` was created by this factory.
    function isVault(address vault) external view returns (bool);

    /// @notice Creates `principal`'s vault for `token`, or returns it when it exists.
    function create(address principal, address token, bytes32 salt) external returns (address vault);

    /// @notice Called by a vault this factory created: creates its child vault, owned by `principal`, under the calling
    ///         vault's grant `parentGrant`, or returns it when it exists.
    function createChild(address principal, uint256 parentGrant, bytes32 salt) external returns (address child);

    /// @notice The address `create` gives for these arguments.
    function addressOf(address principal, address token, bytes32 salt) external view returns (address);

    /// @notice The address `createChild` gives when `parent` calls it with these arguments.
    function childAddressOf(address parent, address principal, uint256 parentGrant, bytes32 salt)
        external
        view
        returns (address);
}
