// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./IClientStructsEvents.sol";

contract ClientInternal is IClientStructsEvents {
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

    function decodeRequestId(uint256 requestId) internal pure returns (uint256 chainId, uint256 requestCount) {
        chainId = requestId >> 128;
        requestCount = requestId & ((1 << 128) - 1);
    }
}