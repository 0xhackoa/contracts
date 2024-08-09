// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract WBTCSwimmingBet is ReentrancyGuard, Ownable {
    IERC20 public wbtcToken;
    
    struct Bet {
        address bettor;
        uint256 amount;
    }
    
    mapping(string => Bet[]) public bets;
    string[] public swimmers;
    uint256 public totalPool;
    bool public bettingOpen;
    string public winner;
    
    event BetPlaced(address bettor, string swimmer, uint256 amount);
    event WinnerDeclared(string winner);
    event RewardClaimed(address bettor, uint256 amount);
    event WBTCReceived(address from, uint256 amount);
    event WBTCWithdrawn(address to, uint256 amount);
    
    constructor(address _wbtcToken) {
        wbtcToken = IERC20(_wbtcToken);
        bettingOpen = true;
    }
    
    // Function to receive WBTC from backend
    function receiveWBTC(address _from, uint256 _amount) external onlyOwner {
        require(wbtcToken.transferFrom(_from, address(this), _amount), "WBTC transfer failed");
        emit WBTCReceived(_from, _amount);
    }
    
    // Function to place a bet
    function placeBet(address _bettor, string memory _swimmer, uint256 _amount) external onlyOwner {
        require(bettingOpen, "Betting is closed");
        require(_amount > 0, "Bet amount must be greater than 0");
        
        bets[_swimmer].push(Bet(_bettor, _amount));
        totalPool += _amount;
        
        if (bets[_swimmer].length == 1) {
            swimmers.push(_swimmer);
        }
        
        emit BetPlaced(_bettor, _swimmer, _amount);
    }
    
    // Function to declare the winner
    function declareWinner(string memory _winner) external onlyOwner {
        require(bettingOpen, "Betting is already closed");
        bettingOpen = false;
        winner = _winner;
        emit WinnerDeclared(_winner);
    }
    
    // Function for users to claim their reward
    function claimReward() external nonReentrant {
        require(!bettingOpen, "Winner has not been declared yet");
        uint256 reward = calculateReward(msg.sender);
        require(reward > 0, "No reward to claim");
        
        require(wbtcToken.transfer(msg.sender, reward), "Reward transfer failed");
        emit RewardClaimed(msg.sender, reward);
    }
    
    // Function to calculate reward
    function calculateReward(address _bettor) public view returns (uint256) {
        uint256 bettorTotal = 0;
        uint256 winningTotal = 0;
        
        for (uint i = 0; i < bets[winner].length; i++) {
            if (bets[winner][i].bettor == _bettor) {
                bettorTotal += bets[winner][i].amount;
            }
            winningTotal += bets[winner][i].amount;
        }
        
        if (winningTotal == 0) return 0;
        return (bettorTotal * totalPool) / winningTotal;
    }
    
    // Function to withdraw any remaining WBTC (for emergency use)
    function withdrawRemainingWBTC(address _to) external onlyOwner {
        uint256 balance = wbtcToken.balanceOf(address(this));
        require(balance > 0, "No WBTC to withdraw");
        require(wbtcToken.transfer(_to, balance), "WBTC withdrawal failed");
        emit WBTCWithdrawn(_to, balance);
    }
    
    // Function to check contract's WBTC balance
    function getContractBalance() external view returns (uint256) {
        return wbtcToken.balanceOf(address(this));
    }
}
