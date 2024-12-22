// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IPicweUSD.sol";
import "./IMainContract.sol";

struct RequestData {
    uint256 requestId;
    address user;
    uint256 amount;
    bool isburn;
}

contract weUSD_manager is AccessControl, Pausable{
    IMainContract public mainContract;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CROSS_CHAIN_MINTER_ROLE = keccak256("CROSS_CHAIN_MINTER_ROLE");
    IPicweUSD public weUSD;
    uint256 public requestCount;
    uint8 public constant WEUSD_DECIMALS = 6;
    uint256 public gasfee = 5*10**(6-1);
    address public feeRecipient;

    uint256[] public activeSourceRequests;
    uint256[] public activeTargetRequests;

    mapping(address => bool) public registeredStablecoins;
    mapping(uint256 => RequestData) private requests;

    mapping(uint256 => uint256) public requestIdToSourceActiveIndex;
    mapping(uint256 => uint256) public requestIdToTargetActiveIndex;

    event StablecoinRegistered(address indexed stablecoin);
    event StablecoinDeleted(address indexed stablecoin);
    event MintedWeUSD(address indexed user, address indexed stablecoin, uint256 stablecoinAmount, uint256 weUSDAmount);
    event BurnedWeUSD(address indexed user, address indexed stablecoin, uint256 weUSDAmount, uint256 stablecoinAmount);
    event CrossChainBurn(uint256 indexed requestId, address indexed user, uint256 sourceChainId, uint256 targetChainId, uint256 amount, address targetUser);
    event CrossChainMint(uint256 indexed requestId, address indexed minter, uint256 sourceChainId, uint256 targetChainId, uint256 amount, address targetUser);

    constructor(address _weUSD, address _stablecoin, address _crossChainMinter, address _main, address _feeRecipient) {
        weUSD = IPicweUSD(_weUSD);
        mainContract = IMainContract(_main);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(CROSS_CHAIN_MINTER_ROLE, _crossChainMinter);
        _grantRole(PAUSER_ROLE, _crossChainMinter);
        registeredStablecoins[_stablecoin] = true;
        feeRecipient = _feeRecipient;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Sets the gas fee (gasfee).
     * @param _gasfee The new gas fee amount.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A GasFeeSet event will be triggered after successful setting.
     */
    function setGasfee(uint256 _gasfee) external onlyRole(ADMIN_ROLE) {
        gasfee = _gasfee;
    }

    /**
     * @dev Sets the fee recipient (feeRecipient).
     * @param _feeRecipient The new fee recipient address.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A FeeRecipientSet event will be triggered after successful setting.
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Registers a stablecoin (stablecoin).
     * @param stablecoin The address of the stablecoin to be registered.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A StablecoinRegistered event will be triggered after successful registration.
     */
    function registerStablecoin(address stablecoin) external onlyRole(ADMIN_ROLE) {
        registeredStablecoins[stablecoin] = true;
        emit StablecoinRegistered(stablecoin);
    }

    /**
     * @dev Deletes a stablecoin (stablecoin).
     * @param stablecoin The address of the stablecoin to be deleted.
     * 
     * @notice This function can only be called by users with the ADMIN_ROLE.
     * @notice A StablecoinDeleted event will be triggered after successful deletion.
     */
    function deleteStablecoin(address stablecoin) external onlyRole(ADMIN_ROLE) {
        registeredStablecoins[stablecoin] = false;
        emit StablecoinDeleted(stablecoin);
    }


    /**
     * @dev Mints weUSD tokens in exchange for stablecoins.
     * @param stablecoin The address of the stablecoin to be exchanged.
     * @param stablecoinAmount The amount of stablecoin to be exchanged.
     *
     * @notice This function can be called by any user.
     * @notice The stablecoin must be registered.
     * @notice The stablecoin amount is converted to weUSD based on the decimal difference.
     * @notice A MintedWeUSD event will be emitted after successful minting.
     */
    function mintWeUSD(address stablecoin, uint256 stablecoinAmount) external {
        require(registeredStablecoins[stablecoin], "Stablecoin not registered");
        uint8 stablecoinDecimals = IERC20Metadata(stablecoin).decimals();
        uint256 weUSDAmount = convertDecimals(stablecoinAmount, stablecoinDecimals, WEUSD_DECIMALS); // Convert to weUSD decimals (6)
        require(IERC20(stablecoin).transferFrom(msg.sender, address(mainContract), stablecoinAmount), "Stablecoin transfer failed");
        weUSD.mint(msg.sender, weUSDAmount);
        emit MintedWeUSD(msg.sender, stablecoin, stablecoinAmount, weUSDAmount);
    }

    /**
     * @dev Burns weUSD tokens and returns stablecoins to the user.
     * @param stablecoin The address of the stablecoin to be returned.
     * @param weUSDAmount The amount of weUSD to be burned.
     *
     * @notice This function can be called by any user.
     * @notice The stablecoin must be registered.
     * @notice The weUSD amount is converted to stablecoin based on the decimal difference.
     * @notice A BurnedWeUSD event will be emitted after successful burning.
     */
    function burnWeUSD(address stablecoin, uint256 weUSDAmount) external {
        require(registeredStablecoins[stablecoin], "Stablecoin not registered");
        uint8 stablecoinDecimals = IERC20Metadata(stablecoin).decimals();
        uint256 stablecoinAmount = convertDecimalsCeil(weUSDAmount, WEUSD_DECIMALS, stablecoinDecimals); // Convert from weUSD decimals (6)
        mainContract.transferStableCoin(stablecoin, msg.sender, stablecoinAmount);
        weUSD.burnFrom(msg.sender, weUSDAmount);
        emit BurnedWeUSD(msg.sender, stablecoin, weUSDAmount, stablecoinAmount);
    }

    /**
     * @dev Burns weUSD tokens on the source chain for cross-chain transfer.
     * @param targetChainId The ID of the target chain where weUSD will be minted.
     * @param amount The total amount of weUSD to be burned (including gas fee).
     * @param targetUser The address of the user on the target chain to receive the minted weUSD.
     *
     * @notice This function can be called by any user when the contract is not paused.
     * @notice A portion of the amount is deducted as gas fee and transferred to the fee recipient.
     * @notice The remaining amount is burned from the sender's balance.
     * @notice A CrossChainBurn event is emitted after successful burning.
     */
    function burnWeUSDCrossChain(uint256 targetChainId, uint256 amount, address targetUser) external whenNotPaused {
        require(targetChainId != block.chainid, "Target chain must be different from source chain");
        require(amount > gasfee, "Amount must be greater than gasfee");
        require(targetUser != address(0), "Invalid target user address");
        uint256 sourceChainId = block.chainid;
        uint256 requestId = (sourceChainId << 192) | (targetChainId << 128) | (block.timestamp << 64) | ++requestCount;
        require(!requestExists(requestId), "Request ID already exists");
        uint256 burnAmount = amount - gasfee;
        weUSD.transferFrom(msg.sender, feeRecipient, gasfee);
        weUSD.burnFrom(msg.sender, burnAmount);
        _createRequest(requestId, msg.sender, burnAmount, true);
        emit CrossChainBurn(requestId, msg.sender, sourceChainId, targetChainId, burnAmount, targetUser);
    }
    
    /**
     * @dev Mints weUSD tokens on the target chain for cross-chain transfer.
     * @param requestId Unique request ID to prevent duplicate processing
     * @param sourceChainId ID of the source chain
     * @param amount Amount of weUSD to be minted
     * @param targetUser Address of the target user to receive the minted weUSD
     *
     * @notice This function can only be called by addresses with the CROSS_CHAIN_MINTER_ROLE role when the contract is not paused
     * @notice The requestId must not have been used before
     * @notice The source chain must be different from the current chain
     * @notice The minting amount must be greater than 0
     * @notice The target user address cannot be the zero address
     * @notice A CrossChainMint event will be emitted after successful minting
     */
    function mintWeUSDCrossChain(uint256 requestId, uint256 sourceChainId, uint256 amount, address targetUser) external onlyRole(CROSS_CHAIN_MINTER_ROLE) whenNotPaused {
        require(sourceChainId != block.chainid, "Source chain must be different from target chain");
        require(amount > 0, "Amount must be greater than 0");
        require(targetUser != address(0), "Invalid target user address");
        require(!requestExists(requestId), "Request ID already exists");
        weUSD.mint(targetUser, amount);
        _createRequest(requestId, targetUser, amount, false);
        emit CrossChainMint(requestId, msg.sender, sourceChainId, block.chainid, amount, targetUser);
    }

    /**
    * @dev Batch mints weUSD tokens on the target chain for cross-chain transfer.
    * @param requestIds Array of unique request IDs to prevent duplicate processing
    * @param sourceChainIds Array of IDs of the source chains
    * @param amounts Array of amounts of weUSD to be minted
    * @param targetUsers Array of addresses of the target users to receive the minted weUSD
    *
    * @notice This function can only be called by addresses with the CROSS_CHAIN_MINTER_ROLE role when the contract is not paused
    * @notice All input arrays must have the same length
    * @notice Each requestId must not have been used before
    * @notice Each source chain must be different from the current chain
    * @notice Each minting amount must be greater than 0
    * @notice Each target user address cannot be the zero address
    * @notice A CrossChainMint event will be emitted for each successful minting
    */
    function batchMintWeUSDCrossChain(
        uint256[] calldata requestIds, 
        uint256[] calldata sourceChainIds, 
        uint256[] calldata amounts, 
        address[] calldata targetUsers
    ) external onlyRole(CROSS_CHAIN_MINTER_ROLE) whenNotPaused {
        require(
            requestIds.length == sourceChainIds.length && 
            requestIds.length == amounts.length && 
            requestIds.length == targetUsers.length, 
            "Input arrays must have the same length"
        );

        for (uint256 i = 0; i < requestIds.length; i++) {
            require(sourceChainIds[i] != block.chainid, "Source chain must be different from target chain");
            require(amounts[i] > 0, "Amount must be greater than 0");
            require(targetUsers[i] != address(0), "Invalid target user address");
            require(!requestExists(requestIds[i]), "Request ID already exists");

            weUSD.mint(targetUsers[i], amounts[i]);
            _createRequest(requestIds[i], targetUsers[i], amounts[i], false);
            emit CrossChainMint(requestIds[i], msg.sender, sourceChainIds[i], block.chainid, amounts[i], targetUsers[i]);
        }
    }
    
    /**
     * @dev Retrieves the request data for a given request ID
     * @param _requestId The unique identifier of the request
     * @return RequestData struct containing the request details
     * 
     * @notice This function can be called by any address
     * @notice Returns a struct with default values if the request ID doesn't exist
     */
    function getRequestById(uint256 _requestId) public view returns (RequestData memory) {
        return requests[_requestId];
    }

    /**
     * @dev Checks if a request exists for a given request ID
     * @param _requestId The unique identifier of the request
     * @return bool indicating whether the request exists
     * 
     * @notice This function can be called by any address
     */
    function requestExists(uint256 _requestId) public view returns (bool) {
        return requests[_requestId].requestId != 0;
    }
    
    /**
     * @dev Get all source chain request IDs for a specific user
     * @param _user User address
     * @param _page Page number (starting from 1)
     * @param _pageSize Number of items per page
     * @return uint256[] Array containing source chain request IDs for the user's specified page
     * @return uint256 Total number of source chain requests for the user
     * 
     * @notice This function can be called by any address
     * @notice If the user has no source chain requests, an empty array will be returned
     * @notice If _page or _pageSize is 0, all requests will be returned
     */
    function getUserSourceRequests(address _user, uint256 _page, uint256 _pageSize) public view returns (uint256[] memory, uint256) {
        require(_page == 0 || _pageSize == 0 || (_page > 0 && _pageSize > 0), "Invalid page or page size");

        uint256 totalRequests = 0;
        for (uint256 i = 0; i < activeSourceRequests.length; i++) {
            if (requests[activeSourceRequests[i]].user == _user) {
                totalRequests++;
            }
        }

        uint256 startIndex = 0;
        uint256 endIndex = totalRequests;

        if (_page > 0 && _pageSize > 0) {
            startIndex = totalRequests - (_page * _pageSize);
            if (startIndex > totalRequests) startIndex = 0;
            endIndex = startIndex + _pageSize;
            if (endIndex > totalRequests) endIndex = totalRequests;
        }

        uint256[] memory userSourceRequests = new uint256[](endIndex - startIndex);
        uint256 count = 0;

        for (uint256 i = activeSourceRequests.length; i > 0 && count < userSourceRequests.length; i--) {
            uint256 requestId = activeSourceRequests[i-1];
            if (requests[requestId].user == _user) {
                if (totalRequests - count > startIndex) {
                    userSourceRequests[count] = requestId;
                    count++;
                } else {
                    break;
                }
            }
        }

        return (userSourceRequests, totalRequests);
    }

    /**
     * @dev Get all target chain request IDs for a specific user
     * @param _user User address
     * @param _page Page number (starting from 1)
     * @param _pageSize Number of items per page
     * @return uint256[] Array containing target chain request IDs for the user's specified page
     * @return uint256 Total number of target chain requests for the user
     * 
     * @notice Any address can call this function
     * @notice If the user has no target chain requests, an empty array will be returned
     * @notice If _page or _pageSize is 0, all requests will be returned
     */
    function getUserTargetRequests(address _user, uint256 _page, uint256 _pageSize) public view returns (uint256[] memory, uint256) {
        require(_page == 0 || _pageSize == 0 || (_page > 0 && _pageSize > 0), "Invalid page or page size");

        uint256 totalRequests = 0;
        for (uint256 i = 0; i < activeTargetRequests.length; i++) {
            if (requests[activeTargetRequests[i]].user == _user) {
                totalRequests++;
            }
        }

        uint256 startIndex = 0;
        uint256 endIndex = totalRequests;

        if (_page > 0 && _pageSize > 0) {
            startIndex = totalRequests - (_page * _pageSize);
            if (startIndex > totalRequests) startIndex = 0;
            endIndex = startIndex + _pageSize;
            if (endIndex > totalRequests) endIndex = totalRequests;
        }

        uint256[] memory userTargetRequests = new uint256[](endIndex - startIndex);
        uint256 count = 0;

        for (uint256 i = activeTargetRequests.length; i > 0 && count < userTargetRequests.length; i--) {
            uint256 requestId = activeTargetRequests[i-1];
            if (requests[requestId].user == _user) {
                if (totalRequests - count > startIndex) {
                    userTargetRequests[count] = requestId;
                    count++;
                } else {
                    break;
                }
            }
        }

        return (userTargetRequests, totalRequests);
    }

    // internal functions


    /**
     * @dev Create a new request record
     * @param _requestId Request ID
     * @param _user User address
     * @param _amount Request amount
     * @param _isburn Whether it is a destruction operation
     */
    function _createRequest(uint256 _requestId, address _user, uint256 _amount, bool _isburn) internal {
   
        RequestData memory newRequest = RequestData({
            requestId: _requestId,
            user: _user,
            amount: _amount,
            isburn: _isburn
        });
        
        requests[_requestId] = newRequest;
        if(_isburn){
            activeSourceRequests.push(_requestId);
        }else{
            activeTargetRequests.push(_requestId);
        }
        if(_isburn){
            requestIdToSourceActiveIndex[_requestId] = activeSourceRequests.length - 1;
        }else{
            requestIdToTargetActiveIndex[_requestId] = activeTargetRequests.length - 1;
        }
    }


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
}