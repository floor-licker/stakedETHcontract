// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256);
    function sharesOf(address _account) external view returns (uint256);
    function getPooledEthByShares(uint256 _shares) external view returns (uint256);
}

contract StakedEthOptions is Ownable, ReentrancyGuard {
    address public staker; // The address of the staker
    address public buyer; // The address of the option buyer
    address public lido; // Lido staking contract
    uint256 public strikePrice; // Strike price in ETH
    uint256 public premium; // Premium in wei
    uint256 public expiration; // Expiration timestamp
    uint256 public stakedShares; // Amount of stETH shares
    bool public isExercised;

    constructor(
        address _lido,
        uint256 _strikePrice,
        uint256 _premium,
        uint256 _expiration
    ) {
        lido = _lido;
        staker = msg.sender;
        strikePrice = _strikePrice;
        premium = _premium;
        expiration = block.timestamp + _expiration;
        transferOwnership(msg.sender); // Set the contract deployer as the owner
    }

    // Stake ETH and mint stETH
    function stakeETH() external payable onlyOwner nonReentrant {
        require(msg.value > 0, "Must stake some ETH");

        // Stake ETH with Lido and get stETH shares
        stakedShares = ILido(lido).submit{value: msg.value}(address(0));
    }

    // Allow a buyer to purchase the option
    function buyOption() external payable nonReentrant {
        require(msg.value == premium, "Incorrect premium amount");
        require(buyer == address(0), "Option already sold");

        buyer = msg.sender;

        // Transfer the premium to the staker
        payable(staker).transfer(premium);
    }

    // Exercise the option
    function exercise(uint256 currentPrice) external nonReentrant {
        require(msg.sender == buyer, "Only the option buyer can exercise");
        require(!isExercised, "Option already exercised");
        require(block.timestamp <= expiration, "Option expired");
        require(currentPrice >= strikePrice, "Current price below strike price");

        // Transfer stETH shares to the buyer
        uint256 stETHAmount = ILido(lido).getPooledEthByShares(stakedShares);
        isExercised = true;
        payable(buyer).transfer(stETHAmount);
    }

    // Cancel the option if it expires unexercised
    function cancelOption() external onlyOwner nonReentrant {
        require(!isExercised, "Option already exercised");
        require(block.timestamp > expiration, "Option not yet expired");

        // Return stETH shares to the staker
        uint256 stETHAmount = ILido(lido).getPooledEthByShares(stakedShares);
        payable(staker).transfer(stETHAmount);
    }
}
