// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IPicweUSD.sol";
import "./IAuctionStructsEvents.sol";
import "./AuctionInternal.sol";

contract picwe_auction is AccessControl, Pausable, IAuctionStructsEvents, AuctionInternal {
    IPicweUSD public picweUSD;
    mapping(address => bool) public supportedStableCoins;
    mapping(address => mapping(address => uint256)) public traderTokenBalances;
    mapping(address => bool) public supportedTokens;
    address[] public supportedTokenList;

    bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
    bytes32 public constant TRANSFER_MANAGER_ROLE = keccak256("TRANSFER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    mapping(uint256 => TradeRequest) public auctions;
    mapping(uint256 => uint256) public auctionIdToActiveIndex;

    // uint256[] public auctionIds;
    uint256 public auctionCount;
    uint256[] public activeAuctionIds;
    uint256 public activeAuctionCount;

    uint8 public precisionFactor = 9;
    bool public escapeMode = false;

    constructor(address _picweUSDAddress, address _stableCoinAddress, address _trader) {
        supportedStableCoins[_stableCoinAddress] = true;
        supportedStableCoins[_picweUSDAddress] = true;
        picweUSD = IPicweUSD(_picweUSDAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TRADER_ROLE, _trader);
        _grantRole(TRANSFER_MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, _trader);
    }
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _removeFromActiveAuctions(uint256 _requestId) internal {
        uint256 index = auctionIdToActiveIndex[_requestId];
        uint256 lastAuctionId = activeAuctionIds[activeAuctionIds.length - 1];
        activeAuctionIds[index] = lastAuctionId;
        auctionIdToActiveIndex[lastAuctionId] = index;
        activeAuctionIds.pop();
        delete auctionIdToActiveIndex[_requestId];
        activeAuctionCount--;
    }

    /////////////////////////////////
    ////// Auction MANAGEMENT //////
    ////////////////////////////////

    /**
     * @dev 
     * This function is used to create a new auction request. The auction can be for buying or selling tokens.
     * 
     * @param _requestId The unique identifier for the auction request.
     * @param _targetchainId The ID of the target chain, which must match the current chain ID.
     * @param _trader The address of the trader initiating the auction.
     * @param _tokenAddress The address of the token.
     * @param _stableCoinAddress The address of the stable coin.
     * @param _stableCoinAmount If it's a buy auction, this is the amount of stable coins to be purchased; if it's a sell auction, this is the minimum amount of stable coins to be received.
     * @param _tokenAmount If it's a buy auction, this is the minimum amount of tokens to be received; if it's a sell auction, this is the amount of tokens to be sold.
     * @param _startPrice If it's a buy auction, this is the minimum buy price; if it's a sell auction, this is the maximum sell price.
     * @param _endPrice If it's a buy auction, this is the maximum buy price; if it's a sell auction, this is the minimum sell price.
     * @param _duration The duration of the auction in seconds.
     * @param _isBuy Indicates whether this is a buy auction or a sell auction.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     * @notice An AuctionCreated event will be triggered after the auction is created.
     */
    function createAuction(
        uint256 _requestId,
        uint256 _targetchainId,
        address _trader,
        address _tokenAddress, 
        address _stableCoinAddress,
        uint256 _stableCoinAmount, 
        uint256 _tokenAmount, 
        uint256 _startPrice, 
        uint256 _endPrice,
        uint256 _duration,
        bool _isBuy
    ) 
        public 
        onlyRole(TRADER_ROLE)
    {

        if (_isBuy) {
            require(_startPrice <= _endPrice, "Start price must be <= end price for buys");
            // require(IERC20(_stableCoinAddress).balanceOf(address(this)) >= convertDecimals(_stableCoinAmount, 18, IERC20Metadata(_stableCoinAddress).decimals()), "Insufficient stable coin balance for buy auction");
        } else {
            require(_startPrice >= _endPrice, "Start price must be >= end price for sells");
            // require(IERC20(_tokenAddress).balanceOf(address(this)) >= convertDecimals(_tokenAmount, 18, IERC20Metadata(_tokenAddress).decimals()), "Insufficient token balance for sell auction");
        }
        require(_stableCoinAmount > 0, "Stable coin amount must be > 0");
        require(_tokenAmount > 0, "Token amount must be > 0");
        require(_duration > 0, "Duration must be > 0");
        require(_targetchainId == block.chainid, "Target chain ID must match current chain ID");
        require(supportedStableCoins[_stableCoinAddress], "Unsupported stable coin");
        require(_requestId != 0, "Invalid requestId");
        require(auctions[_requestId].requestId == 0, "Auction already exists");
        // Check if the token address is supported by the contract and if it is, add it to the supported tokens list
        if (!supportedTokens[_tokenAddress]) {
            supportedTokens[_tokenAddress] = true;
            supportedTokenList.push(_tokenAddress);
        }
        auctions[_requestId] = TradeRequest({
            requestId: _requestId,
            targetchainId: _targetchainId,
            trader: _trader,
            tokenAddress: _tokenAddress,
            stableCoinAddress: _stableCoinAddress,
            stableCoinAmount: _stableCoinAmount,
            tokenAmount: _tokenAmount,
            startPrice: _startPrice,
            endPrice: _endPrice,
            startTime: block.timestamp,
            endTime: block.timestamp +_duration,
            isBuy: _isBuy,
            isActive: true
        });
        activeAuctionIds.push(_requestId);
        auctionIdToActiveIndex[_requestId] = activeAuctionCount;
        activeAuctionCount++;
        auctionCount++;

        emit AuctionCreated(
            _requestId,
            _targetchainId,
            _trader,
            _tokenAddress, 
            _stableCoinAddress,
            _stableCoinAmount, 
            _tokenAmount,
            _startPrice,
            _endPrice,
            block.timestamp,
            block.timestamp +_duration,
            _isBuy
        );
    }

    /**
     * @dev Cancels an active auction.
     * 
     * @param _requestId The unique identifier for the auction request.
     * 
     * @notice This function can only be called by the auction creator or the contract owner.
     */
    function cancelAuction(uint256 _requestId) public onlyRole(TRADER_ROLE){
        TradeRequest storage auction = auctions[_requestId];
        require(auction.isActive, "Auction is not active"); 
        auction.isActive = false;
        _removeFromActiveAuctions(_requestId);
        emit AuctionCancelled(
            _requestId,
            auction.trader,
            auction.tokenAddress,
            auction.stableCoinAddress,
            auction.stableCoinAmount,
            auction.tokenAmount,
            auction.startPrice,
            auction.endPrice,
            auction.startTime,
            auction.endTime,
            auction.isBuy
        );
    }

    /**
     * @dev Batch create multiple auctions
     * @param _requestIds Array of unique identifiers for the auction requests
     * @param _targetchainIds Array of target chain IDs
     * @param _traders Array of trader addresses
     * @param _tokenAddresses Array of token addresses
     * @param _stableCoinAddresses Array of stable coin addresses
     * @param _stableCoinAmounts Array of stable coin amounts
     * @param _tokenAmounts Array of token amounts
     * @param _startPrices Array of start prices
     * @param _endPrices Array of end prices
     * @param _durations Array of auction durations
     * @param _isBuys Array of boolean flags indicating buy or sell auctions
     */
    function batchCreateAuctions(
        uint256[] memory _requestIds,
        uint256[] memory _targetchainIds,
        address[] memory _traders,
        address[] memory _tokenAddresses,
        address[] memory _stableCoinAddresses,
        uint256[] memory _stableCoinAmounts,
        uint256[] memory _tokenAmounts,
        uint256[] memory _startPrices,
        uint256[] memory _endPrices,
        uint256[] memory _durations,
        bool[] memory _isBuys
    ) 
        public 
        onlyRole(TRADER_ROLE)
    {
        require(
            _requestIds.length == _targetchainIds.length &&
            _requestIds.length == _traders.length &&
            _requestIds.length == _tokenAddresses.length &&
            _requestIds.length == _stableCoinAddresses.length &&
            _requestIds.length == _stableCoinAmounts.length &&
            _requestIds.length == _tokenAmounts.length &&
            _requestIds.length == _startPrices.length &&
            _requestIds.length == _endPrices.length &&
            _requestIds.length == _durations.length &&
            _requestIds.length == _isBuys.length,
            "Input arrays must have the same length"
        );

        for (uint256 i = 0; i < _requestIds.length; i++) {
            createAuction(
                _requestIds[i],
                _targetchainIds[i],
                _traders[i],
                _tokenAddresses[i],
                _stableCoinAddresses[i],
                _stableCoinAmounts[i],
                _tokenAmounts[i],
                _startPrices[i],
                _endPrices[i],
                _durations[i],
                _isBuys[i]
            );
        }
    }

    /**
     * @dev Batch cancel multiple active auctions
     * @param _requestIds Array of unique identifiers for the auction requests to be cancelled
     */
    function batchCancelAuctions(uint256[] memory _requestIds) public onlyRole(TRADER_ROLE) {
        for (uint256 i = 0; i < _requestIds.length; i++) {
            cancelAuction(_requestIds[i]);
        }
    }

    ///////////////////////
    ////// Auction  //////
    //////////////////////

    /**
     * @dev 
     * This function is used to proxy a buy auction. The auction must be active and must be a buy auction.
     * 
     * @param _requestId The unique identifier for the auction request.
     * 
     * @notice This function can only be called by users.
     * @notice An AuctionEnded event will be triggered after the auction is ended.
     */
    function proxyBuy(uint256 _requestId) public whenNotPaused {
        TradeRequest storage auction = auctions[_requestId];
        uint8 stableCoinDecimals = IERC20Metadata(auction.stableCoinAddress).decimals();
        uint8 tokenDecimals = IERC20Metadata(auction.tokenAddress).decimals();
        uint256 currentPrice = getCurrentPrice(auction);
        uint256 adjustedCurrentPrice = currentPrice / (10**precisionFactor);
        uint256 tokenAmount = (auction.stableCoinAmount * (10**(18-precisionFactor))) / adjustedCurrentPrice;
        require(auction.isActive, "Auction inactive");
        require(auction.isBuy, "Not a buy auction");
        require(IERC20(auction.tokenAddress).transferFrom(msg.sender, address(this), convertDecimalsCeil(tokenAmount, 18, tokenDecimals)), 
                "Token transfer failed");
        picweUSD.mint(msg.sender, convertDecimals(auction.stableCoinAmount, 18, stableCoinDecimals));
        auction.isActive = false; // Set the auction's active status to inactive
        _removeFromActiveAuctions(_requestId);
        traderTokenBalances[auction.trader][auction.tokenAddress] += tokenAmount;
        
        emit AuctionEnded(
            _requestId,
            auction.trader,
            msg.sender,
            auction.tokenAddress,
            auction.stableCoinAddress,
            auction.stableCoinAmount,
            tokenAmount,
            currentPrice,
            block.timestamp,
            auction.isBuy
        );   
    }
    
    /**
     * @dev 
     * This function is used to proxy a sell auction. The auction must be active and must be a sell auction.
     * 
     * @param _requestId The unique identifier for the auction request.
     * 
     * @notice This function can only be called by users.
     * @notice An AuctionEnded event will be triggered after the auction is ended.
     */
    function proxySell(uint256 _requestId) public whenNotPaused {
        TradeRequest storage auction = auctions[_requestId];
        uint8 stableCoinDecimals = IERC20Metadata(auction.stableCoinAddress).decimals();
        uint8 tokenDecimals = IERC20Metadata(auction.tokenAddress).decimals();
        uint256 currentPrice = getCurrentPrice(auction);
        uint256 adjustedCurrentPrice = currentPrice / (10**precisionFactor);
        uint256 stableCoinAmount = (auction.tokenAmount * adjustedCurrentPrice) / (10**(18-precisionFactor));
        require(auction.isActive, "Auction inactive");
        require(!auction.isBuy, "Not a sell auction");
        picweUSD.burnFrom(msg.sender, convertDecimalsCeil(stableCoinAmount, 18, stableCoinDecimals));
        require(IERC20(auction.tokenAddress).transfer(msg.sender, convertDecimals(auction.tokenAmount, 18, tokenDecimals)), 
                "Token transfer failed");
        auction.isActive = false; // Set the auction's active status to inactive
        traderTokenBalances[auction.trader][auction.tokenAddress] -= auction.tokenAmount;
        _removeFromActiveAuctions(_requestId);

        emit AuctionEnded(
            _requestId,
            auction.trader,
            msg.sender,
            auction.tokenAddress,
            auction.stableCoinAddress,
            stableCoinAmount,
            auction.tokenAmount,
            currentPrice,
            block.timestamp,
            auction.isBuy
        );   
    }

    ////////////////////////////////////
    ////// STABLE COIN MANAGEMENT //////
    ///////////////////////////////////
    /**
     * @dev 
     * This function is used to add a new stable coin to the supported stable coins.
     * 
     * @param token The address of the stable coin to add.
     * 
     * @notice This function can only be called by users with the DEFAULT_ADMIN_ROLE.
     * @notice A StableCoinAdded event will be triggered after the stable coin is added.
     */
    function addStableCoin(address token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!supportedStableCoins[token], "Token already supported");
        supportedStableCoins[token] = true;
        emit StableCoinAdded(token);
    }

    /**
     * @dev 
     * This function is used to remove a stable coin from the supported stable coins.
     * 
     * @param token The address of the stable coin to remove.
     * 
     * @notice This function can only be called by users with the DEFAULT_ADMIN_ROLE.
     * @notice A StableCoinRemoved event will be triggered after the stable coin is removed.
     */
    function removeStableCoin(address token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(supportedStableCoins[token], "Token not supported");
        supportedStableCoins[token] = false;
        emit StableCoinRemoved(token);
    }

    /**
     * @dev Sets the precision factor.
     * @param _precisionFactor The new precision factor.
     */
    function setPrecisionFactor(uint8 _precisionFactor) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_precisionFactor >= 1 && _precisionFactor <= 18, "Precision factor must be between 1 and 18");
        precisionFactor = _precisionFactor;
    }
    
    /////////////////////////////////
    ////// Trasfer MANAGEMENT //////
    ////////////////////////////////
    /**
     * @dev 
     * This function is used to transfer stable coins from the contract to another address.
     * 
     * @param token The address of the stable coin to transfer.
     * @param to The address to transfer the stable coins to.
     * @param amount The amount of stable coins to transfer.
     * 
     * @notice This function can only be called by users with the TRANSFER_MANAGER_ROLE.
     */
    function transferStableCoin(address token, address to, uint256 amount) public onlyRole(TRANSFER_MANAGER_ROLE) {
        require(supportedStableCoins[token], "Token not supported");
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        IERC20(token).transfer(to, amount);
        emit StableCoinTransferred(token, to, amount);
    }

    /**
     * @dev 
     * This function is used to transfer tokens to a specific trader based on their balance in traderTokenBalances.
     * 
     * @param trader The address of the trader to transfer tokens to.
     * @param tokenAddress The address of the token to transfer.
     * 
     * @notice This function can only be called by users with the TRANSFER_MANAGER_ROLE.
     */
    function transferTokensToTrader(address trader, address tokenAddress) public onlyRole(TRANSFER_MANAGER_ROLE) {
        uint256 balance = traderTokenBalances[trader][tokenAddress];
        if (balance > 0) {
            IERC20(tokenAddress).transfer(trader, balance);
            // Reset the balance after transfer
            traderTokenBalances[trader][tokenAddress] = 0;
            emit TokensTransferred(trader, tokenAddress, balance);
        }
    }

    /////////////////////
    ////// Getter //////
    ////////////////////


    /**
     * @dev Get active auction IDs with pagination
     * @param pageSize The number of auctions per page. Set to 0 to return all active auctions.
     * @param page The page number to retrieve, starting from 0.
     * @param showAll If true, return all active auctions regardless of pageSize and page
     * @return An array of active auction IDs, sorted with newest first
     */
    function getActiveAuctionIds(uint256 pageSize, uint256 page, bool showAll) public view returns (uint256[] memory) {
        uint256 resultSize;
        uint256 startIndex;
        
        if (showAll) {
            resultSize = activeAuctionCount;
            startIndex = 0;
        } else {
            startIndex = activeAuctionCount - (page * pageSize) - pageSize;
            uint256 endIndex = activeAuctionCount - (page * pageSize);
            
            if (startIndex < 0) {
                startIndex = 0;
            }
            
            resultSize = endIndex - startIndex;
        }
        
        uint256[] memory result = new uint256[](resultSize);
        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = activeAuctionIds[activeAuctionCount - i - 1 - startIndex];
        }
        return result;
    }

    /**
     * @dev Get active auction data with pagination
     * @param pageSize The number of auctions per page. Set to 0 to return all active auctions.
     * @param page The page number to retrieve, starting from 0.
     * @param showAll If true, return all active auctions regardless of pageSize and page
     * @return An array of TradeRequest structs containing active auction data, sorted with newest first
     */
    function getActiveAuctionsData(uint256 pageSize, uint256 page, bool showAll) public view returns (TradeRequest[] memory) {
        uint256[] memory activeAuction = getActiveAuctionIds(pageSize, page, showAll);
        TradeRequest[] memory auctionsData = new TradeRequest[](activeAuction.length);
        for (uint256 i = 0; i < activeAuction.length; i++) {
            auctionsData[i] = auctions[activeAuction[i]];
        }
        return auctionsData;
    }

    /**
     * @dev 
     * Get the token balance of a specific trader for a specific token
     * 
     * @param trader The address of the trader
     * @param tokenAddress The address of the token
     * @return The balance of the specified token held by the trader
     */
    function getTraderTokenBalance(address trader, address tokenAddress) public view returns (uint256) {
        return traderTokenBalances[trader][tokenAddress];
    }

    /**
     * @dev 
     * Retrieves detailed information of an auction using the auction ID.
     * 
     * @param requestId The unique identifier of the auction.
     * @return Returns detailed information of the auction with the specified ID.
     */
    function getAuctionDetails(uint256 requestId) public view returns (TradeRequest memory) {
        return auctions[requestId];
    }

    /**
     * @dev Retrieves the target chain ID of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The target chain ID of the auction.
     */
    function getAuctionTargetChainId(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].targetchainId;
    }

    /**
     * @dev Retrieves the trader address of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The trader address of the auction.
     */
    function getAuctionTrader(uint256 requestId) public view returns (address) {
        return auctions[requestId].trader;
    }

    /**
     * @dev Retrieves the token address of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The token address of the auction.
     */
    function getAuctionTokenAddress(uint256 requestId) public view returns (address) {
        return auctions[requestId].tokenAddress;
    }

    /**
     * @dev Retrieves the stable coin address of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The stable coin address of the auction.
     */
    function getAuctionStableCoinAddress(uint256 requestId) public view returns (address) {
        return auctions[requestId].stableCoinAddress;
    }

    /**
     * @dev Retrieves the stable coin amount of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The stable coin amount of the auction.
     */
    function getAuctionStableCoinAmount(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].stableCoinAmount;
    }

    /**
     * @dev Retrieves the token amount of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The token amount of the auction.
     */
    function getAuctionTokenAmount(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].tokenAmount;
    }

    /**
     * @dev Retrieves the start price of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The start price of the auction.
     */
    function getAuctionStartPrice(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].startPrice;
    }

    /**
     * @dev Retrieves the end price of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The end price of the auction.
     */
    function getAuctionEndPrice(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].endPrice;
    }

    /**
     * @dev Retrieves the start time of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The start time of the auction.
     */
    function getAuctionStartTime(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].startTime;
    }

    /**
     * @dev Retrieves the end time of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return The end time of the auction.
     */
    function getAuctionEndTime(uint256 requestId) public view returns (uint256) {
        return auctions[requestId].endTime;
    }

    /**
     * @dev Retrieves the buy status of a specific auction.
     * @param requestId The unique identifier of the auction.
     * @return True if the auction is a buy auction, false otherwise.
     */
    function getAuctionIsBuy(uint256 requestId) public view returns (bool) {
        return auctions[requestId].isBuy;
    }

    /**
    * @dev checkAuctionExistsAndActive
    * @param requestId The unique identifier of the auction.
    * @return exists The auction exists
    * @return isActive The auction is active
    */
    function checkAuctionExistsAndActive(uint256 requestId) public view returns (bool exists, bool isActive) {
        TradeRequest storage auction = auctions[requestId];
        exists = (auction.requestId != 0);
        isActive = auction.isActive;
        return (exists, isActive);
    }

    /**
    * @dev batchGetAuctionStatus
    * @param requestIds The array of auction IDs to check.
    * @return Two boolean arrays, the first indicating whether the auction exists, and the second indicating whether the auction is active.
    */
    function batchGetAuctionStatus(uint256[] memory requestIds) public view returns (bool[] memory, bool[] memory) {
        bool[] memory existsArray = new bool[](requestIds.length);
        bool[] memory isActiveArray = new bool[](requestIds.length);

        for (uint256 i = 0; i < requestIds.length; i++) {
            TradeRequest storage auction = auctions[requestIds[i]];
            existsArray[i] = (auction.requestId != 0); 
            isActiveArray[i] = auction.isActive;
        }
        return (existsArray, isActiveArray);
    }


    /**
     * @dev Get all token balances for a specific trader
     * @param trader The address of the trader
     * @param page The page number
     * @param pageSize The number of items per page
     * @return tokenAddresses Array of token addresses
     * @return balances Array of corresponding balances
     */
    function getAllTraderTokenBalances(address trader, uint256 page, uint256 pageSize) public view returns (address[] memory tokenAddresses, uint256[] memory balances) {
        uint256 start = page * pageSize;
        uint256 end = start + pageSize;
        if (end > supportedTokenList.length) {
            end = supportedTokenList.length;
        }

        uint256 count = 0;
        for (uint256 i = start; i < end; i++) {
            if (traderTokenBalances[trader][supportedTokenList[i]] > 0) {
                count++;
            }
        }

        tokenAddresses = new address[](count);
        balances = new uint256[](count);

        uint256 index = 0;
        for (uint256 i = start; i < end; i++) {
            uint256 balance = traderTokenBalances[trader][supportedTokenList[i]];
            if (balance > 0) {
                tokenAddresses[index] = supportedTokenList[i];
                balances[index] = balance;
                index++;
            }
        }

        return (tokenAddresses, balances);
    }

    /**
     * @dev Get all incomplete auctions for a specific token address, along with their current prices and buy/sell directions
     * @param targettokenAddress The target token address
     * @return requestIds Array of IDs for incomplete auctions
     * @return currentPrices Array of current prices for incomplete auctions
     * @return isBuyArray Array of buy/sell directions for incomplete auctions (true for buy, false for sell)
     */
    function getIncompleteAuctionsByToken(address targettokenAddress) public view returns (uint256[] memory requestIds, uint256[] memory currentPrices, bool[] memory isBuyArray) {
        uint256 count = 0;

        for (uint256 i = 0; i < activeAuctionCount; i++) {
            if (auctions[activeAuctionIds[i]].tokenAddress == targettokenAddress) {
                count++;
            }
        }

        requestIds = new uint256[](count);
        currentPrices = new uint256[](count);
        isBuyArray = new bool[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < activeAuctionCount; i++) {
            if (auctions[activeAuctionIds[i]].tokenAddress == targettokenAddress) {
                requestIds[index] = activeAuctionIds[i];
                currentPrices[index] = getCurrentPrice(auctions[activeAuctionIds[i]]);
                isBuyArray[index] = auctions[activeAuctionIds[i]].isBuy;
                index++;
            }
        }
        
        return (requestIds, currentPrices, isBuyArray);
    }


    /////////////////////////////////
    ////// Token MANAGEMENT /////////
    /////////////////////////////////

    /**
     * @dev Add a supported token
     * @param token The address of the token to add
     */
    function addSupportedToken(address token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token address");
        require(!supportedTokens[token], "Token already supported");
        supportedTokens[token] = true;
        supportedTokenList.push(token);
        emit TokenAdded(token);
    }

    /**
     * @dev Remove a supported token
     * @param token The address of the token to remove
     */
    function removeSupportedToken(address token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token address");
        require(supportedTokens[token], "Token not supported");
        supportedTokens[token] = false;
        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            if (supportedTokenList[i] == token) {
                supportedTokenList[i] = supportedTokenList[supportedTokenList.length - 1];
                supportedTokenList.pop();
                emit TokenRemoved(token);
                break;
            }
        }
    }

    ///////////////////////////////////////
    ////// ESCAPE MODE MANAGEMENT /////////
    //////////////////////////////////////
    
    /**
     * @dev Enable escape mode
     * Can only be called by the admin
     */
    function enableEscapeMode() public onlyRole(DEFAULT_ADMIN_ROLE) {
        escapeMode = true;
        emit EscapeModeEnabled();
    }

    /**
     * @dev Disable escape mode
     * Can only be called by the admin
     */
    function disableEscapeMode() public onlyRole(DEFAULT_ADMIN_ROLE) {
        escapeMode = false;
        emit EscapeModeDisabled();
    }

    /**
     * @dev Allow customers to withdraw their token balances in escape mode
     * @param tokenAddress The address of the token to withdraw
     */
    function withdrawTokensInEscapeMode(address tokenAddress) public {
        require(escapeMode, "Escape mode is not enabled");
        uint256 balance = traderTokenBalances[msg.sender][tokenAddress];
        require(balance > 0, "No balance to withdraw");

        traderTokenBalances[msg.sender][tokenAddress] = 0;
        IERC20(tokenAddress).transfer(msg.sender, balance);
    }
}