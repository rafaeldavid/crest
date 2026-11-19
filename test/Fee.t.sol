// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {CrestFactory} from "../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../src/CrestFeeSweeper.sol";
import {CrestVault} from "../src/CrestVault.sol";
import {ICrestFeeSweeper} from "../src/ICrestFeeSweeper.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";
import {PayModule} from "./mocks/PayModule.sol";

/// A test token that calls back on every transfer: a hostile sweeper uses it to re-enter, and it refuses one recipient
/// so a forward from the sweeper can fail.
contract HookToken is MockERC3009Token {
    address public refused;

    constructor() MockERC3009Token("Hook USD", "hUSD", 6) {}

    function refuse(address who) external {
        refused = who;
    }

    function _afterTokenTransfer(address, address to, uint256) internal override {
        if (to != address(0) && to == refused) revert("refused");
        if (to.code.length != 0) {
            (bool ok,) = to.call(abi.encodeWithSignature("onTokens()"));
            ok;
        }
    }
}

/// A sweeper that, on receiving tokens, tries to take the fee again and to move the vault's other money.
contract HostileSweeper {
    CrestVault public vault;
    uint256 public tries;

    function aim(CrestVault v) external {
        vault = v;
    }

    function onTokens() external {
        if (tries++ > 0) return;
        vault.collectFee();
        try vault.withdraw(address(this), 1, "") {} catch {}
        try vault.returnToParent(1, "") {} catch {}
    }
}

/// The fee: fixed in the factory when it is deployed, owed as each payment is made, and collected by a sweeper contract
/// that the vault never calls. Each `test_attack_*` passes when the defence holds.
contract FeeTest is CrestBase {
    uint256 internal constant RATE = 100; // 1%, in basis points
    uint256 internal constant CREST_FEE = HOLD * RATE / 10_000;

    address internal destination;
    CrestFeeSweeper internal sweeper;
    CrestFactory internal feeFactory;
    CrestVault internal fv;
    uint256 internal fg;

    function setUp() public override {
        super.setUp();
        destination = makeAddr("fee destination");
        sweeper = new CrestFeeSweeper(destination);
        feeFactory = new CrestFactory(RATE, address(sweeper));
        fv = CrestVault(feeFactory.create(principal, address(usdc), bytes32("a vault with a fee")));
        vm.startPrank(principal);
        fv.setModule(address(module), module.payee(), "");
        fg = fv.grant(ROOT, buyer, _caps(2 * HOLD, 3 * (HOLD + CREST_FEE), type(uint128).max, 5, true, true), 0, "");
        fv.allow(fg, _merchant(), true, "");
        vm.stopPrank();
        usdc.mint(address(fv), 10 * HOLD);
    }

    // The fee is owed as a payment is made

    function test_aPaymentOwesTheFee_andTheHoldGetsExactlyItsTerms() public {
        uint256 store = usdc.balanceOf(escrow.getTokenStore(address(rules)));
        vm.expectEmit(address(fv));
        emit ICrestVault.FeeOwed(fg, CREST_FEE);
        bytes32 id = _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(usdc.balanceOf(escrow.getTokenStore(address(rules))) - store, HOLD, "the hold holds its terms");
        assertEq(fv.feeOwed(), CREST_FEE);
        assertEq(usdc.balanceOf(address(fv)), 9 * HOLD, "the fee stays in the vault until collected");
        assertEq(_grantOf(fv, fg).spent, HOLD + CREST_FEE, "the fee counts against the grant");
    }

    function test_theFeeIsFixedInEveryVaultOfTheFactory() public {
        assertEq(fv.FEE_BPS(), RATE);
        assertEq(fv.FEE_SWEEPER(), address(sweeper));
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        assertEq(child.FEE_BPS(), RATE);
        assertEq(child.FEE_SWEEPER(), address(sweeper));
        assertEq(vault.FEE_BPS(), 0, "CrestBase's factory charges nothing");
    }

    function test_attack_aFactoryWithAMalformedFee_refused() public {
        vm.expectRevert(ICrestVault.InvalidFee.selector);
        new CrestFactory(10_001, address(sweeper));
        vm.expectRevert(ICrestVault.InvalidFee.selector);
        new CrestFactory(1, address(0));
        new CrestFactory(0, address(0));
        new CrestFactory(10_000, address(sweeper));
    }

    // No limit is passed by the fee

    /// A payment that exactly meets a limit is refused by name once the fee is counted with it.
    function test_attack_aPaymentExactlyAtALimit_withAFee_refusedByName() public {
        vm.prank(principal);
        fv.setCaps(fg, _caps(HOLD, 10 * HOLD, type(uint128).max, 5, true, true), "per payment: exactly one hold");
        _expectRefused(
            _vterms(address(fv), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, fg)
        );
        vm.prank(principal);
        fv.setCaps(fg, _caps(HOLD + CREST_FEE, 10 * HOLD, type(uint128).max, 5, true, true), "one hold and its fee");
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
    }

    function test_attack_theFeePassesNoPeriodLimit() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        assertEq(_grantOf(fv, fg).inPeriod, 3 * (HOLD + CREST_FEE));
        _expectRefused(
            _vterms(address(fv), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, fg)
        );
    }

    /// A sub-agent's payment counts its fee at every level above it.
    function test_attack_theFeePassesNoLimitThroughASubGrant() public {
        vm.prank(buyer);
        uint256 subGrant = fv.grant(fg, sub, _wide(), 0, "");
        _fundVia(_vterms(address(fv), sub), SUB_PK);
        assertEq(_grantOf(fv, subGrant).spent, HOLD + CREST_FEE);
        assertEq(_grantOf(fv, fg).spent, HOLD + CREST_FEE);
        assertEq(_grantOf(fv, ROOT).spent, HOLD + CREST_FEE);
        vm.prank(principal);
        fv.setCaps(fg, _caps(2 * HOLD, 2 * HOLD + CREST_FEE, type(uint128).max, 5, true, true), "");
        _expectRefused(
            _vterms(address(fv), sub), SUB_PK, abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, fg)
        );
    }

    function test_attack_theFeePassesNoLimitThroughASignedGrant() public {
        bytes32[] memory merchants = new bytes32[](1);
        merchants[0] = _merchant();
        ICrestVault.SignedGrant memory s = ICrestVault.SignedGrant({
            parent: fg,
            controller: sub,
            caps: _caps(HOLD, 2 * HOLD, type(uint128).max, 1, true, false),
            salt: 0,
            counterparties: merchants,
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: ""
        });
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(BUYER_PK, _signedGrantDigest(fv, s));
        fv.grantBySig(s, abi.encodePacked(r, ss, v));
        _expectRefused(
            _vterms(address(fv), sub),
            SUB_PK,
            abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, fv.grantOf(sub))
        );
    }

    // The fee owed stays in the vault

    function test_attack_aWithdrawalTakesTheFeeOwed_refused() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        uint256 balance = usdc.balanceOf(address(fv));
        vm.prank(principal);
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        fv.withdraw(principal, balance, "");
        vm.prank(principal);
        fv.withdraw(principal, balance - CREST_FEE, "everything but the fee owed");
        assertEq(usdc.balanceOf(address(fv)), CREST_FEE);
    }

    function test_attack_aFillTakesTheFeeOwed_refused() public {
        vm.prank(principal);
        fv.setCaps(fg, _wide(), "");
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        uint256 free = usdc.balanceOf(address(fv)) - CREST_FEE;
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        fv.fundChild(address(child), free + 1, "");
        vm.prank(buyer);
        fv.fundChild(address(child), free, "everything but the fee owed");
        assertEq(usdc.balanceOf(address(fv)), CREST_FEE);
    }

    /// A child vault of a factory with a fee owes its own fee, which a return to the parent leaves behind.
    function test_attack_aReturnTakesTheChildsFeeOwed_refused() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(fv.createChild(fg, 0, ""));
        vm.prank(buyer);
        fv.fundChild(address(child), 2 * HOLD, "");
        vm.prank(buyer);
        child.grant(ROOT, sub, _wide(), 0, "");
        _fundVia(_vterms(address(child), sub), SUB_PK);
        assertEq(child.feeOwed(), CREST_FEE);
        uint256 left = usdc.balanceOf(address(child));
        vm.prank(principal);
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        fv.takeBackFromChild(address(child), left, "");
        vm.prank(principal);
        fv.takeBackFromChild(address(child), left - CREST_FEE, "all but the child's fee owed");
        assertEq(usdc.balanceOf(address(child)), CREST_FEE);
    }

    function test_attack_aPaymentThatWouldDipIntoTheFeeOwed_refused() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        uint256 spare = usdc.balanceOf(address(fv)) - CREST_FEE - HOLD;
        vm.prank(principal);
        fv.withdraw(principal, spare, "");
        _expectRefused(
            _vterms(address(fv), buyer), BUYER_PK, abi.encodeWithSelector(ICrestVault.BalanceBelowFee.selector)
        );
        usdc.mint(address(fv), CREST_FEE);
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        assertEq(usdc.balanceOf(address(fv)), 2 * CREST_FEE, "only the fees owed remain");
    }

    // Collecting

    function test_theSweeperCollectsExactlyTheFeeOwed_andForwardsIt() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        uint256 balance = usdc.balanceOf(address(fv));
        vm.expectEmit(address(fv));
        emit ICrestVault.FeeCollected(address(sweeper), CREST_FEE, address(sweeper));
        vm.prank(stranger);
        assertEq(sweeper.sweep(fv), CREST_FEE);
        assertEq(usdc.balanceOf(destination), CREST_FEE);
        assertEq(usdc.balanceOf(address(fv)), balance - CREST_FEE);
        assertEq(fv.feeOwed(), 0);
        vm.prank(stranger);
        assertEq(sweeper.sweep(fv), 0, "a second sweep takes nothing");
        assertEq(usdc.balanceOf(destination), CREST_FEE);
    }

    function test_anyoneCanHaveTheFeePaid_butOnlyToTheFixedSweeper() public {
        _fundVia(_vterms(address(fv), buyer), BUYER_PK);
        vm.prank(stranger);
        assertEq(fv.collectFee(), CREST_FEE);
        assertEq(usdc.balanceOf(address(sweeper)), CREST_FEE);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    /// A vault of another factory pays only its own sweeper, even when this sweeper sweeps it.
    function test_attack_aVaultFromAnotherFactory_paysOnlyItsOwnSweeper() public {
        CrestFeeSweeper otherSweeper = new CrestFeeSweeper(makeAddr("another destination"));
        CrestFactory otherFactory = new CrestFactory(RATE, address(otherSweeper));
        CrestVault ov = CrestVault(otherFactory.create(principal, address(usdc), bytes32("other")));
        vm.startPrank(principal);
        ov.setModule(address(module), module.payee(), "");
        uint256 og = ov.grant(ROOT, buyer, _caps(2 * HOLD, 10 * HOLD, type(uint128).max, 5, true, true), 0, "");
        ov.allow(og, _merchant(), true, "");
        vm.stopPrank();
        usdc.mint(address(ov), 2 * HOLD);
        _fundVia(_vterms(address(ov), buyer), BUYER_PK);
        sweeper.sweep(ov);
        assertEq(usdc.balanceOf(destination), 0, "this sweeper's destination gets nothing of the other vault");
        assertEq(usdc.balanceOf(makeAddr("another destination")), 0);
        assertEq(usdc.balanceOf(address(otherSweeper)), CREST_FEE, "the other vault paid its own sweeper");
    }

    // A broken or hostile sweeper costs at most the fee owed

    function test_attack_aHostileSweeperTakesMoreOrTwice_orReenters() public {
        HookToken hook = new HookToken();
        HostileSweeper hostile = new HostileSweeper();
        (CrestVault hv, PayModule pay, uint256 hg) = _hookWorld(hook, address(hostile));
        hostile.aim(hv);
        pay.pay(hv, buyer, 1_000_000, keccak256("anyone"));
        uint256 owed = hv.feeOwed();
        uint256 before = hook.balanceOf(address(hv));
        hv.collectFee();
        assertEq(hook.balanceOf(address(hostile)), owed, "the sweeper got exactly the fee owed");
        assertEq(hook.balanceOf(address(hv)), before - owed, "nothing else left the vault");
        assertEq(hv.feeOwed(), 0);
        assertEq(_grantOf(hv, hg).spent, 1_000_000 + owed);
    }

    /// A token that refuses the sweeper's forward fails only the sweep; the vault's payments go on.
    function test_aForwardTheTokenRefuses_leavesPaymentsUntouched() public {
        HookToken hook = new HookToken();
        CrestFeeSweeper s = new CrestFeeSweeper(destination);
        (CrestVault hv, PayModule pay,) = _hookWorld(hook, address(s));
        pay.pay(hv, buyer, 1_000_000, keccak256("anyone"));
        uint256 owed = hv.feeOwed();
        hook.refuse(destination);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        s.sweep(hv);
        assertEq(hv.feeOwed(), owed, "the fee is still owed");
        pay.pay(hv, buyer, 1_000_000, keccak256("anyone"));
        assertEq(hv.feeOwed(), 2 * owed, "payments go on");
        hook.refuse(address(0));
        s.sweep(hv);
        assertEq(hook.balanceOf(destination), 2 * owed);
    }

    function test_attack_aSweeperToNoOne_refused() public {
        vm.expectRevert(ICrestFeeSweeper.ZeroDestination.selector);
        new CrestFeeSweeper(address(0));
    }

    // Rounding

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_theFeeRoundsDown_andNeverPassesTheRate(uint16 rate, uint64 amount) public {
        rate = uint16(bound(rate, 1, 10_000));
        amount = uint64(bound(amount, 1, type(uint64).max));
        HookToken t = new HookToken();
        CrestFeeSweeper s = new CrestFeeSweeper(destination);
        CrestFactory f = new CrestFactory(rate, address(s));
        CrestVault v = CrestVault(f.create(principal, address(t), bytes32("fuzz")));
        PayModule pay = new PayModule(address(t));
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        t.mint(address(v), 2 * uint256(amount) + 1);
        pay.pay(v, buyer, amount, keccak256("anyone"));
        assertEq(v.feeOwed(), uint256(amount) * rate / 10_000);
        assertLe(v.feeOwed() * 10_000, uint256(amount) * rate);
    }

    function test_theTopRate_roundsAtOneBaseUnit() public {
        HookToken t = new HookToken();
        CrestFeeSweeper s = new CrestFeeSweeper(destination);
        for (uint256 i; i < 2; ++i) {
            CrestFactory f = new CrestFactory(i == 0 ? 10_000 : 9_999, address(s));
            CrestVault v = CrestVault(f.create(principal, address(t), bytes32("top")));
            PayModule pay = new PayModule(address(t));
            vm.startPrank(principal);
            v.setModule(address(pay), address(pay), "");
            v.grant(ROOT, buyer, _wide(), 0, "");
            vm.stopPrank();
            t.mint(address(v), 2);
            pay.pay(v, buyer, 1, keccak256("anyone"));
            assertEq(v.feeOwed(), i == 0 ? 1 : 0, "10,000 bps owes the whole unit; 9,999 bps rounds down to 0");
        }
    }

    // A rate of 0

    function test_atRateZero_aPaymentOwesNothing_andMovesNothingExtra() public {
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        assertEq(vault.feeOwed(), 0);
        assertEq(vault.collectFee(), 0);
        uint256 all = usdc.balanceOf(address(vault));
        vm.prank(principal);
        vault.withdraw(principal, all, "everything");
    }

    function test_gas_aFundingAtRateZero() public {
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory a = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agree(t, BUYER_PK);
        uint256 before = gasleft();
        module.agreeAndFund(t, s, a, ag, H.Funding({signature: new bytes(65)}));
        emit log_named_uint("a funding at rate 0, execution gas", before - gasleft());
    }

    // Helpers

    function _hookWorld(HookToken t, address feeSweeper) internal returns (CrestVault v, PayModule pay, uint256 g) {
        CrestFactory f = new CrestFactory(RATE, feeSweeper);
        v = CrestVault(f.create(principal, address(t), bytes32("hook")));
        pay = new PayModule(address(t));
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        g = v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        t.mint(address(v), 100_000_000);
    }

    function _signedGrantDigest(CrestVault v, ICrestVault.SignedGrant memory s) internal view returns (bytes32) {
        bytes32 capsHash = keccak256(
            abi.encode(
                keccak256(
                    "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool restricted,bool mayDelegate)"
                ),
                s.caps
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,bytes32[] counterparties,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool restricted,bool mayDelegate)"
                ),
                s.parent,
                s.controller,
                capsHash,
                s.salt,
                keccak256(abi.encodePacked(s.counterparties)),
                s.deadline,
                keccak256(s.note)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(v)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
