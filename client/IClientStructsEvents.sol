// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface IClientStructsEvents {
    struct RequestData {
        uint256 requestId;
        address user;
        uint256 targetchainId;
        address targettokenAddress;
        address targetstableCoinAddress;
        address sourceStableCoinAddress;
        uint256 stableCoinAmount;
        uint256 tokenAmount;
        uint256 startPrice;
        uint256 endPrice;
        bool isBuy;
        uint8 status;
    }

    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        uint256 targetchainId,
        address tokenAddress,
        address stableCoinAddress,
        address sourceStableCoinAddress,
        uint256 stableCoinAmount,
        uint256 tokenAmount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 duration,
        bool isBuy
    );

    event RequestCompleted(
        uint256 indexed requestId,
        address indexed user,
        uint256 targetchainId,
        address tokenAddress,
        address stableCoinAddress,
        address sourceStableCoinAddress,
        uint256 stableCoinAmount,
        uint256 tokenAmount,
        uint256 finalPrice,
        bool isBuy
    );

    event RequestCancelled(
        uint256 indexed requestId,
        address indexed user,
        uint256 targetchainId,
        address tokenAddress,
        bool isBuy
    );

    event CancellationInitiated(
        uint256 indexed requestId,
        address indexed user,
        uint256 targetchainId,
        address tokenAddress,
        bool isBuy
    );

    event SourceStableCoinAdded(address token);
    event SourceStableCoinRemoved(address token);
    event StableCoinTransferred(address indexed token, address indexed to, uint256 amount);
    event GasAmountSet(uint256 newGasAmount);
}