// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256);
    function getPooledEthByShares(uint256 _shares) external view returns (uint256);
}

interface IAggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract StakedEthOptions is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Struct to represent an option
    struct Option {
        address buyer;
        uint256 premium;
        uint256 strikePrice;
        uint256 expiration;
        bool isExercised;
    }

    // Lido stETH token contract
    address public immutable lido;

    // Price feed interface
    IAggregatorV3Interface public priceFeed;

    // Mapping from option ID to Option
    mapping(uint256 => Option) public options;
    uint256 public optionCount;

    // Total staked shares
    uint256 public stakedShares;

    // Events
    event Staked(address indexed staker, uint256 amount);
    event OptionBought(address indexed buyer, uint256 premium, uint256 optionId);
    event OptionExercised(address indexed buyer, uint256 stETHAmount, uint256 optionId);
    event OptionCancelled(address indexed owner, uint256 stETHAmount, uint256 optionId);
    event Withdrawn(address indexed owner, uint256 amount);

    /**
     * @dev Constructor initializes the contract with required parameters.
     * @param _lido Address of the Lido stETH contract.
     * @param _priceFeed Address of the trusted price feed (e.g., Chainlink).
     */
    constructor(address _lido, address _priceFeed) {
        require(_lido != address(0), "Invalid Lido address");
        require(_priceFeed != address(0), "Invalid price feed address");

        lido = _lido;
        priceFeed = IAggregatorV3Interface(_priceFeed);
    }

    /**
     * @dev Allows the owner to stake ETH and receive stETH.
     */
    function stakeETH() external payable onlyOwner nonReentrant {
        require(msg.value > 0, "Must stake some ETH");
        uint256 shares = ILido(lido).submit{value: msg.value}(address(0));
        stakedShares += shares;
        emit Staked(msg.sender, msg.value);
    }

    /**
     * @dev Allows a user to buy an option by paying the premium.
     * @param _strikePrice The strike price of the option.
     * @param _expiration The duration (in seconds) until the option expires.
     */
    function buyOption(uint256 _strikePrice, uint256 _expiration) external payable nonReentrant {
        require(msg.sender == tx.origin, "Contracts cannot buy options");
        require(msg.value > 0, "Premium must be greater than zero");
        require(_strikePrice > 0, "Strike price must be greater than zero");
        require(_expiration > 0, "Expiration time must be positive");

        optionCount += 1;
        options[optionCount] = Option({
            buyer: msg.sender,
            premium: msg.value,
            strikePrice: _strikePrice,
            expiration: block.timestamp + _expiration,
            isExercised: false
        });

        // Transfer the premium to the owner
        (bool success, ) = payable(owner()).call{value: msg.value}("");
        require(success, "Transfer to owner failed");

        emit OptionBought(msg.sender, msg.value, optionCount);
    }

    /**
     * @dev Allows the buyer to exercise their option if conditions are met.
     * @param _optionId The ID of the option to exercise.
     */
    function exercise(uint256 _optionId) external nonReentrant {
        Option storage option = options[_optionId];
        require(msg.sender == option.buyer, "Only the option buyer can exercise");
        require(!option.isExercised, "Option already exercised");
        require(block.timestamp <= option.expiration, "Option expired");

        uint256 currentPrice = getCurrentPrice();
        require(currentPrice >= option.strikePrice, "Current price below strike price");

        option.isExercised = true;

        uint256 stETHBalance = IERC20(lido).balanceOf(address(this));
        require(stETHBalance > 0, "No stETH tokens to transfer");

        // Transfer stETH to the buyer
        IERC20(lido).safeTransfer(option.buyer, stETHBalance);

        emit OptionExercised(option.buyer, stETHBalance, _optionId);
    }

    /**
     * @dev Allows the owner to cancel an expired option and reclaim stETH.
     * @param _optionId The ID of the option to cancel.
     */
    function cancelOption(uint256 _optionId) external onlyOwner nonReentrant {
        Option storage option = options[_optionId];
        require(!option.isExercised, "Option already exercised");
        require(block.timestamp > option.expiration, "Option not yet expired");

        uint256 stETHBalance = IERC20(lido).balanceOf(address(this));
        require(stETHBalance > 0, "No stETH to reclaim");

        // Transfer stETH back to the owner
        IERC20(lido).safeTransfer(owner(), stETHBalance);

        emit OptionCancelled(owner(), stETHBalance, _optionId);
    }

    /**
     * @dev Allows the owner to withdraw any residual ETH from the contract.
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
        emit Withdrawn(owner(), balance);
    }

    /**
     * @dev Fetches the current ETH price from the price feed.
     * @return The current ETH price as a uint256.
     */
    function getCurrentPrice() internal view returns (uint256) {
        (
            uint80 roundID, 
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        require(price > 0, "Invalid price from oracle");
        require(answeredInRound >= roundID, "Stale price data");
        require(updatedAt > 0, "Round not complete");

        return uint256(price);
    }

    /**
     * @dev Fallback function to accept ETH.
     */
    receive() external payable {}

    /**
     * @dev Fallback function to reject unknown function calls.
     */
    fallback() external payable {
        revert("Function not supported");
    }
}
