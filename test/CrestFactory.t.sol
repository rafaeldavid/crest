// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// The factory: anyone creates a principal's vault and gains nothing; addresses are known in advance; code is fixed.
contract CrestFactoryTest is CrestBase {
    function test_attack_aStrangerCreatesThePrincipalsVault_andGetsNoPower() public {
        address expected = factory.addressOf(principal, address(usdc), bytes32("second"));
        vm.prank(stranger);
        CrestVault v = CrestVault(factory.create(principal, address(usdc), bytes32("second")));
        assertEq(address(v), expected, "the address was known before creation");
        assertEq(v.principal(), principal);
        assertEq(v.grantOf(stranger), 0);
        vm.startPrank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        v.setModule(address(module), stranger, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        v.withdraw(stranger, 0, "");
        vm.stopPrank();
    }

    function test_aSecondCreationReturnsTheVault() public {
        address again = factory.create(principal, address(usdc), bytes32(0));
        assertEq(again, address(vault));
        assertEq(vault.getGrant(agentGrant).controller, buyer, "nothing was reset");
    }

    function test_attack_initializeTheImplementationOrAVaultAgain_refused() public {
        CrestVault implementation = CrestVault(factory.IMPLEMENTATION());
        vm.expectRevert(ICrestVault.AlreadyInitialized.selector);
        implementation.initialize(stranger, address(usdc), address(0), 0);
        vm.expectRevert(ICrestVault.AlreadyInitialized.selector);
        vault.initialize(stranger, address(usdc), address(0), 0);
    }

    function test_anotherPrincipalGetsAnotherAddress() public view {
        assertTrue(factory.addressOf(stranger, address(usdc), bytes32(0)) != address(vault));
    }

    function test_vaultsAreMinimalClones() public view {
        assertLt(address(vault).code.length, 50, "a minimal proxy's runtime code, not the vault's");
        assertGt(factory.IMPLEMENTATION().code.length, 1_000);
    }
}
