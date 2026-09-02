// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBindingCurveToken {
    function bondingCurveTotalDaiRaised() external view returns (uint256);
}

contract NonPerishableWorldVaultDAO {
    address public constant OBS_TOKEN_ADDRESS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    address public constant MASTER_CONTROLLER_WALLET = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    IERC20 public immutable obsVaultToken;
    IBindingCurveToken public immutable obsToken;

    uint256 public constant FUNDING_GOAL_DAI = 5_000_000_000 * 1e18;
    uint256 public constant MONTHLY_LP_GRANT = 100 * 1e18;
    uint256 public constant PROPOSAL_COST_LP = 50 * 1e18;
    uint256 public constant MAX_MEMBERS = 1000;
    uint256 public constant SECONDS_PER_MONTH = 30 days;
    uint256 public constant ROBOT_AUTH_INTERVAL = 60 days;
    uint256 public constant MAX_PROJECT_DURATION = 730 days;

    string public constant DAO_MISSION = "Non-perishable food vaults for global emergencies - fully off-grid with solar, battery storage, atmospheric water generation, and composting toilets";

    bool public fundsUnlocked = false;
    bool public systemPermanentlyLocked = false;
    bool public robotConfigUpdatable = true;

    address public connectedRoomieRobotAddress;
    bytes public roomiePqcPublicKey;
    bytes public daoPqcPublicKey;

    uint256 public proposalCount;
    uint256 public vaultLocationProposalCount;
    uint256 public disbursementCount;
    uint256 public daoGovernanceNonce;
    uint256 public robotExecutionNonce;
    uint256 public lastRobotSpendApprovalTimestamp;
    uint256 public projectStartTimestamp;

    struct Member {
        bool isMember;
        bool activeLP;
        uint256 joinTimestamp;
        uint256 lastClaimMonth;
    }

    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        string projectScope;
        uint256 requestedAmount;
        uint256 deadline;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 targetMonth;
        bool executed;
        bool isVaultLocationProposal;
    }

    struct VaultLocationProposal {
        uint256 id;
        address proposer;
        string locationDescription;
        string coordinates;
        bool hasSolar;
        bool hasBatteryStorage;
        bool hasAtmosphericWaterGeneration;
        bool hasCompostingToilets;
        bool isFullyOffGrid;
        uint256 deadline;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 targetMonth;
        bool executed;
        bool selected;
    }

    struct ProjectMilestone {
        uint256 id;
        string description;
        uint256 allocatedAmount;
        uint256 deadline;
        bool completed;
        bool robotVerified;
        uint256 robotVerificationTimestamp;
        string robotSignatureHex;
        bytes hybridPqcSignature;
    }

    struct VaultDisbursement {
        uint256 id;
        address recipient;
        uint256 amount;
        string projectMilestone;
        uint256 timestamp;
        bool verifiedByRobot;
        uint256 milestoneId;
    }

    mapping(address => Member) public members;
    address[] public memberList;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => VaultLocationProposal) public vaultLocationProposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnVaultLocation;
    mapping(address => mapping(uint256 => bool)) public monthlyClaimed;
    mapping(address => mapping(uint256 => uint256)) public monthlyLPBal;
    mapping(uint256 => VaultDisbursement) public vaultDisbursements;
    mapping(uint256 => ProjectMilestone) public projectMilestones;
    uint256 public projectMilestoneCount;

    event MemberJoined(address indexed member, uint256 timestamp);
    event MemberBurned(address indexed member, uint256 timestamp);
    event LPTokensIssued(address indexed member, uint256 month, uint256 amount);
    event LPTokensExpired(address indexed member, uint256 month, uint256 amount);
    event VaultLocationProposalCreated(uint256 indexed proposalId, address indexed proposer, string locationDescription, bool isFullyOffGrid, uint256 deadline);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event VaultLocationVoted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event FundsUnlocked(uint256 totalDaiRaised);
    event RoomieRobotLinkedAndUpdated(address indexed controller, address indexed robotAddress, bytes pqcPublicKey);
    event RobotConfigUpdatesRevoked(address indexed controller, uint256 timestamp);
    event VaultFundsDisbursedByRobot(address indexed recipient, uint256 amount, string projectMilestone, string robotSignatureHex, uint256 timestamp);
    event DAOActionExecutedWithPQC(uint256 indexed nonce, string actionType);
    event ProjectMilestoneCreated(uint256 indexed milestoneId, string description, uint256 allocatedAmount, uint256 deadline);
    event ProjectMilestoneCompleted(uint256 indexed milestoneId, uint256 timestamp, string robotSignatureHex);
    event VaultLocationSelected(uint256 indexed proposalId, string locationDescription);

    constructor(bytes memory _initialDaoPqcKey) {
        obsVaultToken = IERC20(OBS_TOKEN_ADDRESS);
        obsToken = IBindingCurveToken(OBS_TOKEN_ADDRESS);
        daoPqcPublicKey = _initialDaoPqcKey;
    }

    modifier onlyMasterController() {
        require(msg.sender == MASTER_CONTROLLER_WALLET, "Unauthorized: Master controller only");
        _;
    }

    modifier onlyActiveMember() {
        require(members[msg.sender].isMember, "Not an active DAO member");
        _;
    }

    modifier onlyWhenFundsUnlocked() {
        require(fundsUnlocked, "Vault funds are locked until 5 billion DAI bonding curve milestone");
        _;
    }

    modifier onlyIfSystemMutable() {
        require(!systemPermanentlyLocked, "System is permanently immutable");
        _;
    }

    function joinDAO() external {
        require(!members[msg.sender].isMember, "Already a DAO member");
        require(memberList.length < MAX_MEMBERS, "Max members reached");

        members[msg.sender] = Member({
            isMember: true,
            activeLP: true,
            joinTimestamp: block.timestamp,
            lastClaimMonth: 0
        });
        memberList.push(msg.sender);

        emit MemberJoined(msg.sender, block.timestamp);
    }

    function burnMembership() external onlyActiveMember {
        members[msg.sender].isMember = false;
        members[msg.sender].activeLP = false;
        emit MemberBurned(msg.sender, block.timestamp);
    }

    function _getCurrentMonth() public view returns (uint256) {
        return block.timestamp / SECONDS_PER_MONTH;
    }

    function _getMonthStartTimestamp(uint256 month) public pure returns (uint256) {
        return month * SECONDS_PER_MONTH;
    }

    function _getMonthEndTimestamp(uint256 month) public pure returns (uint256) {
        return (month + 1) * SECONDS_PER_MONTH - 1;
    }

    function claimMonthlyLP() external onlyActiveMember {
        uint256 currentMonth = _getCurrentMonth();
        require(!monthlyClaimed[msg.sender][currentMonth], "Already claimed LP for this month");

        _expirePreviousMonthLP(msg.sender, currentMonth);

        monthlyClaimed[msg.sender][currentMonth] = true;
        monthlyLPBal[msg.sender][currentMonth] = MONTHLY_LP_GRANT;

        emit LPTokensIssued(msg.sender, currentMonth, MONTHLY_LP_GRANT);
    }

    function _expirePreviousMonthLP(address member, uint256 currentMonth) internal {
        if (currentMonth == 0) return;

        uint256 previousMonth = currentMonth - 1;
        uint256 previousMonthEnd = _getMonthEndTimestamp(previousMonth);

        if (block.timestamp > previousMonthEnd) {
            uint256 expiredAmount = monthlyLPBal[member][previousMonth];
            if (expiredAmount > 0) {
                monthlyLPBal[member][previousMonth] = 0;
                emit LPTokensExpired(member, previousMonth, expiredAmount);
            }
        }
    }

    function getVotingPower(address voter) public view returns (uint256) {
        uint256 currentMonth = _getCurrentMonth();
        uint256 currentMonthStart = _getMonthStartTimestamp(currentMonth);
        uint256 currentMonthEnd = _getMonthEndTimestamp(currentMonth);

        if (block.timestamp < currentMonthStart || block.timestamp > currentMonthEnd) {
            return 0;
        }

        return monthlyLPBal[voter][currentMonth];
    }

    function createProposal(
        string calldata description,
        string calldata projectScope,
        uint256 requestedAmount,
        uint256 durationDays
    ) external onlyActiveMember returns (uint256) {
        uint256 currentMonth = _getCurrentMonth();
        require(monthlyLPBal[msg.sender][currentMonth] >= PROPOSAL_COST_LP, "Insufficient monthly LP tokens for proposal (need 50 LP)");

        monthlyLPBal[msg.sender][currentMonth] -= PROPOSAL_COST_LP;

        proposalCount++;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposer: msg.sender,
            description: description,
            projectScope: projectScope,
            requestedAmount: requestedAmount,
            deadline: block.timestamp + (durationDays * 1 days),
            yesVotes: 0,
            noVotes: 0,
            targetMonth: currentMonth,
            executed: false,
            isVaultLocationProposal: false
        });

        emit Voted(proposalCount, msg.sender, true, PROPOSAL_COST_LP);
        return proposalCount;
    }

    function createVaultLocationProposal(
        string calldata locationDescription,
        string calldata coordinates,
        bool hasSolar,
        bool hasBatteryStorage,
        bool hasAtmosphericWaterGeneration,
        bool hasCompostingToilets,
        uint256 durationDays
    ) external onlyActiveMember returns (uint256) {
        uint256 currentMonth = _getCurrentMonth();
        require(monthlyLPBal[msg.sender][currentMonth] >= PROPOSAL_COST_LP, "Insufficient monthly LP tokens for proposal (need 50 LP)");

        bool isFullyOffGrid = hasSolar && hasBatteryStorage && hasAtmosphericWaterGeneration && hasCompostingToilets;
        require(isFullyOffGrid, "Vault location MUST be fully off-grid: solar, battery, atmospheric water, composting toilets required");

        monthlyLPBal[msg.sender][currentMonth] -= PROPOSAL_COST_LP;

        vaultLocationProposalCount++;
        vaultLocationProposals[vaultLocationProposalCount] = VaultLocationProposal({
            id: vaultLocationProposalCount,
            proposer: msg.sender,
            locationDescription: locationDescription,
            coordinates: coordinates,
            hasSolar: hasSolar,
            hasBatteryStorage: hasBatteryStorage,
            hasAtmosphericWaterGeneration: hasAtmosphericWaterGeneration,
            hasCompostingToilets: hasCompostingToilets,
            isFullyOffGrid: isFullyOffGrid,
            deadline: block.timestamp + (durationDays * 1 days),
            yesVotes: 0,
            noVotes: 0,
            targetMonth: currentMonth,
            executed: false,
            selected: false
        });

        emit VaultLocationProposalCreated(vaultLocationProposalCount, msg.sender, locationDescription, isFullyOffGrid, vaultLocationProposals[vaultLocationProposalCount].deadline);
        return vaultLocationProposalCount;
    }

    function vote(uint256 proposalId, bool support) external onlyActiveMember {
        Proposal storage prop = proposals[proposalId];
        require(block.timestamp <= prop.deadline, "Voting period has ended");
        require(!hasVotedOnProposal[proposalId][msg.sender], "Already voted on this proposal");
        require(!prop.isVaultLocationProposal, "Use voteVaultLocation for vault location proposals");

        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No active LP voting weight for current month (LP expires at month end)");

        hasVotedOnProposal[proposalId][msg.sender] = true;

        if (support) {
            prop.yesVotes += weight;
        } else {
            prop.noVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    function voteVaultLocation(uint256 proposalId, bool support) external onlyActiveMember {
        VaultLocationProposal storage prop = vaultLocationProposals[proposalId];
        require(block.timestamp <= prop.deadline, "Voting period has ended");
        require(!hasVotedOnVaultLocation[proposalId][msg.sender], "Already voted on this vault location proposal");

        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No active LP voting weight for current month (LP expires at month end)");

        hasVotedOnVaultLocation[proposalId][msg.sender] = true;

        if (support) {
            prop.yesVotes += weight;
        } else {
            prop.noVotes += weight;
        }

        emit VaultLocationVoted(proposalId, msg.sender, support, weight);
    }

    function checkAndUnlockFunds() external returns (bool) {
        if (fundsUnlocked) return true;

        uint256 totalDaiRaised = obsToken.bondingCurveTotalDaiRaised();
        if (totalDaiRaised >= FUNDING_GOAL_DAI) {
            fundsUnlocked = true;
            projectStartTimestamp = block.timestamp;
            emit FundsUnlocked(totalDaiRaised);
            return true;
        }
        return false;
    }

    function getVaultBalance() external view returns (uint256) {
        return obsVaultToken.balanceOf(address(this));
    }

    function setupRoomieRobotAndLock(address robotAddress, bytes calldata robotPqcPublicKey) external onlyMasterController onlyIfSystemMutable {
        require(robotConfigUpdatable, "Robot configuration updates have been permanently revoked");
        require(robotAddress != address(0), "Invalid robot address");
        require(robotPqcPublicKey.length > 0, "PQC public key required");

        connectedRoomieRobotAddress = robotAddress;
        roomiePqcPublicKey = robotPqcPublicKey;

        emit RoomieRobotLinkedAndUpdated(msg.sender, robotAddress, robotPqcPublicKey);
    }

    function revokeRobotConfigUpdates() external onlyMasterController {
        require(robotConfigUpdatable, "Already revoked");
        robotConfigUpdatable = false;
        systemPermanentlyLocked = true;

        emit RobotConfigUpdatesRevoked(msg.sender, block.timestamp);
    }

    function createProjectMilestone(
        string calldata description,
        uint256 allocatedAmount,
        uint256 durationDays
    ) external onlyMasterController onlyWhenFundsUnlocked onlyIfSystemMutable {
        require(projectStartTimestamp > 0, "Funds not yet unlocked");
        require(projectMilestoneCount == 0 || projectMilestones[projectMilestoneCount].completed, "Previous milestone not completed");
        require(durationDays > 0 && durationDays <= MAX_PROJECT_DURATION, "Invalid milestone duration");

        projectMilestoneCount++;
        projectMilestones[projectMilestoneCount] = ProjectMilestone({
            id: projectMilestoneCount,
            description: description,
            allocatedAmount: allocatedAmount,
            deadline: block.timestamp + (durationDays * 1 days),
            completed: false,
            robotVerified: false,
            robotVerificationTimestamp: 0,
            robotSignatureHex: "",
            hybridPqcSignature: bytes("")
        });

        emit ProjectMilestoneCreated(projectMilestoneCount, description, allocatedAmount, projectMilestones[projectMilestoneCount].deadline);
    }

    function verifyMilestoneByRobot(
        uint256 milestoneId,
        string calldata robotSignatureHex,
        bytes calldata hybridPqcSignature
    ) external onlyMasterController onlyWhenFundsUnlocked onlyIfSystemMutable {
        ProjectMilestone storage milestone = projectMilestones[milestoneId];
        require(milestoneId > 0 && milestoneId <= projectMilestoneCount, "Invalid milestone");
        require(!milestone.completed, "Milestone already completed");
        require(!milestone.robotVerified, "Already robot verified");
        require(block.timestamp <= milestone.deadline, "Milestone deadline passed - project timeout enforced");
        require(block.timestamp >= lastRobotSpendApprovalTimestamp + ROBOT_AUTH_INTERVAL, "Robot enforces mathematical pacing: biometric authorization required only once every 2 months");
        require(connectedRoomieRobotAddress != address(0), "Robot not configured");
        require(roomiePqcPublicKey.length > 0, "Robot PQC public key not set");

        _verifyHybridPqcSignature(robotSignatureHex, hybridPqcSignature);

        milestone.robotVerified = true;
        milestone.robotVerificationTimestamp = block.timestamp;
        milestone.robotSignatureHex = robotSignatureHex;
        milestone.hybridPqcSignature = hybridPqcSignature;

        lastRobotSpendApprovalTimestamp = block.timestamp;
        robotExecutionNonce++;

        emit ProjectMilestoneCompleted(milestoneId, block.timestamp, robotSignatureHex);
        emit DAOActionExecutedWithPQC(robotExecutionNonce, "MILESTONE_VERIFICATION");
    }

    function completeMilestoneAndDisburse(
        uint256 milestoneId,
        address recipient,
        uint256 amount,
        string calldata projectMilestoneDescription
    ) external onlyMasterController onlyWhenFundsUnlocked onlyIfSystemMutable {
        ProjectMilestone storage milestone = projectMilestones[milestoneId];
        require(milestoneId > 0 && milestoneId <= projectMilestoneCount, "Invalid milestone");
        require(milestone.robotVerified, "Milestone not robot verified");
        require(!milestone.completed, "Milestone already completed");
        require(amount <= milestone.allocatedAmount, "Amount exceeds allocated for milestone");
        require(obsVaultToken.balanceOf(address(this)) >= amount, "Insufficient OBS token balance in vault");

        milestone.completed = true;

        disbursementCount++;
        vaultDisbursements[disbursementCount] = VaultDisbursement({
            id: disbursementCount,
            recipient: recipient,
            amount: amount,
            projectMilestone: projectMilestoneDescription,
            timestamp: block.timestamp,
            verifiedByRobot: true,
            milestoneId: milestoneId
        });

        require(obsVaultToken.transfer(recipient, amount), "Vault token transfer failed");

        emit VaultFundsDisbursedByRobot(recipient, amount, projectMilestoneDescription, milestone.robotSignatureHex, block.timestamp);
        emit DAOActionExecutedWithPQC(robotExecutionNonce, "MILESTONE_DISBURSEMENT");
    }

    function executeVaultDisbursementWithPQC(
        address recipient,
        uint256 amount,
        string calldata projectMilestone,
        uint256 proposalId,
        string calldata robotSignatureHex,
        bytes calldata hybridPqcSignature
    ) external onlyMasterController onlyWhenFundsUnlocked onlyIfSystemMutable returns (bool) {
        require(recipient != address(0), "Invalid recipient");
        require(obsVaultToken.balanceOf(address(this)) >= amount, "Insufficient OBS token balance in vault");

        require(
            block.timestamp >= lastRobotSpendApprovalTimestamp + ROBOT_AUTH_INTERVAL,
            "Robot enforces mathematical pacing: funds can only be authorized once every 2 months per milestone"
        );

        Proposal storage prop = proposals[proposalId];
        require(prop.id > 0, "Invalid proposal");
        require(prop.executed == false, "Proposal already executed");
        require(prop.yesVotes > prop.noVotes, "Proposal did not pass community vote");
        require(connectedRoomieRobotAddress != address(0), "Robot not configured");
        require(roomiePqcPublicKey.length > 0, "Robot PQC public key not set");

        _verifyHybridPqcSignature(robotSignatureHex, hybridPqcSignature);

        lastRobotSpendApprovalTimestamp = block.timestamp;
        robotExecutionNonce++;

        prop.executed = true;
        disbursementCount++;

        vaultDisbursements[disbursementCount] = VaultDisbursement({
            id: disbursementCount,
            recipient: recipient,
            amount: amount,
            projectMilestone: projectMilestone,
            timestamp: block.timestamp,
            verifiedByRobot: true,
            milestoneId: 0
        });

        require(obsVaultToken.transfer(recipient, amount), "Vault token transfer failed");

        emit VaultFundsDisbursedByRobot(recipient, amount, projectMilestone, robotSignatureHex, block.timestamp);
        emit DAOActionExecutedWithPQC(robotExecutionNonce, "ROBOT_DISBURSEMENT");

        return true;
    }

    function finalizeVaultLocation(uint256 proposalId) external onlyMasterController onlyIfSystemMutable {
        VaultLocationProposal storage prop = vaultLocationProposals[proposalId];
        require(prop.id > 0, "Invalid vault location proposal");
        require(block.timestamp > prop.deadline, "Voting period not ended");
        require(!prop.executed, "Already finalized");
        require(prop.yesVotes > prop.noVotes, "Proposal did not pass");
        require(prop.isFullyOffGrid, "Location must be fully off-grid");

        for (uint256 i = 1; i <= vaultLocationProposalCount; i++) {
            if (vaultLocationProposals[i].selected) {
                vaultLocationProposals[i].selected = false;
            }
        }

        prop.executed = true;
        prop.selected = true;

        emit VaultLocationSelected(proposalId, prop.locationDescription);
    }

    function _verifyHybridPqcSignature(string calldata robotSignatureHex, bytes calldata hybridPqcSignature) internal view {
        require(bytes(robotSignatureHex).length > 0, "Robot signature required");
        require(hybridPqcSignature.length > 0, "Hybrid PQC signature required");
        require(roomiePqcPublicKey.length > 0, "Robot PQC public key not configured");

        // In production, this would verify the hybrid PQC signature (e.g., Dilithium + ECDSA)
        // using the robot's PQC public key stored on-chain. The biometric template
        // remains ONLY on the MCU hardware, never on-chain.
        // This is a placeholder for the actual PQC verification logic.
    }

    function getProjectStatus() external view returns (
        bool fundsUnlocked_,
        uint256 projectMilestoneCount_,
        uint256 currentMilestone_,
        bool systemPermanentlyLocked_,
        bool robotConfigUpdatable_
    ) {
        uint256 current = 0;
        for (uint256 i = 1; i <= projectMilestoneCount; i++) {
            if (!projectMilestones[i].completed) {
                current = i;
                break;
            }
        }
        return (fundsUnlocked, projectMilestoneCount, current, systemPermanentlyLocked, robotConfigUpdatable);
    }

    function getVaultLocationProposal(uint256 proposalId) external view returns (
        string memory locationDescription,
        string memory coordinates,
        bool hasSolar,
        bool hasBatteryStorage,
        bool hasAtmosphericWaterGeneration,
        bool hasCompostingToilets,
        bool isFullyOffGrid,
        uint256 deadline,
        uint256 yesVotes,
        uint256 noVotes,
        bool executed,
        bool selected
    ) {
        VaultLocationProposal storage prop = vaultLocationProposals[proposalId];
        return (
            prop.locationDescription,
            prop.coordinates,
            prop.hasSolar,
            prop.hasBatteryStorage,
            prop.hasAtmosphericWaterGeneration,
            prop.hasCompostingToilets,
            prop.isFullyOffGrid,
            prop.deadline,
            prop.yesVotes,
            prop.noVotes,
            prop.executed,
            prop.selected
        );
    }

    function getMemberLPBalance(address member, uint256 month) external view returns (uint256) {
        return monthlyLPBal[member][month];
    }

    function isLPExpired(address member, uint256 month) external view returns (bool) {
        uint256 monthEnd = _getMonthEndTimestamp(month);
        return block.timestamp > monthEnd;
    }

    function getProposalYesVotes(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].yesVotes;
    }

    function getProposalNoVotes(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].noVotes;
    }

    function getMilestoneDescription(uint256 milestoneId) external view returns (string memory) {
        return projectMilestones[milestoneId].description;
    }

    function getMilestoneAllocatedAmount(uint256 milestoneId) external view returns (uint256) {
        return projectMilestones[milestoneId].allocatedAmount;
    }

    function getMilestoneDeadline(uint256 milestoneId) external view returns (uint256) {
        return projectMilestones[milestoneId].deadline;
    }

    function getMilestoneCompleted(uint256 milestoneId) external view returns (bool) {
        return projectMilestones[milestoneId].completed;
    }

    function getMilestoneRobotVerified(uint256 milestoneId) external view returns (bool) {
        return projectMilestones[milestoneId].robotVerified;
    }

    function getMilestoneRobotVerificationTimestamp(uint256 milestoneId) external view returns (uint256) {
        return projectMilestones[milestoneId].robotVerificationTimestamp;
    }

    function getMilestoneRobotSignatureHex(uint256 milestoneId) external view returns (string memory) {
        return projectMilestones[milestoneId].robotSignatureHex;
    }

    function getMilestoneHybridPqcSignature(uint256 milestoneId) external view returns (bytes memory) {
        return projectMilestones[milestoneId].hybridPqcSignature;
    }
}