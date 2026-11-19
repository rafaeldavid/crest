// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {IHoldbackModule} from "../src/modules/holdback/IHoldbackModule.sol";
import {VaultBuyerBase} from "./VaultBuyerBase.sol";

/// The vault as the deal's buyer (design record, section 12): the agent signs for the vault while its grant's path can
/// pay, and the principal, or anyone with live authority above that grant, signs in its place. Holdback's contracts are
/// unchanged: its rules contract asks the vault through ERC-1271.
contract VaultBuyerTest is VaultBuyerBase {
    // The deal's life with the vault as the buyer

    function test_theVaultBuys_theAgentAgreesForIt_andTheDealFundsAndReleases() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(vault.getOpen(id).grant, agentGrant, "the agent's grant paid");
        assertEq(_grantOf(vault, agentGrant).spent, HOLD);
        _release(t, id);
    }

    function test_theAgentAcceptsEarlyForTheVault_whileItsGrantCanPay() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        uint256 sellerBefore = usdc.balanceOf(seller);
        _acceptEarly(t, _earlyAs(t, id, BUYER_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE);
    }

    function test_theAgentAndTheSellerSettleForTheVault_whileItsGrantCanPay() public {
        H.Terms memory t = _bterms(vault);
        uint256 before = usdc.balanceOf(address(vault));
        bytes32 id = _fundAs(t, BUYER_PK);
        _settle(t, _mutualAs(t, id, _fullRefund(t), BUYER_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Settled));
        assertEq(usdc.balanceOf(address(vault)), before, "the whole hold came back");
    }

    /// The red team's Medium (I1): with a module that also took the agent's key as the buyer, the agent chose its own
    /// key and kept its early accept after every stop. The module the principal enables here takes only the vault as
    /// the buyer, so the agent cannot choose.
    function test_attack_theAgentNamesItsOwnKeyAsTheBuyer_refusedByAVaultBuyerModule() public {
        assertTrue(module.VAULT_IS_BUYER());
        _expectRefused(
            _vterms(address(vault), buyer), BUYER_PK, abi.encodeWithSelector(IHoldbackModule.BuyerNotTheVault.selector)
        );
        assertEq(_grantOf(vault, agentGrant).spent, 0, "nothing counted");
    }

    // The principal steps in after a stop

    function test_afterAPause_theAgentIsRefused_andThePrincipalAcceptsEarlyInItsPlace() public {
        _principalStepsIn(0);
    }

    function test_afterAClose_theAgentIsRefused_andThePrincipalAcceptsEarlyInItsPlace() public {
        _principalStepsIn(1);
    }

    function test_afterARootPause_theAgentIsRefused_andThePrincipalAcceptsEarlyInItsPlace() public {
        _principalStepsIn(2);
    }

    function _principalStepsIn(uint8 stop) internal {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        vm.prank(principal);
        if (stop == 0) vault.setPaused(agentGrant, true, "stop");
        else if (stop == 1) vault.close(agentGrant, "stop");
        else vault.setPaused(ROOT, true, "stop everything");

        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
        _expectSettleRefused(t, _mutualAs(t, id, _fullRefund(t), BUYER_PK), IHoldbackRules.BadSignature.selector);
        _acceptEarly(t, _earlyAs(t, id, PRINCIPAL_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
    }

    /// Closes the gap the front-running tests record while the agent's key is the buyer: after every stop that leaves
    /// the module on, the stopped agent cannot release a delivered hold, and the principal and the merchant cancel the
    /// deal without it.
    function test_attack_afterEveryStop_theStoppedAgentCannotRelease_andThePrincipalCancelsWithTheMerchant() public {
        H.Terms memory t = _bterms(vault);
        uint256 before = usdc.balanceOf(address(vault));
        bytes32 id = _fundAs(t, BUYER_PK);
        bytes32 merchant = _merchant();
        vm.startPrank(principal);
        vault.setPaused(ROOT, true, "stop everything");
        vault.close(agentGrant, "stop");
        allowList.set(vault, agentGrant, merchant, false, "unlist");
        vm.stopPrank();

        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
        _settle(t, _mutualAs(t, id, _fullRefund(t), PRINCIPAL_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Settled));
        assertEq(usdc.balanceOf(address(vault)), before, "the principal and the merchant cancelled the deal");
    }

    /// Authority above signs for a grant below while its own path is live: the agent signs for its sub-agent's deal
    /// after the principal paused the sub-agent alone.
    function test_aLiveAgentSignsForItsPausedSubAgentsDeal() public {
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, SUB_PK);
        assertEq(vault.getOpen(id).grant, subGrant);
        vm.prank(principal);
        vault.setPaused(subGrant, true, "stop the sub-agent");

        _expectEarlyRefused(t, _earlyAs(t, id, SUB_PK));
        _acceptEarly(t, _earlyAs(t, id, BUYER_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
    }

    // Child vaults

    /// A child vault buys its own deals. Inside it, the sub-agent signs while its path can pay, here and in the parent.
    /// After the principal pauses the agent's grant in the parent, neither the sub-agent nor the agent (the child's
    /// principal) signs, and the top vault's principal signs in their place.
    function test_aChildVaultBuysItsOwnDeals_andThePrincipalAboveSignsAfterAStop() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        H.Terms memory t1 = _bterms(child);
        bytes32 id1 = _fundAs(t1, SUB_PK);
        _acceptEarly(t1, _earlyAs(t1, id1, SUB_PK));
        assertEq(uint8(_stage(id1)), uint8(IHoldbackRules.Stage.Released));

        H.Terms memory t2 = _bterms(child);
        bytes32 id2 = _fundAs(t2, SUB_PK);
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop the agent and all below it");
        _expectEarlyRefused(t2, _earlyAs(t2, id2, SUB_PK));
        _expectEarlyRefused(t2, _earlyAs(t2, id2, BUYER_PK));
        _acceptEarly(t2, _earlyAs(t2, id2, PRINCIPAL_PK));
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Released));
    }

    // 1. Funding time

    /// Before a deal is paid, the vault answers for the terms and the agreement as a dry run of the payment: the deal
    /// must name the vault as buyer and payer, and the signer's own grant must be able to pay it (state, expiry,
    /// per-payment limit and lists, here and above). A yes moves nothing: only `charge` approves the vault's money.
    function test_beforeFunding_theVaultAnswersForTheTermsAndTheAgreement_asADryRunOfThePayment() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = hx.id(t);
        assertEq(vault.isValidSignature(rules.typedDataHash(id), _termsSig(t, BUYER_PK)), MAGIC_1271);
        H.Agree memory a = _agreeAs(t, BUYER_PK);
        assertEq(vault.isValidSignature(_agreeDigest(t, a), a.signature), MAGIC_1271);

        assertEq(
            vault.isValidSignature(rules.typedDataHash(id), _termsSig(t, OTHER_PK)), NO_1271, "a key with no grant"
        );

        H.Terms memory over = _bterms(vault);
        over.price = PRICE + 1;
        assertEq(vault.isValidSignature(rules.typedDataHash(hx.id(over)), _termsSig(over, BUYER_PK)), NO_1271, "over");

        H.Terms memory unlisted = _bterms(vault);
        unlisted.sellerPayoutAddress = vm.addr(OTHER_PK);
        assertEq(
            vault.isValidSignature(rules.typedDataHash(hx.id(unlisted)), _termsSig(unlisted, BUYER_PK)),
            NO_1271,
            "an unlisted merchant"
        );

        H.Terms memory otherPayer = _bterms(vault);
        otherPayer.buyerPaymentAddress = buyer;
        assertEq(
            vault.isValidSignature(rules.typedDataHash(hx.id(otherPayer)), _termsSig(otherPayer, BUYER_PK)),
            NO_1271,
            "a deal the vault would not pay"
        );

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        assertEq(vault.isValidSignature(_agreeDigest(t, a), a.signature), NO_1271, "a paused grant");
    }

    /// The vault's yes before funding does not fund a deal on its own: a direct funding at the rules contract, without
    /// the module, gets the agreement through and is refused at the token, which only `charge` lets pay.
    function test_attack_aFundingWithoutTheModule_movesNothing() public {
        H.Terms memory t = _bterms(vault);
        uint256 before = usdc.balanceOf(address(vault));
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        H.Agree memory a = _agreeAs(t, BUYER_PK);
        vm.prank(stranger);
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        rules.agreeAndFund(t, s, acc, a, H.Funding({signature: new bytes(65)}));
        assertEq(uint8(_stage(hx.id(t))), uint8(IHoldbackRules.Stage.None), "nothing funded");
        assertEq(usdc.balanceOf(address(vault)), before);
        assertEq(_grantOf(vault, agentGrant).spent, 0);
    }

    /// An agreement opens one deal. The same deal again is refused by the vault; the agreement on other terms recovers a
    /// key with no grant; and a signature over one deal's agreement inside a message naming another is refused by the
    /// vault, so Holdback refuses the funding.
    function test_attack_anAgreementOpensOneDealOnly() public {
        H.Terms memory t1 = _bterms(vault);
        H.Agree memory a1 = _agreeAs(t1, BUYER_PK);
        module.agreeAndFund(
            t1, _sellerSig(t1, SELLER_PK), _acceptance(t1, ADJ_PK), a1, H.Funding({signature: new bytes(65)})
        );
        _expectFundRefused(t1, a1, abi.encodeWithSelector(ICrestVault.CommitmentOpen.selector));

        H.Terms memory t2 = _bterms(vault);
        _expectFundRefused(t2, a1, abi.encodeWithSelector(ICrestVault.NoGrant.selector));

        H.Agree memory a2 = H.Agree({nonce: keccak256("agree"), expiresAt: t2.timing.offerExpiresAt, signature: ""});
        a2.signature = abi.encode(
            address(module), abi.encodeCall(module.agreeMessage, (t1, a1)), _ecdsa(BUYER_PK, _agreeDigest(t2, a2))
        );
        _expectFundRefused(t2, a2, abi.encodeWithSelector(IHoldbackRules.BadSignature.selector));
        assertEq(_grantOf(vault, agentGrant).spent, HOLD, "one deal, one charge");
    }

    /// An agreement whose signature holds no ECDSA signature a key recovers from is refused by the module.
    function test_attack_anAgreementWithoutARecoverableSignature_refused() public {
        H.Terms memory t = _bterms(vault);
        H.Agree memory a = _agreeAs(t, BUYER_PK);
        (address m, bytes memory message,) = abi.decode(a.signature, (address, bytes, bytes));
        a.signature = abi.encode(m, message, new bytes(64));
        _expectFundRefused(t, a, abi.encodeWithSelector(IHoldbackModule.BadBuyerSignature.selector));
        a.signature = abi.encode(m, message, new bytes(65));
        _expectFundRefused(t, a, abi.encodeWithSelector(IHoldbackModule.BadBuyerSignature.selector));
    }

    // 6. The principal's signature after a stop

    /// After a close and a root pause, the principal settles one funded deal with the merchant and accepts another
    /// early. Money goes only to the deal's two fixed addresses, whoever signs: the seller's payout address and the
    /// vault. A settlement naming the principal is refused by Holdback. The principal's signatures open no deal: one
    /// presented as an agreement recovers a key with no grant, and its own agreement is refused by the root's pause.
    function test_thePrincipalsSignatureAfterAStop_paysOnlyTheDealsTwoAddresses_andOpensNoDeal() public {
        H.Terms memory t1 = _bterms(vault);
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        H.Terms memory t2 = _bterms(vault);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        vm.startPrank(principal);
        vault.close(agentGrant, "stop");
        vault.setPaused(ROOT, true, "stop everything");
        vm.stopPrank();
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 principalBefore = usdc.balanceOf(principal);
        uint256 agentBefore = usdc.balanceOf(buyer);

        H.Payout[] memory toPrincipal = new H.Payout[](1);
        toPrincipal[0] = H.Payout(principal, PRICE);
        _expectSettleRefused(t1, _mutualAs(t1, id1, toPrincipal, PRINCIPAL_PK), IHoldbackRules.InvalidMessage.selector);

        H.Payout[] memory split = new H.Payout[](2);
        split[0] = H.Payout(t1.sellerPayoutAddress, PRICE - 1_000_000);
        split[1] = H.Payout(address(vault), 1_000_000);
        _settle(t1, _mutualAs(t1, id1, split, PRINCIPAL_PK));
        Early memory e = _earlyAs(t2, id2, PRINCIPAL_PK);
        _acceptEarly(t2, e);

        assertEq(usdc.balanceOf(seller) - sellerBefore, 2 * PRICE - 1_000_000, "the payout address");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, 1_000_000 + 2 * FEE, "the payment address");
        assertEq(usdc.balanceOf(principal), principalBefore, "the principal's key received nothing");
        assertEq(usdc.balanceOf(buyer), agentBefore, "the agent's key received nothing");

        H.Terms memory t3 = _bterms(vault);
        H.Agree memory asAgree =
            H.Agree({nonce: keccak256("agree"), expiresAt: t3.timing.offerExpiresAt, signature: e.m.signature});
        _expectFundRefused(t3, asAgree, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
        _expectFundRefused(t3, _agreeAs(t3, PRINCIPAL_PK), abi.encodeWithSelector(ICrestVault.Paused.selector, ROOT));
    }

    // Gas: a funding with the vault as the buyer against today's. Run with `forge test --isolate --match-test
    // test_gas_ -vv`, so each call is its own transaction and starts cold.

    function test_gas_aFundingWithTheAgentsKeyAsTheBuyer() public {
        _useLegacyModule();
        H.Terms memory t = _vterms(address(vault), buyer);
        _measureFunding("the agent's key as the buyer", _fundCall(t, BUYER_PK));
    }

    function test_gas_aFundingWithTheVaultAsTheBuyer() public {
        H.Terms memory t = _bterms(vault);
        bytes memory call = abi.encodeCall(
            module.agreeAndFund,
            (
                t,
                _sellerSig(t, SELLER_PK),
                _acceptance(t, ADJ_PK),
                _agreeAs(t, BUYER_PK),
                H.Funding({signature: new bytes(65)})
            )
        );
        _measureFunding("the vault as the buyer", call);
    }

    /// Child vaults have no depth limit. The vault's answer walks the deal's path through every ancestor vault, so an
    /// early accept costs more at each level. Measured for the top principal, the longest walk, at depths 0 to 4, and
    /// for an early accept with the agent's key as the buyer.
    function test_gas_anEarlyAcceptByTheTopPrincipal_byDepth() public {
        _setAgentCaps(_caps(HOLD, type(uint128).max, type(uint128).max, 100, true, true));
        CrestVault at = vault;
        uint256 leafPk = BUYER_PK;
        uint256 leafGrant = agentGrant;
        for (uint256 depth; depth <= 4; depth++) {
            if (depth > 0) (at, leafPk, leafGrant) = _deeper(at, leafPk, leafGrant, depth);
            H.Terms memory t = _bterms(at);
            bytes32 id = _fundAs(t, leafPk);
            _acceptEarly(t, _earlyAs(t, id, PRINCIPAL_PK));
            emit log_named_uint(
                string.concat("early accept, vault as the buyer, depth ", vm.toString(depth), ": execution gas"),
                vm.lastCallGas().gasTotalUsed
            );
        }
    }

    function test_gas_anEarlyAcceptWithTheAgentsKeyAsTheBuyer() public {
        _useLegacyModule();
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        _earlyAcceptAsAgent(t, id);
        emit log_named_uint("early accept, the agent's key as the buyer: execution gas", vm.lastCallGas().gasTotalUsed);
    }

    function _measureFunding(string memory label, bytes memory call) internal {
        (bool ok,) = address(module).call(call);
        assertTrue(ok);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint(string.concat(label, ": execution gas"), used);
        emit log_named_uint(string.concat(label, ": calldata gas"), _calldataGas(call));
        emit log_named_uint(string.concat(label, ": calldata bytes"), call.length);
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    // Review findings

    /// From review test R3. The dry run before funding counts Crest's fee as `charge` does: one unit short of the hold
    /// plus its fee is a no, exactly that is a yes, and the funding then charges exactly that.
    function test_beforeFunding_theDryRunCountsCrestsFee() public {
        CrestFactory ff = new CrestFactory(100, makeAddr("sweeper"));
        CrestVault fv = CrestVault(ff.create(principal, address(usdc), bytes32("fee")));
        uint256 exact = HOLD + HOLD * 100 / 10_000;
        address payee = module.payee();
        vm.startPrank(principal);
        fv.setModule(address(module), payee, "");
        uint256 g =
            fv.grant(ROOT, buyer, _caps(exact - 1, type(uint128).max, type(uint128).max, 10, false, true), 0, "");
        vm.stopPrank();
        usdc.mint(address(fv), 10 * HOLD);
        H.Terms memory t = _bterms(fv);
        bytes32 termsDigest = rules.typedDataHash(hx.id(t));
        assertEq(fv.isValidSignature(termsDigest, _termsSig(t, BUYER_PK)), NO_1271, "one unit short with the fee");
        _expectFundRefused(t, _agreeAs(t, BUYER_PK), abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, g));
        vm.prank(principal);
        fv.setCaps(g, _caps(exact, type(uint128).max, type(uint128).max, 10, false, true), "");
        assertEq(fv.isValidSignature(termsDigest, _termsSig(t, BUYER_PK)), MAGIC_1271, "exactly the hold and its fee");
        _fundAs(t, BUYER_PK);
        assertEq(fv.getGrant(g).spent, exact);
    }

    /// From review test R8. After the principal disables the module, it enables it again and signs.
    function test_afterTheModuleIsEnabledAgain_thePrincipalSigns() public {
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        address payee = module.payee();
        vm.prank(principal);
        vault.setModule(address(module), address(0), "off");
        _expectEarlyRefused(t, _earlyAs(t, id, PRINCIPAL_PK));
        vm.prank(principal);
        vault.setModule(address(module), payee, "on again");
        _acceptEarly(t, _earlyAs(t, id, PRINCIPAL_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
    }

    /// From review test R11. Today's deal, with the agent's key as the buyer and the vault as the payer, charges the
    /// agent's grant as before.
    function test_todaysDealWithTheAgentsKeyAsTheBuyer_chargesTheAgentsGrantAsBefore() public {
        _useLegacyModule();
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(vault.getOpen(id).grant, agentGrant);
        assertEq(_grantOf(vault, agentGrant).spent, HOLD);
    }
}
