// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./IAuctionStructsEvents.sol";

contract AuctionInternal is IAuctionStructsEvents {
    function convertDecimals(
        uint256 value,
        uint8 sourceDecimals,
        uint8 targetDecimals
    ) internal pure returns (uint256 result) {
        if (sourceDecimals == targetDecimals) {
            result = value;
        } else if (sourceDecimals < targetDecimals) {
            result = value * (10**(targetDecimals - sourceDecimals));
        } else {
            result = value / (10**(sourceDecimals - targetDecimals));
        }
    }

    function convertDecimalsCeil(
        uint256 value,
        uint8 sourceDecimals,
        uint8 targetDecimals
    ) internal pure returns (uint256 result) {
        if (sourceDecimals == targetDecimals) {
            result = value;
        } else if (sourceDecimals < targetDecimals) {
            result = value * (10**(targetDecimals - sourceDecimals));
        } else {
            uint256 temp = 10**(sourceDecimals - targetDecimals);
            result = value / temp;
            if (value % temp != 0) {
                result += 1;
            }
        }
    }

    function getCurrentPrice(TradeRequest memory auction) internal view returns (uint256) {
        uint256 elapsedTime = block.timestamp - auction.startTime;
        uint256 totalDuration = auction.endTime - auction.startTime;

        if (block.timestamp >= auction.endTime) {
            return auction.endPrice;
        }

        uint256 priceRange;
        uint256 priceChange;

        if (auction.isBuy) {
            // Buy operation: Price increases from low to high
            priceRange = auction.endPrice - auction.startPrice;
            priceChange = priceRange * elapsedTime / totalDuration;
            return auction.startPrice + priceChange;
        } else {
            // Sell operation: Price decreases from high to low
            priceRange = auction.startPrice - auction.endPrice;
            priceChange = priceRange * elapsedTime / totalDuration;
            return auction.startPrice - priceChange;
        }
    }
}