// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IClientStructsEvents.sol";
import "./ClientInternal.sol";

contract picwe_client is AccessControl, Pausable, IClientStructsEvents, ClientInternal {
    bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
    bytes32 public constant TRANSFER_MANAGER_ROLE = keccak256("TRANSFER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    mapping(uint256 => RequestData) private requests;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public balances;
    mapping(address => bool) public supportedStableCoins;
    mapping(uint256 => bool) public requestCancellationInitiated;

    mapping(uint256 => uint256) public requestIdToActiveIndex;

    uint8 constant PENDING = 0;
    uint8 constant FULFILLED = 1;
    uint8 constant CANCELLED = 2;

    // uint256[] public allRequestIds;
    uint256[] public activeRequestIds;
    uint256 public activeRequestCount;
    uint256 public requestCount;

    uint256 public feePercentage = 50;  // 0.5%=50/10000
    uint256 public cancelFeePercentage = 100;  // 1%=100/10000
    uint256 public gasAmount = 5*10**17;  // 0.5 USD
    uint8 public precisionFactor = 9;
    address public feeRecipient;



    constructor(address _feeRecipient, address _stableCoinAddress, address _weusd, address _trader) {
        feeRecipient = _feeRecipient;
        supportedStableCoins[_stableCoinAddress] = true;
        supportedStableCoins[_weusd] = true;
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

    ///////////////////////////////
    ////// FEE MANAGEMENT /////////
    ///////////////////////////////

    /**
     * @dev Sets the fee recipient address.
     * @param _feeRecipient The address to which fees are sent.
     */
    function setFeeRecipient(address _feeRecipient) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeRecipient != address(0), "Invalid address: cannot be zero address");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Sets the fee percentage.
     * @param _feePercentage The new fee percentage.
     */
    function setFeePercentage(uint256 _feePercentage) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feePercentage <= 100, "Fee percentage cannot exceed 100");
        feePercentage = _feePercentage;
    }

    /**
     * @dev Sets the cancellation fee percentage.
     * @param _cancelFeePercentage The new cancellation fee percentage.
     */
    function setCancelFeePercentage(uint256 _cancelFeePercentage) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_cancelFeePercentage <= 100, "Cancellation fee percentage cannot exceed 100");
        cancelFeePercentage = _cancelFeePercentage;
    }

    /**
     * @dev Sets the precision factor.
     * @param _precisionFactor The new precision factor.
     */
    function setPrecisionFactor(uint8 _precisionFactor) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_precisionFactor >= 1 && _precisionFactor <= 18, "Precision factor must be between 1 and 18");
        precisionFactor = _precisionFactor;
    }

    /**
     * @dev Sets the gas amount (gasAmount).
     * @param _gasAmount The new gas amount.
     * 
     * @notice This function can only be called by users with the DEFAULT_ADMIN_ROLE.
     * @notice A GasAmountSet event will be triggered after successful setting.
     */
    function setGasAmount(uint256 _gasAmount) public onlyRole(TRADER_ROLE) {
        require(_gasAmount > 0, "Gas amount must be greater than 0");
        gasAmount = _gasAmount;
        emit GasAmountSet(_gasAmount);
    }

    ///////////////////////////////
    ////// STABLE COIN /////////////
    ///////////////////////////////

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
        emit SourceStableCoinAdded(token);
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
        emit SourceStableCoinRemoved(token);
    }

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

    ///////////////////////////////
    ////// BUY & SELL /////////////
    ///////////////////////////////

    /**
     * @dev 
     * This function is used to buy tokens.
     * 
     * @param _stableCoinAmount The amount of stable coins to use for the purchase.
     * @param _targetchainId The ID of the chain to buy the tokens on.
     * @param _tokenAddress The address of the token to buy.
     * @param _stableCoinAddress The address of the stable coin to use for the purchase.
     * @param _sourceStableCoinAddress The address of the stable coin to use for the purchase.
     * @param _tokenAmount The amount of tokens to buy.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function buyTokens(
        uint256 _stableCoinAmount,
        uint256 _targetchainId,
        address _tokenAddress,
        address _stableCoinAddress,
        address _sourceStableCoinAddress,
        uint256 _tokenAmount,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _duration
    ) public whenNotPaused {
        require(_stableCoinAmount >= gasAmount, "Token amount must be greater than or equal to gas amount");
        uint8 sourceStableCoinDecimals = IERC20Metadata(_sourceStableCoinAddress).decimals();
        uint256 fee = _stableCoinAmount * feePercentage / 10000 + gasAmount;
        uint256 realFee = convertDecimalsCeil(fee, 18, sourceStableCoinDecimals);
        uint256 amountAfterFee = _stableCoinAmount - fee;
        uint256 realAmountAfterFee = convertDecimalsCeil(amountAfterFee, 18, sourceStableCoinDecimals);
        require(supportedStableCoins[_sourceStableCoinAddress], "Token not supported");
        require(IERC20(_sourceStableCoinAddress).transferFrom(msg.sender, address(this), realAmountAfterFee), "Transfer of stable coin failed");
        require(IERC20(_sourceStableCoinAddress).transferFrom(msg.sender, feeRecipient, realFee), "Fee transfer failed");

        createRequest(
            _targetchainId,
            _tokenAddress,
            _stableCoinAddress,
            _sourceStableCoinAddress,
            amountAfterFee,
            _tokenAmount,
            _startPrice,
            _endPrice,
            _duration,
            true
        );
    }

    /**
     * @dev 
     * This function is used to sell tokens.
     * 
     * @param _tokenAmount The amount of tokens to sell.
     * @param _targetchainId The ID of the chain to sell the tokens on.
     * @param _tokenAddress The address of the token to sell.
     * @param _stableCoinAddress The address of the stable coin to use for the purchase.
     * @param _sourceStableCoinAddress The address of the stable coin to use for the purchase.
     * @param _stableCoinAmount The amount of stable coins to use for the purchase.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function sellTokens(
        uint256 _tokenAmount,
        uint256 _targetchainId,
        address _tokenAddress,
        address _stableCoinAddress,
        address _sourceStableCoinAddress,
        uint256 _stableCoinAmount,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _duration
    ) public whenNotPaused {
        validateSellTokenAmount(_stableCoinAmount, _tokenAmount, _startPrice, _endPrice, _targetchainId, _tokenAddress);
        createRequest(
            _targetchainId,
            _tokenAddress,
            _stableCoinAddress,
            _sourceStableCoinAddress,
            _stableCoinAmount,
            _tokenAmount,
            _startPrice,
            _endPrice,
            _duration,
            false
        );

    }

    /////////////////////
    ////// Cancel //////
    ////////////////////

    /**
     * @dev Initiates the cancellation of a buy token request on the source chain.
     * 
     * @param requestId The ID of the request to initiate cancellation.
     * 
     * @notice This function can only be called by the user who created the request or by an admin.
     */
    function initiateCancelBuyToken(uint256 requestId) public whenNotPaused {
        RequestData storage request = requests[requestId];
        require(request.user == msg.sender || hasRole(TRADER_ROLE, msg.sender), "Not authorized to initiate cancel");
        require(request.isBuy, "Not a buy request");
        require(request.status == PENDING, "Request not pending");
        require(!requestCancellationInitiated[requestId], "Cancellation already initiated");

        requestCancellationInitiated[requestId] = true;

        emit CancellationInitiated(
            request.requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.isBuy
        );
    }

    /**
     * @dev Initiates the cancellation of a sell token request on the source chain.
     * 
     * @param requestId The ID of the request to initiate cancellation.
     * 
     * @notice This function can only be called by the user who created the request or an admin.
     */
    function initiateCancelSellToken(uint256 requestId) public whenNotPaused {
        RequestData storage request = requests[requestId];
        require(request.user == msg.sender || hasRole(TRADER_ROLE, msg.sender), "Not authorized to initiate cancel");
        require(!request.isBuy, "Not a sell request");
        require(request.status == PENDING, "Request not pending");
        require(!requestCancellationInitiated[requestId], "Cancellation already initiated");

        // Mark the request as cancellation initiated
        requestCancellationInitiated[requestId] = true;

        emit CancellationInitiated(
            request.requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.isBuy
        );
    }

    /////////////////////////////
    ////// Single processing /////
    ////////////////////////////
    
    /**
     * @dev 
     * This function is used to complete a buy request.
     * 
     * @param requestId The ID of the request to complete.
     * @param finalPrice The final price of the tokens.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function completeBuy(uint256 requestId, uint256 finalPrice) public onlyRole(TRADER_ROLE) {
        RequestData storage request = requests[requestId];
        require(request.status == PENDING, "Request not pending");
        require(request.isBuy, "Not a buy request");
        uint256 adjustedFinalPrice = finalPrice/(10**precisionFactor);
        uint256 receivedAmount = (request.stableCoinAmount * (10**(18-precisionFactor))) / adjustedFinalPrice;
        balances[request.user][request.targetchainId][request.targettokenAddress] += receivedAmount;
        request.status = FULFILLED;
        _removeFromActiveRequests(requestId);
        
        emit RequestCompleted(
            requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.targetstableCoinAddress,
            request.sourceStableCoinAddress,
            request.stableCoinAmount,
            receivedAmount,
            finalPrice,
            request.isBuy
        );
    }

    /**
     * @dev 
     * This function is used to complete a sell request.
     * 
     * @param requestId The ID of the request to complete.
     * @param finalPrice The final price of the tokens.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function completeSell(uint256 requestId, uint256 finalPrice) public onlyRole(TRADER_ROLE) {
        RequestData storage request = requests[requestId];
        require(request.status == PENDING, "Request not pending");
        require(!request.isBuy, "Not a sell request");
        uint8 sourceStableCoinDecimals = IERC20Metadata(request.sourceStableCoinAddress).decimals();
        uint256 adjustedFinalPrice = finalPrice / (10**precisionFactor);
        uint256 receivedAmount = (request.tokenAmount * adjustedFinalPrice) / (10**(18-precisionFactor));
        uint256 fee = receivedAmount * feePercentage / 10000 + gasAmount;
        require(IERC20(request.sourceStableCoinAddress).balanceOf(address(this)) >= convertDecimals(receivedAmount - fee, 18, sourceStableCoinDecimals), "Contract does not have enough funds");
        require(IERC20(request.sourceStableCoinAddress).transfer(feeRecipient, convertDecimals(fee, 18, sourceStableCoinDecimals)), "Fee transfer to fee recipient failed");
        require(IERC20(request.sourceStableCoinAddress).transfer(request.user, convertDecimals(receivedAmount - fee, 18, sourceStableCoinDecimals)), "Transfer of stable coin to user failed");
        
        balances[request.user][request.targetchainId][request.targettokenAddress] -= request.tokenAmount;
        request.status = FULFILLED;
        _removeFromActiveRequests(requestId);

        emit RequestCompleted(
            requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.targetstableCoinAddress,
            request.sourceStableCoinAddress,
            receivedAmount,
            request.tokenAmount,
            finalPrice,
            request.isBuy
        );
    }

    /**
     * @dev Completes the cancellation of a buy token request after confirmation on the target chain.
     * 
     * @param requestId The ID of the request to complete cancellation.
     */
    function completeCancelBuyToken(uint256 requestId) public onlyRole(TRADER_ROLE) {
        RequestData storage request = requests[requestId];
        require(requestCancellationInitiated[requestId], "Cancellation not initiated");
        require(request.isBuy, "Not a buy request");
        require(request.status == PENDING, "Request not pending");
        uint8 sourceStableCoinDecimals = IERC20Metadata(request.sourceStableCoinAddress).decimals();

        uint256 cancelFee = request.stableCoinAmount * cancelFeePercentage / 10000 + gasAmount;
        uint256 realCancelFee = convertDecimals(cancelFee, 18, sourceStableCoinDecimals);
        uint256 refundAmount = request.stableCoinAmount - cancelFee;
        uint256 realRefundAmount = convertDecimals(refundAmount, 18, sourceStableCoinDecimals);

        require(IERC20(request.sourceStableCoinAddress).transfer(request.user, realRefundAmount), "Refund failed");

        require(IERC20(request.sourceStableCoinAddress).transfer(feeRecipient, realCancelFee), "Fee transfer failed");

        request.status = CANCELLED;
        requestCancellationInitiated[requestId] = false;
        _removeFromActiveRequests(requestId);

        emit RequestCancelled(
            request.requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.isBuy
        );
    }

    /**
     * @dev Completes the cancellation of a sell token request after confirmation on the target chain.
     * 
     * @param requestId The ID of the request to complete cancellation.
     */
    function completeCancelSellToken(uint256 requestId) public onlyRole(TRADER_ROLE) {
        RequestData storage request = requests[requestId];
        require(requestCancellationInitiated[requestId], "Cancellation not initiated");
        require(!request.isBuy, "Not a sell request");
        require(request.status == PENDING, "Request not pending");
        uint256 adjustedEndPrice = request.endPrice/(10**precisionFactor);
        // Calculate the base for cancel fee
        uint256 stableCoinEquivalent = request.stableCoinAmount* (10**(18-precisionFactor)) / adjustedEndPrice;
        uint256 gasAmountEquivalent  = gasAmount*(10**(18-precisionFactor))/adjustedEndPrice;

        // Calculate and deduct cancellation fee
        uint256 cancelFee = stableCoinEquivalent * cancelFeePercentage / 10000 + gasAmountEquivalent;
        balances[request.user][request.targetchainId][request.targettokenAddress] -= cancelFee;

        // Mark the request as fully cancelled
        request.status = CANCELLED;
        requestCancellationInitiated[requestId] = false;
        _removeFromActiveRequests(requestId);

        emit RequestCancelled(
            request.requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.isBuy
        );
    }

    /**
     * @dev Admin forcibly cancels an order
     * @param requestId The ID of the order to cancel
     */
    function forceCancelRequest(uint256 requestId) public onlyRole(TRADER_ROLE) {
        RequestData storage request = requests[requestId];
        require(request.status == PENDING, "Request not pending");

        request.status = CANCELLED;
        _removeFromActiveRequests(requestId);
        emit RequestCancelled(
            request.requestId,
            request.user,
            request.targetchainId,
            request.targettokenAddress,
            request.isBuy
        );
    }

    /////////////////////////////
    ////// Batch processing /////
    ////////////////////////////

    /**
     * @dev 
     * This function is used to complete multiple buy requests.
     * 
     * @param requestIds The IDs of the requests to complete.
     * @param finalPrices The final prices of the tokens.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function batchCompleteBuy(uint256[] memory requestIds, uint256[] memory finalPrices) public onlyRole(TRADER_ROLE) {
        require(requestIds.length == finalPrices.length, "Input arrays must have the same length");
        for (uint256 i = 0; i < requestIds.length; i++) {
            completeBuy(requestIds[i], finalPrices[i]);
        }
    }

    /**
     * @dev 
     * This function is used to complete multiple sell requests.
     * 
     * @param requestIds The IDs of the requests to complete.
     * @param finalPrices The final prices of the tokens.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function batchCompleteSell(uint256[] memory requestIds, uint256[] memory finalPrices) public onlyRole(TRADER_ROLE) {
        require(requestIds.length == finalPrices.length, "Input arrays must have the same length");
        for (uint256 i = 0; i < requestIds.length; i++) {
            completeSell(requestIds[i], finalPrices[i]);
        }
    }    

    /**
     * @dev 
     * This function is used to complete multiple buy request cancellations.
     * 
     * @param requestIds The IDs of the requests to complete cancellation.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function batchCompleteCancelBuyToken(uint256[] memory requestIds) public onlyRole(TRADER_ROLE) {
        for (uint256 i = 0; i < requestIds.length; i++) {
            completeCancelBuyToken(requestIds[i]);
        }
    }

    /**
     * @dev 
     * This function is used to complete multiple sell request cancellations.
     * 
     * @param requestIds The IDs of the requests to complete cancellation.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function batchCompleteCancelSellToken(uint256[] memory requestIds) public onlyRole(TRADER_ROLE) {
        for (uint256 i = 0; i < requestIds.length; i++) {
            completeCancelSellToken(requestIds[i]);
        }
    }

    /**
     * @dev 
     * This function is used to forcibly cancel multiple requests.
     * 
     * @param requestIds The IDs of the requests to cancel.
     * 
     * @notice This function can only be called by users with the TRADER_ROLE.
     */
    function batchForceCancelRequest(uint256[] memory requestIds) public onlyRole(TRADER_ROLE) {
        for (uint256 i = 0; i < requestIds.length; i++) {
            forceCancelRequest(requestIds[i]);
        }
    }

    /////////////////////
    ////// Getter //////
    ////////////////////

    /**
     * @dev 
     * This function is used to get the balance of a user for a specific token on a specific chain.
     * 
     * @param user The address of the user.
     * @param chainId The ID of the chain.
     * @param tokenAddress The address of the token.
     * 
     * @return The balance of the user for the specified token on the specified chain.
     */
    function getBalance(address user, uint256 chainId, address tokenAddress) public view returns (uint256) {
        return balances[user][chainId][tokenAddress];
    }

    /**
    * @dev 
    * This function is used to query the details of a request with a specific ID.
    * 
    * @param requestId The ID of the request to query.
    * 
    * @return request A RequestData struct containing all details of the request.
     */
    function getRequest(uint256 requestId) public view returns (RequestData memory) {
        require(requestId != 0 , "Request does not exist");
        RequestData storage request = requests[requestId];
        return request;
    }

    /**
     * @dev Get the user address of the specified request
     * @param requestId The request ID
     * @return The user address of the request
     */
    function getRequestUser(uint256 requestId) public view returns (address) {
        require(requestId != 0 , "Request does not exist");
        return requests[requestId].user;
    }

    /**
     * @dev Get the target token address of the specified request
     * @param requestId The request ID
     * @return The target token address of the request
     */
    function getRequestTargetTokenAddress(uint256 requestId) public view returns (address) {
        require(requestId != 0 , "Request does not exist");
        return requests[requestId].targettokenAddress;
    }

    /**
     * @dev Get the stable coin amount of the specified request
     * @param requestId The request ID
     * @return The stable coin amount of the request
     */
    function getRequestStableCoinAmount(uint256 requestId) public view returns (uint256) {
        require(requestId != 0 , "Request does not exist");
        return requests[requestId].stableCoinAmount;
    }

    /**
     * @dev Get the token amount of the specified request
     * @param requestId The request ID
     * @return The token amount of the request
     */
    function getRequestTokenAmount(uint256 requestId) public view returns (uint256) {
        require(requestId != 0 , "Request does not exist");
        return requests[requestId].tokenAmount;
    }

    /**
     * @dev Get whether the specified request is a buy request
     * @param requestId The request ID
     * @return Whether the request is a buy request
     */
    function getRequestIsBuy(uint256 requestId) public view returns (bool) {
        require(requestId != 0 , "Request does not exist");
        return requests[requestId].isBuy;
    }

    /**
     * @dev Get the status of the specified request
     * @param requestId The request ID
     * @return The status of the request
     */
    function getRequestStatus(uint256 requestId) public view returns (uint8) {
        require(requestId != 0 , "Request does not exist");
        return requests[requestId].status;
    }

    /**
     * @dev Get the number of active requests
     * @return The number of active requests
     */
    function getActiveRequestCount() public view returns (uint256) {
        return activeRequestCount;
    }

    /**
    * @dev Get the active requests id
    * @param pageSize The page size
    * @param page The page number
    * @param showAll If true, return all active requests regardless of pageSize and page
    * @return The active requests id, sorted with newest first
    */
    function getActiveRequestIds(uint256 pageSize, uint256 page, bool showAll) public view returns (uint256[] memory) {
        uint256 resultSize;
        uint256 startIndex;
        
        if (showAll) {
            resultSize = activeRequestCount;
            startIndex = 0;
        } else {
            startIndex = activeRequestCount - (page * pageSize) - pageSize;
            uint256 endIndex = activeRequestCount - (page * pageSize);
            
            if (startIndex < 0) {
                startIndex = 0;
            }
            
            resultSize = endIndex - startIndex;
        }
        
        uint256[] memory result = new uint256[](resultSize);
        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = activeRequestIds[activeRequestCount - i - 1 - startIndex];
        }
        return result;
    }

    /**
    * @dev Get the active requests data
    * @param pageSize The page size
    * @param page The page number
    * @param showAll If true, return all active requests regardless of pageSize and page
    * @return The active requests data, sorted with newest first
    */
    function getActiveRequestsData(uint256 pageSize, uint256 page, bool showAll) public view returns (RequestData[] memory) {
        uint256[] memory activeRequests = getActiveRequestIds(pageSize, page, showAll);
        RequestData[] memory requestsData = new RequestData[](activeRequests.length);
        for (uint256 i = 0; i < activeRequests.length; i++) {
            requestsData[i] = requests[activeRequests[i]];
        }
        return requestsData;
    }

    /////////////////////
    ////// Internal /////
    ////////////////////
    function createRequest(
        uint256 _targetchainId,
        address _tokenAddress,
        address _stableCoinAddress,
        address _sourceStableCoinAddress,
        uint256 _stableCoinAmount,
        uint256 _tokenAmount,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _duration,
        bool _isBuy
    ) internal {
        uint256 requestId = (block.chainid << 192) | (_targetchainId << 128) | (block.timestamp << 64) | ++requestCount;
        requests[requestId] = RequestData({
            requestId: requestId,
            user: msg.sender,
            targetchainId: _targetchainId,
            targettokenAddress: _tokenAddress,
            targetstableCoinAddress: _stableCoinAddress,
            sourceStableCoinAddress: _sourceStableCoinAddress,
            stableCoinAmount: _stableCoinAmount,
            tokenAmount: _tokenAmount,
            startPrice: _startPrice,
            endPrice: _endPrice,
            isBuy: _isBuy,
            status: PENDING
        });

        // allRequestIds.push(requestId);
        activeRequestIds.push(requestId);
        requestIdToActiveIndex[requestId] = activeRequestIds.length - 1;
        activeRequestCount++;

        emit RequestCreated(
            requestId,
            msg.sender,
            _targetchainId,
            _tokenAddress,
            _stableCoinAddress,
            _sourceStableCoinAddress,
            _stableCoinAmount,
            _tokenAmount,
            _startPrice,
            _endPrice,
            _duration,
            _isBuy
        );
    }

    function validateSellTokenAmount(
        uint256 _stableCoinAmount,
        uint256 _tokenAmount,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _targetchainId,
        address _tokenAddress
    ) internal view {
        uint256 adjustedEndAmount = _tokenAmount*(_endPrice / (10**precisionFactor))/(10**(18-precisionFactor));
        uint256 adjustedStartAmount = _tokenAmount*(_startPrice / (10**precisionFactor))/(10**(18-precisionFactor));
        require(adjustedEndAmount > gasAmount, "Token amount must be greater than gas amount");
        require(balances[msg.sender][_targetchainId][_tokenAddress] >= _tokenAmount, "Insufficient token balance");
        require(_stableCoinAmount >= adjustedEndAmount && _stableCoinAmount <= adjustedStartAmount, "Stable coin amount must be between end and start amounts");
    }

    function _removeFromActiveRequests(uint256 requestId) internal {
        uint256 index = requestIdToActiveIndex[requestId];
        uint256 lastRequestId = activeRequestIds[activeRequestIds.length - 1];
        activeRequestIds[index] = lastRequestId;
        requestIdToActiveIndex[lastRequestId] = index;
        activeRequestIds.pop();
        delete requestIdToActiveIndex[requestId];
        activeRequestCount--;
    }
}