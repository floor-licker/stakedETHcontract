// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ILido {
    function submit(address _referral) external payable returns (uint256);
    function getPooledEthByShares(uint256 _shares) external view returns (uint256);
}

contract StakedEthOptions is Ownable, ReentrancyGuard {
    address public immutable lido;
    uint256 public immutable strikePrice;
    uint256 public premium;
    uint256 public expiration;
    uint256 public stakedShares;
    address public buyer;
    bool public isExercised;

    event Staked(address indexed staker, uint256 amount);
    event OptionBought(address indexed buyer, uint256 premium);
    event OptionExercised(address indexed buyer, uint256 stETHAmount);
    event OptionCancelled(address indexed staker, uint256 stETHAmount);

    constructor(
        address _lido,
        uint256 _strikePrice,
        uint256 _premium,
        uint256 _expiration
    ) {
        require(_lido != address(0), "Invalid Lido address");
        require(_strikePrice > 0, "Strike price must be greater than zero");
        require(_expiration > 0, "Expiration time must be positive");

        lido = _lido;
        strikePrice = _strikePrice;
        premium = _premium;
        expiration = block.timestamp + _expiration;
        transferOwnership(msg.sender);
    }

    function stakeETH() external payable onlyOwner nonReentrant {
        require(msg.value > 0, "Must stake some ETH");

        // Write stakedShares only once
        stakedShares = ILido(lido).submit{value: msg.value}(address(0));
        emit Staked(msg.sender, msg.value);
    }

    function buyOption() external payable nonReentrant {
        require(msg.value == premium, "Incorrect premium amount");
        require(buyer == address(0), "Option already sold");

        // Combine buyer assignment and transfer in one step
        buyer = msg.sender;
        payable(owner()).transfer(msg.value);

        emit OptionBought(buyer, msg.value);
    }

    function exercise(uint256 currentPrice) external nonReentrant {
        require(msg.sender == buyer, "Only the option buyer can exercise");
        require(!isExercised, "Option already exercised");
        require(block.timestamp <= expiration, "Option expired");
        require(currentPrice >= strikePrice, "Current price below strike price");

        // Combine state update and transfer
        uint256 stETHAmount = ILido(lido).getPooledEthByShares(stakedShares);
        isExercised = true; // Update the state before external call
        payable(buyer).transfer(stETHAmount);

        emit OptionExercised(buyer, stETHAmount);
    }

    function cancelOption() external onlyOwner nonReentrant {
        require(!isExercised, "Option already exercised");
        require(block.timestamp > expiration, "Option not yet expired");

        // Combine retrieval and transfer logic
        uint256 stETHAmount = ILido(lido).getPooledEthByShares(stakedShares);
        payable(owner()).transfer(stETHAmount);

        emit OptionCancelled(owner(), stETHAmount);
    }
}
