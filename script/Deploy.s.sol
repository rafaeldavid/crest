// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";

import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {HoldbackModule} from "../src/modules/holdback/HoldbackModule.sol";

/// @title Deploy
/// @notice Deploys Crest on a test network: the factory, whose constructor deploys the vault implementation, and the
///         Holdback module for one Holdback rules deployment, both through the public CREATE2 deployer so their
///         addresses follow from the code alone. Then checks every value a principal relies on and writes
///         `deployments/<chain id>.json`. Refuses any chain but Sepolia and a local chain.
/// @dev Env: `HOLDBACK_RULES`, the rules contract; `CREST_RECORD`, optional, another path for the record (a rehearsal
///      on a fork writes there, so `deployments/11155111.json` only ever holds the real deployment). Run with
///      `--broadcast` and the maintainer's key.
contract Deploy is Script {
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant LOCAL = 31_337;
    bytes32 internal constant SALT = keccak256("crest v01");

    error NotATestNetwork(uint256 chainId);
    error CheckFailed(string what);

    function run() external returns (CrestFactory factory, HoldbackModule module) {
        (factory, module) = deploy(HoldbackRules(vm.envAddress("HOLDBACK_RULES")));
        _record(factory, module);
    }

    function deploy(HoldbackRules rules) public returns (CrestFactory factory, HoldbackModule module) {
        if (block.chainid != SEPOLIA && block.chainid != LOCAL) revert NotATestNetwork(block.chainid);
        if (address(rules).code.length == 0) revert CheckFailed("no rules contract at HOLDBACK_RULES");
        vm.startBroadcast();
        factory = new CrestFactory{salt: SALT}();
        module = new HoldbackModule{salt: SALT}(rules);
        vm.stopBroadcast();
        check(factory, module, rules);
    }

    /// @notice Reverts unless the factory's implementation is the uninitializable vault code and the module points at
    ///         this rules deployment, its escrow and its ERC-3009 collector.
    function check(CrestFactory factory, HoldbackModule module, HoldbackRules rules) public view {
        CrestVault implementation = CrestVault(factory.IMPLEMENTATION());
        if (address(implementation).code.length == 0) revert CheckFailed("the implementation has no code");
        if (implementation.principal() != address(1)) revert CheckFailed("the implementation can be initialized");
        if (address(module.RULES()) != address(rules)) revert CheckFailed("the module names another rules contract");
        if (module.payee() != rules.ERC3009_COLLECTOR()) revert CheckFailed("the module pays another collector");
        if (module.escrow() != address(rules.ESCROW())) revert CheckFailed("the module names another escrow");
    }

    function _record(CrestFactory factory, HoldbackModule module) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "rules", address(module.RULES()));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "implementation", factory.IMPLEMENTATION());
        vm.serializeAddress(o, "holdbackModule", address(module));
        vm.serializeBytes32(o, "salt", SALT);
        string memory json = vm.serializeUint(o, "block", block.number);
        string memory path =
            vm.envOr("CREST_RECORD", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        vm.writeJson(json, path);
        console2.log("factory", address(factory));
        console2.log("implementation", factory.IMPLEMENTATION());
        console2.log("holdbackModule", address(module));
    }
}
