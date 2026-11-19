// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {CrestBase} from "../CrestBase.sol";

/// The deploy rehearsal on a fork of Sepolia: the script deploys against Holdback's live rules contract, escrow,
/// collector and test token, checks itself, and a vault from it pays one deal inside its caps to Released and is
/// refused one above them. Runs only when `CREST_FORK_URL` names a Sepolia RPC; skipped otherwise, as in CI.
contract SepoliaForkTest is CrestBase {
    HoldbackRules internal constant SEPOLIA_RULES = HoldbackRules(0x3BE45128565ABBc35DbD4660716b703Ff489f1b4);
    address internal constant SEPOLIA_TOKEN = 0x0b3d947f594B59Fc1Fb7D02E62C6795F8118cA6D;

    function setUp() public override {
        string memory url = vm.envOr("CREST_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        uint256 forkTime = vm.getBlockTimestamp();
        super.setUp();
        vm.chainId(11_155_111);
        vm.warp(forkTime);
        // Holdback's test keys are well known, and on Sepolia others have set EIP-7702 delegations on most of their
        // addresses, so a signature check would ask that code. The rehearsal clears it on the fork only.
        address[5] memory keys = [buyer, seller, adjudicator, fallbackAdj, appealAdj];
        for (uint256 i; i < keys.length; ++i) {
            vm.etch(keys[i], "");
        }
        rules = SEPOLIA_RULES;
        escrow = AuthCaptureEscrow(rules.ESCROW());
        usdc = MockERC3009Token(SEPOLIA_TOKEN);
        Deploy script = new Deploy();
        (factory, module) = script.deploy(rules, script.rpcChainId());
        vault = CrestVault(factory.create(principal, address(usdc), bytes32("sepolia fork")));
        vm.startPrank(principal);
        vault.setModule(address(module), module.payee(), "");
        agentGrant = vault.grant(ROOT, buyer, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true), 0, "");
        vault.allow(agentGrant, _merchant(), true, "");
        vm.stopPrank();
        usdc.mint(address(vault), 2 * HOLD);
    }

    function test_onSepolia_insideTheCaps_fundsAndReleases() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(usdc.balanceOf(address(vault)), HOLD);
        _release(t, id);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE);
    }

    function test_onSepolia_aboveThePerSpendCap_refused() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        t.price = PRICE + 1;
        _expectRefused(t, BUYER_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentGrant));
        assertEq(usdc.balanceOf(address(vault)), 2 * HOLD);
    }
}
