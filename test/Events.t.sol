// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// Every change a principal or a controller makes is recorded with who made it and the note it gave.
contract EventsTest is CrestBase {
    bytes internal constant NOTE = "ticket 42: lower the agent's daily limit after the review";

    function test_aLimitsChangeRecordsThePreviousLimits_whoAndTheNote() public {
        ICrestVault.Caps memory previous = vault.getGrant(agentGrant).caps;
        ICrestVault.Caps memory next = _caps(HOLD, 2 * HOLD, type(uint128).max, 2, true, true);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.CapsSet(agentGrant, previous, next, principal, NOTE);
        vm.prank(principal);
        vault.setCaps(agentGrant, next, NOTE);
    }

    function test_aGrantRecordsItsGrantorAndNote() public {
        uint256 id = uint256(keccak256(abi.encode(agentGrant, sub, bytes32(0))));
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.Granted(id, agentGrant, sub, _wide(), buyer, NOTE);
        vm.prank(buyer);
        vault.grant(agentGrant, sub, _wide(), 0, NOTE);
    }

    function test_aPauseACloseAndAListingRecordWhoAndTheNote() public {
        bytes32 m = _merchant();
        vm.startPrank(principal);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.PausedSet(agentGrant, true, principal, NOTE);
        vault.setPaused(agentGrant, true, NOTE);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.Allowed(agentGrant, m, false, principal, NOTE);
        vault.allow(agentGrant, m, false, NOTE);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.Closed(agentGrant, principal, NOTE);
        vault.close(agentGrant, NOTE);
        vm.stopPrank();
    }

    function test_moneyMovesRecordWhoAndTheNote() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, NOTE));
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.ChildFunded(address(child), agentGrant, HOLD, buyer, NOTE);
        vm.prank(buyer);
        vault.fundChild(address(child), HOLD, NOTE);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.ChildTakenBack(address(child), agentGrant, HOLD, principal, NOTE);
        vm.prank(principal);
        vault.takeBackFromChild(address(child), HOLD, NOTE);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ICrestVault.Withdrawn(principal, HOLD, NOTE);
        vm.prank(principal);
        vault.withdraw(principal, HOLD, NOTE);
    }
}
