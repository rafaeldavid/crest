// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

/// @title IHoldbackModule
/// @notice Pays a hold in Holdback, the escrow behind Crow, from a Crest vault. One module serves one Holdback rules
///         deployment and every vault that enables it; it holds no tokens and no state.
///
///         A deal paid this way names the vault as `buyerPaymentAddress` and the agent's key as `buyer`. Anyone sends
///         the rules contract's own `agreeAndFund` call to this module instead, with the same arguments. The module has
///         the vault charge the agent's grant with the hold (price plus the adjudication fee), for the deal's payout
///         address and its three adjudicators, then forwards the call unchanged. The rules contract checks the
///         seller's, the adjudicator's and the agent's signatures as it always does; the token asks the vault, which
///         approves exactly that hold.
///
///         Why an approved merchant holds through the escrow: Holdback pays a hold out only to the terms' payout
///         address or back to the payment address. So a vault that lists a payout address knows the money can reach
///         only that merchant or come back.
/// @dev The principal enables this module on its vault with the escrow's ERC-3009 collector as the payee (`payee()`). The
///      module derives the escrow's expiry, the payment record and the collector's nonce exactly as the rules contract
///      does (`HoldbackRules._escrowExpiry`, `_paymentInfo`); a wrong derivation fails closed, as the token then refuses
///      the funding.
interface IHoldbackModule {
    error FundingSignatureNot65Bytes();
    error NotEnded();

    /// @notice The rules contract's own funding call, forwarded after the vault has charged the agent's grant.
    /// @param f Its signature is passed on untouched and must be exactly 65 bytes; the vault's approval does not read
    ///        it. Any 65 bytes work, which keeps the call in the API's shape and keeps ERC-6492 hooks out.
    /// @return id The commitment ID.
    function agreeAndFund(
        H.Terms calldata t,
        bytes calldata sellerSignature,
        H.Acceptance calldata acc,
        H.Agree calldata ag,
        H.Funding calldata f
    ) external returns (bytes32 id);

    /// @notice Anyone tells the paying vault that a deal has ended, so its open counts fall: the rules contract's stage
    ///         is Released, Refunded or Settled, or the escrow's expiry has passed, after which no capture can follow.
    function close(H.Terms calldata t) external;

    /// @notice The counterparty key a vault lists to approve a Holdback merchant: its payout address together with the
    ///         three adjudicators the principal accepts for it.
    function counterpartyOf(address payout, address adjudicator, address fallbackAdjudicator, address appealAdjudicator)
        external
        pure
        returns (bytes32);

    /// @notice The address the vault pays: the escrow's ERC-3009 collector.
    function payee() external view returns (address);

    /// @notice The Commerce Payments escrow behind the rules contract, for a vault's `reclaim`.
    function escrow() external view returns (address);
}
