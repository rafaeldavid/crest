// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CrestBase} from "./CrestBase.sol";

/// Each contract's external surface is exactly a reviewed list: a new external function is a visible diff here, and
/// any other selector reverts with any calldata from any caller.
contract SelectorsTest is CrestBase {
    function test_theVaultsFunctions_areExactlyTheReviewedList() public view {
        string[43] memory want = [
            "FEE_BPS()",
            "FEE_SWEEPER()",
            "ROOT()",
            "acceptPrincipal(bytes)",
            "authorityOver(address,uint256)",
            "cancelSignedGrant(uint256,address,bytes32,bytes)",
            "charge(address,uint256,bytes32,bytes32,uint256,bytes32)",
            "checkDelegable(uint256)",
            "checkPath(uint256,uint256,bytes32)",
            "close(uint256,bytes)",
            "collectFee()",
            "createChild(uint256,bytes32,bytes)",
            "eip712Domain()",
            "endCommitment(bytes32)",
            "factory()",
            "feeOwed()",
            "fundChild(address,uint256,bytes)",
            "getGrant(uint256)",
            "getOpen(bytes32)",
            "grant(uint256,address,(uint128,uint128,uint128,uint32,uint32,uint40,bool,address),bytes32,bytes)",
            "grantBySig((uint256,address,(uint128,uint128,uint128,uint32,uint32,uint40,bool,address),bytes32,uint40,bytes),bytes)",
            "grantOf(address)",
            "grantOfChild(address)",
            "initialize(address,address,address,uint256)",
            "isAbove(address,uint256)",
            "isValidSignature(bytes32,bytes)",
            "parent()",
            "parentGrant()",
            "pathLive(uint256)",
            "payeeOf(address)",
            "pendingPrincipal()",
            "principal()",
            "proposePrincipal(address,bytes)",
            "reclaim(address,(address,address,address,address,uint120,uint48,uint48,uint48,uint16,uint16,address,uint256))",
            "returnToParent(uint256,bytes)",
            "setCaps(uint256,(uint128,uint128,uint128,uint32,uint32,uint40,bool,address),bytes)",
            "setModule(address,address,bytes)",
            "setPaused(uint256,bool,bytes)",
            "signsAbove(address,uint256)",
            "signsFor(address,uint256)",
            "takeBackFromChild(address,uint256,bytes)",
            "token()",
            "withdraw(address,uint256,bytes)"
        ];
        string[] memory got = vm.parseJsonKeys(vm.readFile("out/CrestVault.sol/CrestVault.json"), ".methodIdentifiers");
        assertEq(got.length, want.length, "the vault's function count changed");
        for (uint256 i; i < want.length; i++) {
            assertEq(got[i], want[i]);
        }
    }

    function test_theFactorysFunctions_areExactlyTheReviewedList() public view {
        string[6] memory want = [
            "IMPLEMENTATION()",
            "addressOf(address,address,bytes32)",
            "childAddressOf(address,address,uint256,bytes32)",
            "create(address,address,bytes32)",
            "createChild(address,uint256,bytes32)",
            "isVault(address)"
        ];
        string[] memory got =
            vm.parseJsonKeys(vm.readFile("out/CrestFactory.sol/CrestFactory.json"), ".methodIdentifiers");
        assertEq(got.length, want.length, "the factory's function count changed");
        for (uint256 i; i < want.length; i++) {
            assertEq(got[i], want[i]);
        }
    }

    function test_theModulesFunctions_areExactlyTheReviewedList() public view {
        string[] memory got =
            vm.parseJsonKeys(vm.readFile("out/HoldbackModule.sol/HoldbackModule.json"), ".methodIdentifiers");
        string[12] memory start = [
            "RULES()",
            "VAULT_IS_BUYER()",
            "agreeAndFund(",
            "agreeMessage(",
            "buyerMessage(bytes)",
            "close(",
            "counterpartyOf(address,address,address,address)",
            "earlyAcceptMessage(bytes32,address,(uint8,bytes32,bytes32,uint64,bytes))",
            "escrow()",
            "mutualMessage(",
            "payee()",
            "termsMessage("
        ];
        assertEq(got.length, start.length, "the module's function count changed");
        for (uint256 i; i < start.length; i++) {
            assertTrue(vm.indexOf(got[i], start[i]) == 0, got[i]);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_anySelectorOutsideTheList_reverts(bytes4 selector, bytes calldata rest, address caller) public {
        string[] memory names =
            vm.parseJsonKeys(vm.readFile("out/CrestVault.sol/CrestVault.json"), ".methodIdentifiers");
        for (uint256 i; i < names.length; i++) {
            vm.assume(selector != bytes4(keccak256(bytes(names[i]))));
        }
        vm.prank(caller);
        (bool ok,) = address(vault).call(abi.encodePacked(selector, rest));
        assertFalse(ok, "a selector outside the list ran");
    }
}
