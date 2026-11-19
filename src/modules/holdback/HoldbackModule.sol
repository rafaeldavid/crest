// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {ICrestEscrowModule, ICrestVault} from "../../ICrestVault.sol";
import {IHoldbackModule} from "./IHoldbackModule.sol";

/// @title HoldbackModule
/// @notice Pays a Holdback hold from a Crest vault. `IHoldbackModule` describes every function and error.
contract HoldbackModule is IHoldbackModule, ICrestEscrowModule {
    HoldbackRules public immutable RULES;
    AuthCaptureEscrow internal immutable ESCROW;
    address internal immutable COLLECTOR;
    address internal immutable TOKEN;
    uint64 internal immutable EXPIRY_MARGIN;

    constructor(HoldbackRules rules) {
        RULES = rules;
        ESCROW = rules.ESCROW();
        COLLECTOR = rules.ERC3009_COLLECTOR();
        TOKEN = rules.TOKEN();
        EXPIRY_MARGIN = rules.EXPIRY_MARGIN();
    }

    /// @inheritdoc IHoldbackModule
    function agreeAndFund(
        H.Terms calldata t,
        bytes calldata sellerSignature,
        H.Acceptance calldata acc,
        H.Agree calldata ag,
        H.Funding calldata f
    ) external returns (bytes32 id) {
        if (f.signature.length != 65) revert FundingSignatureNot65Bytes();
        bytes32 commitment = H.commitmentId(t);
        ICrestVault(t.buyerPaymentAddress).charge(
            t.buyer,
            t.price + t.fee,
            counterpartyOf(t.sellerPayoutAddress, t.adjudicator, t.fallbackAdjudicator, t.appealAdjudicator),
            commitment,
            t.timing.fundBy,
            _nonce(t, commitment)
        );
        id = RULES.agreeAndFund(t, sellerSignature, acc, ag, f);
    }

    /// @inheritdoc IHoldbackModule
    function close(H.Terms calldata t) external {
        bytes32 id = H.commitmentId(t);
        IHoldbackRules.Stage s = RULES.dealOf(id).stage;
        bool ended = s == IHoldbackRules.Stage.Released || s == IHoldbackRules.Stage.Refunded
            || s == IHoldbackRules.Stage.Settled;
        if (!ended && block.timestamp < _expiry(t)) revert NotEnded();
        ICrestVault(t.buyerPaymentAddress).endCommitment(id);
    }

    /// @inheritdoc IHoldbackModule
    function counterpartyOf(address payout, address adjudicator, address fallbackAdjudicator, address appealAdjudicator)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(payout, adjudicator, fallbackAdjudicator, appealAdjudicator));
    }

    /// @inheritdoc IHoldbackModule
    function payee() external view returns (address) {
        return COLLECTOR;
    }

    /// @inheritdoc IHoldbackModule
    function escrow() external view override(IHoldbackModule, ICrestEscrowModule) returns (address) {
        return address(ESCROW);
    }

    function _expiry(H.Terms calldata t) internal view returns (uint256) {
        return uint256(t.timing.fallbackBy) + t.timing.appealDecideSec + EXPIRY_MARGIN;
    }

    function _nonce(H.Terms calldata t, bytes32 id) internal view returns (bytes32) {
        uint48 expiry = uint48(_expiry(t));
        return ESCROW.getHash(
            AuthCaptureEscrow.PaymentInfo({
                operator: address(RULES),
                payer: address(0),
                receiver: t.sellerPayoutAddress,
                token: TOKEN,
                maxAmount: uint120(t.price + t.fee),
                preApprovalExpiry: uint48(t.timing.fundBy),
                authorizationExpiry: expiry,
                refundExpiry: expiry,
                minFeeBps: 0,
                maxFeeBps: 10_000,
                feeReceiver: address(0),
                salt: uint256(id)
            })
        );
    }
}
