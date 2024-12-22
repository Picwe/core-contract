// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface IAuctionStructsEvents {
    struct TradeRequest {
        uint256 requestId;
        uint256 targetchainId;
        address trader;
        address tokenAddress;
        address stableCoinAddress;
        uint256 stableCoinAmount;
        uint256 tokenAmount;
        uint256 startPrice;
        uint256 endPrice;
        uint256 startTime;
        uint256 endTime;
        bool isBuy;
        bool isActive;
    }

    event AuctionCreated(
        uint256 indexed requestId,
        uint256 targetchainId,
        address indexed trader,
        address tokenAddress, 
        address stableCoinAddress,
        uint256 stableCoinAmount,
        uint256 tokenAmount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime,
        bool isBuy
    );

    event AuctionEnded(
        uint256 indexed requestId,
        address indexed trader,
        address winner, 
        address tokenAddress,
        address stableCoinAddress,
        uint256 stableCoinAmount, 
        uint256 tokenAmount,
        uint256 finalPrice,
        uint256 finalTime,
        bool isBuy
    );

    event AuctionCancelled(
        uint256 indexed requestId,
        address indexed trader,
        address tokenAddress,
        address stableCoinAddress,
        uint256 stableCoinAmount, 
        uint256 tokenAmount,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime,
        bool isBuy
    );

    event StableCoinAdded(address token);
    event StableCoinRemoved(address token);
    event StableCoinTransferred(address indexed token, address indexed to, uint256 amount);
    event TokenAdded(address token);
    event TokenRemoved(address token);
    event EscapeModeEnabled();
    event EscapeModeDisabled();
    event TokensTransferred(address indexed trader, address indexed tokenAddress, uint256 amount);
    event TokensWithdrawnInEscapeMode(address indexed trader, address indexed tokenAddress, uint256 amount);
}