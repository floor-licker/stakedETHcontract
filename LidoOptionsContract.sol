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

    address public immutable lido;            // stETH token contract (Lido)
    uint256 public immutable strikePrice;     // Strike price in same units as aggregator
    uint256 public immutable expiration;      // Expiration timestamp
    uint256 public premium;                   // Premium in ETH (paid by buyer)
    uint256 public stakedShares;              // Shares minted upon staking
    address public buyer;                     // The buyer of the option
    bool public isExercised;                  // Whether the option has been exercised

    IAggregatorV3Interface public priceFeed;  // Trusted price feed (e.g., Chainlink)

    event Staked(address indexed staker, uint256 amount);
    event OptionBought(address indexed buyer, uint256 premium);
    event OptionExercised(address indexed buyer, uint256 stETHAmount);
    event OptionCancelled(address indexed staker, uint256 stETHAmount);

    constructor(
        address _lido,
        uint256 _strikePrice,
        uint256 _premium,
        uint256 _expiration,
        address _priceFeed
    ) {
        require(_lido != address(0), "Invalid Lido address");
        require(_strikePrice > 0, "Strike price must be greater than zero");
        require(_expiration > 0, "Expiration time must be positive");
        require(_priceFeed != address(0), "Invalid price feed address");

        lido = _lido;
        strikePrice = _strikePrice;
        premium = _premium;
        expiration = block.timestamp + _expiration;
        priceFeed = IAggregatorV3Interface(_priceFeed);
    }

    function stakeETH() external payable onlyOwner nonReentrant {
        require(msg.value > 0, "Must stake some ETH");
        stakedShares = ILido(lido).submit{value: msg.value}(address(0));
        emit Staked(msg.sender, msg.value);
    }

    function buyOption() external payable nonReentrant {
        require(msg.sender == tx.origin, "Contracts cannot buy options");
        require(msg.value == premium, "Incorrect premium amount");
        require(buyer == address(0), "Option already sold");

        buyer = msg.sender;
        (bool success, ) = payable(owner()).call{value: msg.value}("");
        require(success, "Transfer to owner failed");

        emit OptionBought(buyer, msg.value);
    }

    function exercise() external nonReentrant {
        require(msg.sender == buyer, "Only the option buyer can exercise");
        require(!isExercised, "Option already exercised");
        require(block.timestamp <= expiration, "Option expired");

        // Get the trusted price from the oracle
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price >= 0, "Invalid price feed response");
        uint256 currentPrice = uint256(price);

        require(currentPrice >= strikePrice, "Current price below strike price");

        isExercised = true;

        // Determine how many stETH tokens the contract has
        // The contract received stETH tokens from the Lido submit call
        uint256 stETHBalance = IERC20(lido).balanceOf(address(this));
        require(stETHBalance > 0, "No stETH tokens to transfer");

        // Transfer all stETH to the buyer using SafeERC20
        IERC20(lido).safeTransfer(buyer, stETHBalance);

        emit OptionExercised(buyer, stETHBalance);
    }

    function cancelOption() external onlyOwner nonReentrant {
        require(!isExercised, "Option already exercised");
        require(block.timestamp > expiration, "Option not yet expired");

        uint256 stETHBalance = IERC20(lido).balanceOf(address(this));
        require(stETHBalance > 0, "No stETH to reclaim");

        // Transfer all stETH back to the owner using SafeERC20
        IERC20(lido).safeTransfer(owner(), stETHBalance);

        emit OptionCancelled(owner(), stETHBalance);
    }

    function withdraw() external onlyOwner nonReentrant {
        // Withdraw any leftover ETH (e.g., premium if not yet transferred)
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdraw failed");
    }

    receive() external payable {}
    fallback() external payable {
        revert("Function not supported");
    }
}
