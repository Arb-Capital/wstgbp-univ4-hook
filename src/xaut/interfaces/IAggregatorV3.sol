// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAggregatorV3
/// @notice Minimal Chainlink AggregatorV3Interface, vendored for the XAUT/wstGBP venue
///         (the repo carries no Chainlink dependency).
/// @dev Source: smartcontractkit/chainlink `AggregatorV3Interface.sol` (MIT), trimmed to the
///      two functions this venue reads. `latestRoundData` is always called via a guarded raw
///      `staticcall` (see `OracleLib`) so a misbehaving feed can never revert a swap.
interface IAggregatorV3 {
    /// @notice Feed decimals (8 for both the mainnet XAU/USD and GBP/USD feeds; asserted once
    ///         at deployment, never per swap).
    function decimals() external view returns (uint8);

    /// @notice Latest round: only `answer` and `updatedAt` are consumed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
