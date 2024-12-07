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
    uint256 public immutable expiration;
    uint256 public premium;
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
    }

    function stakeETH() external payable onlyOwner nonReentrant {
        require(msg.value > 0, "Must stake some ETH");
        stakedShares = ILido(lido).submit{value: msg.value}(address(0));
        emit Staked(msg.sender, msg.value);
    }

    function buyOption() external payable nonReentrant {
        require(msg.sender == tx.origin, "Contracts cannot buy options"); // Restrict to EOAs
        require(msg.value == premium, "Incorrect premium amount");
        require(buyer == address(0), "Option already sold");

        buyer = msg.sender;
        (bool success, ) = payable(owner()).call{value: msg.value}("");
        require(success, "Transfer to owner failed");

        emit OptionBought(buyer, msg.value);
    }

    function exercise(uint256 currentPrice) external nonReentrant {
        require(msg.sender == buyer, "Only the option buyer can exercise");
        require(!isExercised, "Option already exercised");
        require(block.timestamp <= expiration, "Option expired");
        require(currentPrice >= strikePrice, "Current price below strike price");

        uint256 stETHAmount = ILido(lido).getPooledEthByShares(stakedShares);
        isExercised = true; // Update the state before external call
        (bool success, ) = payable(buyer).call{value: stETHAmount}("");
        require(success, "Transfer to buyer failed");

        emit OptionExercised(buyer, stETHAmount);
    }

    function cancelOption() external onlyOwner nonReentrant {
        require(!isExercised, "Option already exercised");
        require(block.timestamp > expiration, "Option not yet expired");

        uint256 stETHAmount = ILido(lido).getPooledEthByShares(stakedShares);
        (bool success, ) = payable(owner()).call{value: stETHAmount}("");
        require(success, "Transfer to owner failed");

        emit OptionCancelled(owner(), stETHAmount);
    }

    function withdraw() external onlyOwner nonReentrant {
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
