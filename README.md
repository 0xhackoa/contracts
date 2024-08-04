// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
// Interface for interacting with Polygon's AggLayer
interface IAggLayer {
    function sendMessage(address _app, uint256 _targetChainId, bytes calldata _payload) external payable;
    function receiveMessage(address _srcAddress, uint256 _srcChainId, bytes calldata _message) external;
}

// Main QuestChain contract
contract QuestChain is Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _questIds;
    Counters.Counter private _userIds;

    struct Quest {
        uint256 id;
        string name;
        string description;
        uint256 xpReward;
        bool isActive;
        address creator;
        QuestType questType;
    }

    struct User {
        uint256 id;
        address userAddress;
        uint256 xp;
        uint256 level;
        uint256[] completedQuests;
    }

    enum QuestType { DeFi, NFT, Social, Educational }

    mapping(uint256 => Quest) public quests;
    mapping(address => User) public users;

    QuestChainCoreBridge public coreBridge;
    QuestChainPolygonBridge public polygonBridge;

    DeFiQuest public defiQuest;
    NFTQuest public nftQuest;
    SocialQuest public socialQuest;
    EducationalQuest public educationalQuest;

    event QuestCreated(uint256 indexed questId, string name, address creator);
    event QuestCompleted(uint256 indexed questId, address indexed user, uint256 xpEarned);
    event UserLevelUp(address indexed user, uint256 newLevel);

    constructor() Ownable(msg.sender){
        _userIds.increment(); // Start user IDs at 1
    }

    function createQuest(string memory name, string memory description, uint256 xpReward, QuestType questType) external {
        _questIds.increment();
        uint256 newQuestId = _questIds.current();

        quests[newQuestId] = Quest(newQuestId, name, description, xpReward, true, msg.sender, questType);

        emit QuestCreated(newQuestId, name, msg.sender);
    }

    function registerUser() external {
        require(users[msg.sender].id == 0, "User already registered");
        
        uint256 newUserId = _userIds.current();
        users[msg.sender] = User(newUserId, msg.sender, 0, 1, new uint256[](0));
        
        _userIds.increment();
    }

    function completeQuest(uint256 questId, address user) external {
        require(
            msg.sender == address(defiQuest) ||
            msg.sender == address(nftQuest) ||
            msg.sender == address(socialQuest) ||
            msg.sender == address(educationalQuest),
            "Only specific quest contracts can call this function"
        );
        require(quests[questId].isActive, "Quest not active");
        require(!hasCompletedQuest(user, questId), "Quest already completed");

        User storage questUser = users[user];
        Quest storage quest = quests[questId];

        questUser.xp += quest.xpReward;
        questUser.completedQuests.push(questId);

        uint256 newLevel = calculateLevel(questUser.xp);
        if (newLevel > questUser.level) {
            questUser.level = newLevel;
            emit UserLevelUp(user, newLevel);
        }

        emit QuestCompleted(questId, user, quest.xpReward);

        // Send cross-chain message if needed
        if (address(coreBridge) != address(0)) {
            coreBridge.sendQuestCompletion(questId, user);
        } else if (address(polygonBridge) != address(0)) {
            polygonBridge.sendQuestCompletion(questId, user);
        }
    }

    function hasCompletedQuest(address userAddress, uint256 questId) public view returns (bool) {
        User storage user = users[userAddress];
        for (uint i = 0; i < user.completedQuests.length; i++) {
            if (user.completedQuests[i] == questId) {
                return true;
            }
        }
        return false;
    }

    function calculateLevel(uint256 xp) public pure returns (uint256) {
        return (xp / 100) + 1;
    }

    function setCrossBridges(address _coreBridge, address _polygonBridge) external onlyOwner {
        coreBridge = QuestChainCoreBridge(_coreBridge);
        polygonBridge = QuestChainPolygonBridge(_polygonBridge);
    }

    function setQuestContracts(
        address _defiQuest,
        address _nftQuest,
        address _socialQuest,
        address _educationalQuest
    ) external onlyOwner {
        defiQuest = DeFiQuest(_defiQuest);
        nftQuest = NFTQuest(_nftQuest);
        socialQuest = SocialQuest(_socialQuest);
        educationalQuest = EducationalQuest(_educationalQuest);
    }

    function updateCrossChainQuestStatus(uint256 questId, address user) external {
        require(msg.sender == address(coreBridge) || msg.sender == address(polygonBridge), "Only bridge contracts can call this function");
        
        // Update the user's quest status
        if (!hasCompletedQuest(user, questId)) {
            User storage questUser = users[user];
            Quest storage quest = quests[questId];

            questUser.xp += quest.xpReward;
            questUser.completedQuests.push(questId);

            uint256 newLevel = calculateLevel(questUser.xp);
            if (newLevel > questUser.level) {
                questUser.level = newLevel;
                emit UserLevelUp(user, newLevel);
            }

            emit QuestCompleted(questId, user, quest.xpReward);
        }
    }
}

// NFT Reward contract
contract QuestChainNFT is ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    QuestChain public questChainContract;

    constructor (address _questChainAddress) Ownable(msg.sender) ERC721("QuestChainNFT", "QCNFT") {
        questChainContract = QuestChain(_questChainAddress);
    }

    function mintNFT(address recipient, string memory tokenURI) external onlyOwner returns (uint256) {
        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();
        _mint(recipient, newItemId);
        _setTokenURI(newItemId, tokenURI);
        return newItemId;
    }
}

// Core DAO Bridge contract
contract QuestChainCoreBridge is Ownable {
    address public questChainAddress;
    address public aggLayerAddress;
    uint256 public polygonChainId;

    address public polygonBridgeAddress;  // In QuestChainCoreBridge


    event MessageSent(uint256 indexed questId, address indexed user, uint256 targetChainId);
    event MessageReceived(uint256 indexed questId, address indexed user, uint256 srcChainId);

    constructor(address _questChainAddress, address _aggLayerAddress, uint256 _polygonChainId,address _polygonBridgeAddress)Ownable(msg.sender) {
        questChainAddress = _questChainAddress;
        aggLayerAddress = _aggLayerAddress;
        polygonChainId = _polygonChainId;
        polygonBridgeAddress = _polygonBridgeAddress;
    }

    function sendQuestCompletion(uint256 _questId, address _user) payable external {
        require(msg.sender == questChainAddress, "Only QuestChain can call this function");
        
        bytes memory payload = abi.encode(_questId, _user);
        IAggLayer(aggLayerAddress).sendMessage{value: msg.value}(address(this), polygonChainId, payload);
        
        emit MessageSent(_questId, _user, polygonChainId);
    }

    function receiveMessage(address _srcAddress, uint256 _srcChainId, bytes calldata _message) external {
        require(msg.sender == aggLayerAddress, "Only AggLayer can call this function");
        require(_srcChainId == polygonChainId, "Invalid source chain");
        require(_srcAddress == polygonBridgeAddress, "Invalid source address");

        (uint256 questId, address user) = abi.decode(_message, (uint256, address));
        
        QuestChain(questChainAddress).updateCrossChainQuestStatus(questId, user);

        emit MessageReceived(questId, user, _srcChainId);
    }
}

// Polygon Bridge contract
contract QuestChainPolygonBridge is Ownable {
    address public questChainAddress;
    address public aggLayerAddress;
    uint256 public coreDAOChainId;

    event MessageSent(uint256 indexed questId, address indexed user, uint256 targetChainId);
    event MessageReceived(uint256 indexed questId, address indexed user, uint256 srcChainId);

    constructor(address _questChainAddress, address _aggLayerAddress, uint256 _coreDAOChainId) Ownable(msg.sender){
        questChainAddress = _questChainAddress;
        aggLayerAddress = _aggLayerAddress;
        coreDAOChainId = _coreDAOChainId;
    }

    function sendQuestCompletion(uint256 _questId, address _user) payable external {
        require(msg.sender == questChainAddress, "Only QuestChain can call this function");
        
        bytes memory payload = abi.encode(_questId, _user);
        IAggLayer(aggLayerAddress).sendMessage{value: msg.value}(address(this), coreDAOChainId, payload);
        
        emit MessageSent(_questId, _user, coreDAOChainId);
    }

    function receiveMessage( uint256 _srcChainId, bytes calldata _message) external {
        require(msg.sender == aggLayerAddress, "Only AggLayer can call this function");
        require(_srcChainId == coreDAOChainId, "Invalid source chain");

        (uint256 questId, address user) = abi.decode(_message, (uint256, address));
        
        QuestChain(questChainAddress).updateCrossChainQuestStatus(questId, user);

        emit MessageReceived(questId, user, _srcChainId);
    }
}

// DeFi Quest Contract
contract DeFiQuest is Ownable {
    QuestChain public questChain;
    IERC20 public stakingToken;
    
    mapping(uint256 => uint256) public questStakeRequirements;
    mapping(address => mapping(uint256 => uint256)) public userStakes;

    event Staked(address indexed user, uint256 indexed questId, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed questId, uint256 amount);

    constructor(address _questChain, address _stakingToken) Ownable(msg.sender){
        questChain = QuestChain(_questChain);
        stakingToken = IERC20(_stakingToken);
    }

    function setQuestStakeRequirement(uint256 questId, uint256 amount) external onlyOwner {
        questStakeRequirements[questId] = amount;
    }

    function stake(uint256 questId, uint256 amount) external {
        require(amount >= questStakeRequirements[questId], "Insufficient stake amount");
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        userStakes[msg.sender][questId] += amount;
        emit Staked(msg.sender, questId, amount);

        // Check if the quest is completed by staking
        if (userStakes[msg.sender][questId] >= questStakeRequirements[questId]) {
            questChain.completeQuest(questId, msg.sender);
        }
    }

    function unstake(uint256 questId, uint256 amount) external {
        require(userStakes[msg.sender][questId] >= amount, "Insufficient staked amount");
        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
        
        userStakes[msg.sender][questId] -= amount;
        emit Unstaked(msg.sender, questId, amount);
    }
}

// NFT Quest Contract
contract NFTQuest is Ownable {
    QuestChain public questChain;
    IERC721 public nftContract;
    
    mapping(uint256 => uint256) public questNFTRequirements;
    mapping(address => mapping(uint256 => bool)) public userCompletedNFTQuests;

    event NFTQuestCompleted(address indexed user, uint256 indexed questId, uint256 tokenId);

    constructor(address _questChain, address _nftContract) Ownable(msg.sender){
        questChain = QuestChain(_questChain);
        nftContract = IERC721(_nftContract);
    }

    function setQuestNFTRequirement(uint256 questId, uint256 tokenId) external onlyOwner {
        questNFTRequirements[questId] = tokenId;
    }

    function completeNFTQuest(uint256 questId, uint256 tokenId) external {
        require(nftContract.ownerOf(tokenId) == msg.sender, "You don't own this NFT");
        require(questNFTRequirements[questId] == tokenId, "Incorrect NFT for this quest");
        require(!userCompletedNFTQuests[msg.sender][questId], "Quest already completed");

        userCompletedNFTQuests[msg.sender][questId] = true;
        questChain.completeQuest(questId, msg.sender);
        
        emit NFTQuestCompleted(msg.sender, questId, tokenId);
    }
}

// Social Quest Contract
contract SocialQuest is Ownable {
    QuestChain public questChain;
    
    mapping(uint256 => uint256) public questReferralRequirements;
    mapping(address => mapping(uint256 => uint256)) public userReferrals;

    event ReferralAdded(address indexed referrer, address indexed referred, uint256 indexed questId);
    event SocialQuestCompleted(address indexed user, uint256 indexed questId);

    constructor(address _questChain)Ownable(msg.sender) {
        questChain = QuestChain(_questChain);
    }

    function setQuestReferralRequirement(uint256 questId, uint256 amount) external onlyOwner {
        questReferralRequirements[questId] = amount;
    }

    function addReferral(uint256 questId, address referred) external {
        require(referred != msg.sender, "Cannot refer yourself");
        require(userReferrals[referred][questId] == 0, "User already referred");

        userReferrals[msg.sender][questId]++;
        emit ReferralAdded(msg.sender, referred, questId);

        if (userReferrals[msg.sender][questId] >= questReferralRequirements[questId]) {
            userReferrals[msg.sender][questId] = 0; // Reset for future quests
            questChain.completeQuest(questId, msg.sender);
            emit SocialQuestCompleted(msg.sender, questId);
        }
    }
}


// Educational Quest Contract
contract EducationalQuest is Ownable {
    QuestChain public questChain;
    
    mapping(uint256 => bytes32) public questAnswers;
    mapping(address => mapping(uint256 => bool)) public userCompletedEducationalQuests;

    event EducationalQuestCompleted(address indexed user, uint256 indexed questId);

    constructor(address _questChain) Ownable(msg.sender){
        questChain = QuestChain(_questChain);
    }

    function setQuestAnswer(uint256 questId, string memory answer) external onlyOwner {
        questAnswers[questId] = keccak256(abi.encodePacked(answer));
    }

    function submitAnswer(uint256 questId, string memory answer) external {
        require(!userCompletedEducationalQuests[msg.sender][questId], "Quest already completed");
        require(questAnswers[questId] == keccak256(abi.encodePacked(answer)), "Incorrect answer");

        userCompletedEducationalQuests[msg.sender][questId] = true;
        questChain.completeQuest(questId, msg.sender);
        
        emit EducationalQuestCompleted(msg.sender, questId);
    }
}
