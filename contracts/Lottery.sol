// Lottery

// Enter the lottery (paying some amount)
// Pick a random winner (verifiably random)
// Winner to be selected every X seconds -> completely automated
// Chainlink Oracle -> Randomness, Automated execution (Chainlink UpKeeper)

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

error Lottery__NotEnoughFeeEntered();
error Lottery__TransferFailed();
error Lottery__NotOpen();
error Lottery__NotAttend(address recentWinner);
error Lottery__UpkeepNotNeeded(uint256 currentBalance, uint32 numPlayers, uint8 lotteryState);

contract Lottery is VRFConsumerBaseV2, AutomationCompatibleInterface, ConfirmedOwner {
    using SafeMath for uint256;
    /* Type Declarations */
    enum LotteryState {
        OPEN,
        CALCULATING
    } // uint256 0 = OPEN , 1 = CALCULATING

    /* Chainlink State variables */
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private immutable i_callbackGasLimit;
    uint32 private s_numberOfWinners = 1;

    /* Lottery State variables */
    uint256 private s_interval;
    uint256 private s_lastTimeStamp;
    LotteryState private s_lotteryState;
    uint256 private constant s_entranceFee = 1e18;
    address payable[] private s_players;
    address[] private s_recentWinners;
    uint8 private immutable i_withdrawPercentageForWinner; // Must be less than 100
    uint8 private immutable i_withdrawPercentageForOwner; // Must be less than 100

    /* Events */
    event PlayerEnteredToLottery(address indexed player);
    event RequestedLotteryWinner(uint256 indexed requestId);
    event WinnerPicked(address indexed winner);
    event WithdrawnFund(address indexed someone, uint256 amount);

    constructor(
        address _vrfCoordinatorV2,
        bytes32 _gasLane,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint256 _interval,
        uint8 _withdrawPercentageForWinner,
        uint8 _withdrawPercentageForOwner
    ) VRFConsumerBaseV2(_vrfCoordinatorV2) ConfirmedOwner(msg.sender) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinatorV2);
        i_gasLane = _gasLane;
        i_subscriptionId = _subscriptionId;
        i_callbackGasLimit = _callbackGasLimit;
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_interval = _interval;
        i_withdrawPercentageForWinner = _withdrawPercentageForWinner;
        i_withdrawPercentageForOwner = _withdrawPercentageForOwner;
    }

    function isRecentWinner(address _sender) public view returns (bool) {
        for (uint32 i = 0; i < uint32(s_recentWinners.length); i++) {
            if (_sender == s_recentWinners[i]) return true;
        }
        return false;
    }

    function enterLottery() external payable {
        if (isRecentWinner(msg.sender) == true) {
            revert Lottery__NotAttend(msg.sender);
        }
        if (msg.value < s_entranceFee) {
            revert Lottery__NotEnoughFeeEntered();
        }
        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__NotOpen();
        }

        // Allocate amount of tickets to senders
        uint256 depositAmount = uint256(msg.value);
        uint32 lotteryTicketAmount = uint32(depositAmount.div(s_entranceFee));
        for (uint32 i = 0; i < lotteryTicketAmount; i++) {
            s_players.push(payable(msg.sender));
        }

        emit PlayerEnteredToLottery(msg.sender);
    }

    /**
     * @dev The following should be true in order to return true:
     * 1. Our time interval should have passed
     * 2. The lottery should have atleast 1 player, and have some ETH
     * 3. Our subscription is funded with LINK
     * 4. Lottery should be in "open" state
     */
    function checkUpkeep(
        bytes memory /* checkData */
    ) public override returns (bool upKeepNeeded, bytes memory /* performData */) {
        bool isOpen = (LotteryState.OPEN == s_lotteryState);
        bool timePassed = (block.timestamp - s_lastTimeStamp) > s_interval;
        bool hasPlayers = s_players.length > 0;
        bool hasBalance = address(this).balance > 0;
        upKeepNeeded = (isOpen && timePassed && hasPlayers && hasBalance);
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Lottery__UpkeepNotNeeded(
                address(this).balance,
                uint32(s_players.length),
                uint8(s_lotteryState)
            );
        }

        // Request random number
        s_lotteryState = LotteryState.CALCULATING;
        s_recentWinners = new address[](0);
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, //gasLane
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            s_numberOfWinners
        );
        emit RequestedLotteryWinner(requestId);
    }

    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] memory randomWords
    ) internal override {
        for (uint32 i = 0; i < s_numberOfWinners; i++) {
            uint32 indexOfWinner = uint32(randomWords[i] % s_players.length);
            address recentWinner = s_players[indexOfWinner];
            s_recentWinners.push(recentWinner);
            emit WinnerPicked(recentWinner);
            withdrawFund(
                payable(recentWinner),
                address(this).balance.mul(i_withdrawPercentageForWinner).div(100)
            ); // ?% => Winner
            withdrawFund(
                payable(owner()),
                address(this).balance.mul(i_withdrawPercentageForOwner).div(100)
            ); // ?% => Owner
        }
        s_lotteryState = LotteryState.OPEN;
        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;
    }

    // Withdraw Fund For Specific Account from Contract
    function withdrawFund(address payable _to, uint256 _amount) private {
        (bool success, ) = _to.call{value: _amount}("");
        if (!success) {
            revert Lottery__TransferFailed();
        }
        emit WithdrawnFund(_to, _amount);
    }

    // Update Interval by Owner
    function updateInterval(uint256 _interval) external onlyOwner {
        s_interval = _interval;
    }

    // Update Interval by Owner
    function updateNumberOfWinners(uint32 _numberOfWinners) external onlyOwner {
        if (s_lotteryState == LotteryState.CALCULATING) revert Lottery__NotOpen();
        s_numberOfWinners = _numberOfWinners;
    }

    /* View / Pure functions */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getEntranceFee() external pure returns (uint256) {
        return s_entranceFee;
    }

    function getInterval() external view returns (uint256) {
        return s_interval;
    }

    function getPlayers() external view returns (address payable[] memory) {
        return s_players;
    }

    function getPlayer(uint32 index) external view returns (address) {
        return s_players[index];
    }

    function getRecentWinners() external view returns (address[] memory) {
        return s_recentWinners;
    }

    function getLotteryState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    function getNumberOfWinners() external view returns (uint32) {
        return s_numberOfWinners;
    }

    function getNumberOfPlayers() external view returns (uint32) {
        return uint32(s_players.length);
    }

    function getLatestTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getWithdrawPercentageForWinner() external view returns (uint8) {
        return i_withdrawPercentageForWinner;
    }

    function getWithdrawPercentageForOwner() external view returns (uint8) {
        return i_withdrawPercentageForOwner;
    }
}
