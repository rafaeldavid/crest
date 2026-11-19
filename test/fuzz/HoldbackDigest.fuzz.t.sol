// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestBase} from "../CrestBase.sol";

/// For any terms the rules contract accepts, the authorization the vault approves is exactly the one the collector
/// presents: a funding inside wide limits always lands, so the module's payment record and nonce match the rules
/// contract's own derivation. A mismatch would fail closed, and this test would catch it.
contract HoldbackDigestFuzzTest is CrestBase {
    function setUp() public override {
        super.setUp();
        _setAgentCaps(_caps(type(uint128).max, type(uint128).max, type(uint128).max, type(uint32).max, true, true));
        usdc.mint(address(vault), type(uint120).max);
    }

    function testFuzz_theVaultsDigestMatchesTheCollectors(
        uint96 price,
        uint64 fee,
        uint32 offer,
        uint32 fund,
        uint32 deliver,
        uint32 judge,
        uint32 fallbackAfter,
        uint32 appealDecide
    ) public {
        H.Terms memory t = _vterms(address(vault), buyer);
        uint64 now_ = uint64(block.timestamp);
        t.price = bound(price, 1, type(uint96).max);
        t.fee = bound(fee, 0, type(uint64).max);
        t.timing.offerExpiresAt = now_ + uint64(bound(offer, 1, 30 days));
        t.timing.fundBy = t.timing.offerExpiresAt + uint64(bound(fund, 1, 30 days));
        t.timing.deliverBy = t.timing.fundBy + uint64(bound(deliver, 1, 365 days));
        t.timing.judgeBy = t.timing.deliverBy + uint64(bound(judge, 1, 365 days));
        t.timing.fallbackBy = t.timing.judgeBy + uint64(bound(fallbackAfter, 1, 365 days));
        t.timing.appealDecideSec = uint64(bound(appealDecide, 1, 365 days));
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
    }
}
