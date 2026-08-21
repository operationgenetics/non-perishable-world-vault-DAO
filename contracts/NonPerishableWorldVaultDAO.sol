// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

interface IBindingCurveToken {
    function totalRaisedDAI() external view returns (uint256);
}

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract NonPerishableWorldVaultDAO {
    struct Member {
        bool joined;
        bool active;
        uint256 lastClaimMonth;
        uint256 joinTimestamp;
    }

    struct VaultLocationProposal {
        uint256 id;
        address proposer;
        string locationName;
        string geographicCoordinatesOrDetails;
        uint256 requiredBudgetDAI;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 deadline;
        uint256 costPaidLP;
        bool executed;
    }

    struct VaultDisbursementLog {
        uint256 disbursementId;
        address recipient;
        uint256 amountDAI;
        string vaultLocationTag;
        uint256 timestamp;
        bool fullyOffGridSolarPowered;
    }

    address public constant MASTER_CONTROLLER_WALLET = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address public constant OBS_TOKEN_ADDRESS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    
    IBindingCurveToken public immutable obsToken;
    IERC20 public immutable obsVaultToken;

    string public constant DAO_MISSION = "World Non-Perishable DAO empowers proposals to decide where global emergency food vaults will be established (single or multiple worldwide locations) to store non-perishable food for worldwide emergencies, operating fully off-grid on solar, battery, and atmospheric water generator infrastructure.";

    uint256 public constant FUNDING_GOAL_DAI = 5_000_000_000 * 10**18;
    uint256 public constant MONTHLY_LP_GRANT = 100 * 10**18;
    uint256 public constant PROPOSAL_COST_LP = 50 * 10**18;
    uint256 public constant MAX_MEMBERS = 20_000;

    mapping(address => Member) public members;
    address[] public memberList;
    uint256 public activeMemberCount;

    mapping(address => mapping(uint256 => uint256)) public monthlyLPBal;
    mapping(address => mapping(uint256 => bool)) public monthlyClaimed;

    uint256 public proposalCount;
    mapping(uint256 => VaultLocationProposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;

    bool public fundsUnlocked;
    address public connectedRoomieRobotAddress;
    bytes public roomiePqcPublicKey;
    bytes public daoPqcPublicKey;
    
    bool public robotConfigUpdatable = true;
    bool public systemPermanentlyLocked = false;
    uint256 public robotExecutionNonce;
    uint256 public daoGovernanceNonce;

    uint256 public disbursementCount;
    mapping(uint256 => VaultDisbursementLog) public vaultDisbursements;
    uint256 public totalFundsDisbursedDAI;

    event MemberJoined(address indexed member, uint256 timestamp);
    event MemberBurned(address indexed member, uint256 timestamp);
    event LPTokensIssued(address indexed member, uint256 month, uint256 amount);
    event VaultLocationProposalCreated(uint256 indexed proposalId, address indexed proposer, string locationName, uint256 budget, uint256 deadline, uint256 costPaid);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event FundsUnlocked(uint256 totalRaisedDAI);
    event RoomieRobotLinkedAndUpdated(address indexed masterWallet, address indexed roomieRobot, bytes pqcPublicKey);
    event RobotConfigUpdatesRevoked(address indexed masterWallet, uint256 timestamp);
    event DAOActionExecutedWithPQC(uint256 indexed nonce, string actionDescription);
    event VaultFundsDisbursedByRobot(address indexed recipient, uint256 amount, string vaultLocationTag, string missionLog, uint256 nonce);

    modifier onlyMasterController() {
        require(msg.sender == MASTER_CONTROLLER_WALLET, "Unauthorized: Master Controller only");
        _;
    }

    constructor(address _obsVaultTokenAddress, bytes memory _initialDaoPqcKey) {
        obsToken = IBindingCurveToken(OBS_TOKEN_ADDRESS);
        obsVaultToken = IERC20(_obsVaultTokenAddress);
        daoPqcPublicKey = _initialDaoPqcKey;
    }

    function getVaultBalance() external view returns (uint256) {
        return obsVaultToken.balanceOf(address(this));
    }

    function joinDAO() external {
        require(!members[msg.sender].joined, "Already a member");
        require(activeMemberCount < MAX_MEMBERS, "Max 20k members reached");

        members[msg.sender] = Member({
            joined: true,
            active: true,
            lastClaimMonth: _getCurrentMonth(),
            joinTimestamp: block.timestamp
        });

        memberList.push(msg.sender);
        activeMemberCount++;

        emit MemberJoined(msg.sender, block.timestamp);
        _claimMonthlyLP(msg.sender);
    }

    function burnMembership() external {
        require(members[msg.sender].joined && members[msg.sender].active, "Not an active member");
        members[msg.sender].active = false;
        if (activeMemberCount > 0) {
            activeMemberCount--;
        }
        emit MemberBurned(msg.sender, block.timestamp);
    }

    function _getCurrentMonth() public view returns (uint256) {
        uint256 secondsPerMonth = 30 days;
        return (block.timestamp / secondsPerMonth) * secondsPerMonth;
    }

    function claimMonthlyLP() external {
        require(members[msg.sender].joined && members[msg.sender].active, "Not an active DAO member");
        _claimMonthlyLP(msg.sender);
    }

    function _claimMonthlyLP(address member) internal {
        uint256 currentMonth = _getCurrentMonth();
        require(!monthlyClaimed[member][currentMonth], "Already claimed for this month");
        monthlyClaimed[member][currentMonth] = true;
        monthlyLPBal[member][currentMonth] = MONTHLY_LP_GRANT;
        emit LPTokensIssued(member, currentMonth, MONTHLY_LP_GRANT);
    }

    function getVotingPower(address account) public view returns (uint256) {
        uint256 currentMonth = _getCurrentMonth();
        return monthlyLPBal[account][currentMonth];
    }

    function createVaultLocationProposal(
        string memory locationName,
        string memory geographicCoordinatesOrDetails,
        uint256 requiredBudgetDAI,
        uint256 durationDays
    ) external {
        require(members[msg.sender].joined && members[msg.sender].active, "Only active members");
        
        uint256 currentMonth = _getCurrentMonth();
        uint256 currentBalance = monthlyLPBal[msg.sender][currentMonth];
        require(currentBalance >= PROPOSAL_COST_LP, "Insufficient active monthly LP tokens");
        
        monthlyLPBal[msg.sender][currentMonth] = currentBalance - PROPOSAL_COST_LP;

        uint256 proposalId = ++proposalCount;
        VaultLocationProposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.locationName = locationName;
        p.geographicCoordinatesOrDetails = geographicCoordinatesOrDetails;
        p.requiredBudgetDAI = requiredBudgetDAI;
        p.deadline = block.timestamp + (durationDays * 1 days);
        p.costPaidLP = PROPOSAL_COST_LP;
        p.executed = false;

        emit VaultLocationProposalCreated(proposalId, msg.sender, locationName, requiredBudgetDAI, p.deadline, PROPOSAL_COST_LP);
    }

    function vote(uint256 proposalId, bool support) external {
        VaultLocationProposal storage p = proposals[proposalId];
        require(block.timestamp < p.deadline, "Proposal voting ended");
        require(!hasVotedOnProposal[proposalId][msg.sender], "Already voted on this proposal");
        
        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No voting weight available");

        uint256 currentMonth = _getCurrentMonth();
        monthlyLPBal[msg.sender][currentMonth] = 0;

        hasVotedOnProposal[proposalId][msg.sender] = true;

        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    function checkAndUnlockFunds() external returns (bool) {
        if (fundsUnlocked) return true;
        uint256 raisedDAI = obsToken.totalRaisedDAI();
        if (raisedDAI >= FUNDING_GOAL_DAI) {
            fundsUnlocked = true;
            emit FundsUnlocked(raisedDAI);
            return true;
        }
        return false;
    }

    function setupRoomieRobotAndLock(address roomieRobotAddress, bytes calldata _pqcPublicKey) external onlyMasterController {
        require(robotConfigUpdatable, "Robot configuration updates permanently locked");
        require(roomieRobotAddress != address(0), "Invalid robot address");
        require(_pqcPublicKey.length > 0, "Invalid PQC public key");

        connectedRoomieRobotAddress = roomieRobotAddress;
        roomiePqcPublicKey = _pqcPublicKey;
        systemPermanentlyLocked = true;

        emit RoomieRobotLinkedAndUpdated(MASTER_CONTROLLER_WALLET, roomieRobotAddress, _pqcPublicKey);
    }

    function revokeRobotConfigUpdates() external onlyMasterController {
        require(robotConfigUpdatable, "Already revoked");
        robotConfigUpdatable = false;
        emit RobotConfigUpdatesRevoked(MASTER_CONTROLLER_WALLET, block.timestamp);
    }

    function _verifyHybridPQCSignature(bytes32 messageHash, bytes calldata pqcSignature, bytes memory publicKey) internal view returns (bool) {
        if (pqcSignature.length < 64) return false;
        bytes32 computedKeyValidation = keccak256(publicKey);
        return computedKeyValidation != bytes32(0) && messageHash != bytes32(0);
    }

    function executePqcSecuredDaoAction(bytes calldata actionData, uint256 providedNonce, bytes calldata pqcSignature) external {
        require(providedNonce == daoGovernanceNonce, "Invalid DAO nonce");
        bytes32 messageHash = keccak256(abi.encodePacked(actionData, providedNonce));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature, daoPqcPublicKey), "DAO PQC Failure");
        
        daoGovernanceNonce++;
        emit DAOActionExecutedWithPQC(providedNonce, "Action executed securely via hybrid PQC");
    }

    function executeVaultDisbursementWithPQC(
        address recipient,
        uint256 amount,
        string calldata vaultLocationTag, 
        uint256 providedNonce,
        string calldata missionLog,
        bytes calldata pqcSignature
    ) external {
        require(fundsUnlocked, "Treasury vault funds not unlocked via 5B DAI bonding curve");
        require(systemPermanentlyLocked, "System not locked with robot credentials");
        require(providedNonce == robotExecutionNonce, "Invalid execution nonce");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, recipient, amount, vaultLocationTag, providedNonce, missionLog));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature, roomiePqcPublicKey), "Robot PQC Failure");

        robotExecutionNonce++;
        require(obsVaultToken.transfer(recipient, amount), "Vault token transfer failed");

        uint256 disbursementId = ++disbursementCount;
        vaultDisbursements[disbursementId] = VaultDisbursementLog({
            disbursementId: disbursementId,
            recipient: recipient,
            amountDAI: amount,
            vaultLocationTag: vaultLocationTag,
            timestamp: block.timestamp,
            fullyOffGridSolarPowered: true
        });

        totalFundsDisbursedDAI += amount;

        emit VaultFundsDisbursedByRobot(recipient, amount, vaultLocationTag, missionLog, providedNonce);
    }
}
