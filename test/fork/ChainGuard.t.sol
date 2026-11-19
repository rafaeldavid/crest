// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {CrestFactory} from "../../src/CrestFactory.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";

/// Which chain the deploy script deploys to. Forge simulates a script with `block.chainid` 31337 from foundry.toml
/// whatever the RPC, and signs for the chain the RPC answers, so the script asks the RPC. Each suite runs only when
/// its RPC variable is set; skipped otherwise, as in CI.
abstract contract ChainGuardBase is Test {
    function _forkOrSkip(string memory variable) internal {
        string memory url = vm.envOr(variable, string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        vm.chainId(31_337);
    }
}

/// `CREST_FORK_URL`: a fork of Sepolia. The script runs as forge runs it and records Sepolia.
contract DeployOnSepoliaTest is ChainGuardBase {
    HoldbackRules internal constant RULES = HoldbackRules(0x3BE45128565ABBc35DbD4660716b703Ff489f1b4);

    function setUp() public {
        _forkOrSkip("CREST_FORK_URL");
    }

    function test_onSepolia_runReadsTheChainFromTheRpc_andRecordsIt() public {
        string memory path = "deployments/rehearsal-11155111.json";
        vm.setEnv("HOLDBACK_RULES", vm.toString(address(RULES)));
        vm.setEnv("CREST_RECORD", path);
        (CrestFactory f, HoldbackModule m) = new Deploy().run();
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 11_155_111);
        assertEq(vm.parseJsonAddress(json, ".rules"), address(RULES));
        assertEq(vm.parseJsonAddress(json, ".factory"), address(f));
        assertEq(vm.parseJsonAddress(json, ".implementation"), f.IMPLEMENTATION());
        assertEq(vm.parseJsonAddress(json, ".holdbackModule"), address(m));
        vm.removeFile(path);
        bytes32 salt = keccak256("crest v01");
        bytes memory moduleCode = abi.encodePacked(type(HoldbackModule).creationCode, abi.encode(RULES));
        assertEq(address(f), vm.computeCreate2Address(salt, keccak256(type(CrestFactory).creationCode)));
        assertEq(address(m), vm.computeCreate2Address(salt, keccak256(moduleCode)));
    }
}

/// `CREST_CHAIN1_URL`: an RPC that answers chain ID 1, as mainnet does (`anvil --chain-id 1` stands in). The script
/// refuses before anything is sent.
contract DeployOnChainOneTest is ChainGuardBase {
    function setUp() public {
        _forkOrSkip("CREST_CHAIN1_URL");
    }

    function test_attack_runAgainstChainOne_refused() public {
        Deploy script = new Deploy();
        vm.setEnv("HOLDBACK_RULES", vm.toString(address(script)));
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotATestNetwork.selector, 1));
        script.run();
    }
}
