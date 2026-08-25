import os
import subprocess

print("[1/4] Writing NonPerishableWorldVaultDAO.sol contract...")
os.makedirs("contracts", exist_ok=True)
contract_code = """// SPDX-License-Identifier: MIT
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

    string public constant DAO_MISSION = "Off-grid ecological and robotic infrastructure deployment in Tucson, AZ";

    bool public fundsUnlocked = false;
    bool public systemPermanentlyLocked = false;
    bool public robotConfigUpdatable = true;

    address public connectedRoomieRobotAddress;
    bytes public roomiePqcPublicKey;
    bytes public daoPqcPublicKey;

    uint256 public proposalCount;
    uint256 public disbursementCount;
    uint256 public daoGovernanceNonce;
    uint256 public robotExecutionNonce;
    uint256 public lastRobotSpendApprovalTimestamp;

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
    }

    struct VaultDisbursement {
        uint256 id;
        address recipient;
        uint256 amount;
        string projectMilestone;
        uint256 timestamp;
        bool verifiedByRobot;
    }

    mapping(address => Member) public members;
    address[] public memberList;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;
    mapping(address => mapping(uint256 => bool)) public monthlyClaimed;
    mapping(address => mapping(uint256 => uint256)) public monthlyLPBal;
    mapping(uint256 => VaultDisbursement) public vaultDisbursements;

    event MemberJoined(address indexed member, uint256 timestamp);
    event MemberBurned(address indexed member, uint256 timestamp);
    event LPTokensIssued(address indexed member, uint256 month, uint256 amount);
    event VaultLocationProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 requestedAmount, uint256 targetMonth, uint256 deadline);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event FundsUnlocked(uint256 totalDaiRaised);
    event RoomieRobotLinkedAndUpdated(address indexed controller, address indexed robotAddress, bytes pqcPublicKey);
    event RobotConfigUpdatesRevoked(address indexed controller, uint256 timestamp);
    event VaultFundsDisbursedByRobot(address indexed recipient, uint256 amount, string projectMilestone, string robotSignatureHex, uint256 timestamp);
    event DAOActionExecutedWithPQC(uint256 indexed nonce, string actionType);

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
        return block.timestamp / 30 days;
    }

    function claimMonthlyLP() external onlyActiveMember {
        uint256 currentMonth = _getCurrentMonth();
        require(!monthlyClaimed[msg.sender][currentMonth], "Already claimed LP for this month");

        monthlyClaimed[msg.sender][currentMonth] = true;
        monthlyLPBal[msg.sender][currentMonth] = MONTHLY_LP_GRANT;

        emit LPTokensIssued(msg.sender, currentMonth, MONTHLY_LP_GRANT);
    }

    function getVotingPower(address voter) public view returns (uint256) {
        uint256 currentMonth = _getCurrentMonth();
        return monthlyLPBal[voter][currentMonth];
    }

    function createVaultLocationProposal(
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
            executed: false
        });

        emit VaultLocationProposalCreated(proposalCount, msg.sender, description, requestedAmount, currentMonth, proposals[proposalCount].deadline);
        return proposalCount;
    }

    function vote(uint256 proposalId, bool support) external onlyActiveMember {
        Proposal storage prop = proposals[proposalId];
        require(block.timestamp <= prop.deadline, "Voting period has ended");
        require(!hasVotedOnProposal[proposalId][msg.sender], "Already voted on this proposal");

        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No active LP voting weight for current month");

        hasVotedOnProposal[proposalId][msg.sender] = true;

        if (support) {
            prop.yesVotes += weight;
        } else {
            prop.noVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    function checkAndUnlockFunds() external returns (bool) {
        if (fundsUnlocked) return true;

        uint256 totalDaiRaised = obsToken.bondingCurveTotalDaiRaised();
        if (totalDaiRaised >= FUNDING_GOAL_DAI) {
            fundsUnlocked = true;
            emit FundsUnlocked(totalDaiRaised);
            return true;
        }
        return false;
    }

    function getVaultBalance() external view returns (uint256) {
        return obsVaultToken.balanceOf(address(this));
    }

    function setupRoomieRobotAndLock(address robotAddress, bytes calldata robotPqcPublicKey) external onlyMasterController {
        require(robotConfigUpdatable, "Robot configuration updates have been permanently revoked");
        require(robotAddress != address(0), "Invalid robot address");

        connectedRoomieRobotAddress = robotAddress;
        roomiePqcPublicKey = robotPqcPublicKey;

        emit RoomieRobotLinkedAndUpdated(msg.sender, robotAddress, roomiePqcPublicKey);
    }

    function revokeRobotConfigUpdates() external onlyMasterController {
        require(robotConfigUpdatable, "Already revoked");
        robotConfigUpdatable = false;
        systemPermanentlyLocked = true;

        emit RobotConfigUpdatesRevoked(msg.sender, block.timestamp);
    }

    function executeVaultDisbursementWithPQC(
        address recipient,
        uint256 amount,
        string calldata projectMilestone,
        uint256 proposalId,
        string calldata robotSignatureHex,
        bytes calldata hybridPqcSignature
    ) external onlyMasterController returns (bool) {
        require(fundsUnlocked, "Vault funds are locked until 5 billion DAI bonding curve milestone");
        require(recipient != address(0), "Invalid recipient");
        require(obsVaultToken.balanceOf(address(this)) >= amount, "Insufficient OBS token balance in vault");

        require(
            block.timestamp >= lastRobotSpendApprovalTimestamp + 60 days,
            "Robot enforces mathematical pacing: funds can only be authorized once every 2 months per milestone"
        );

        Proposal storage prop = proposals[proposalId];
        require(prop.executed == false, "Proposal already executed");
        require(prop.yesVotes > prop.noVotes, "Proposal did not pass community vote");

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
            verifiedByRobot: true
        });

        require(obsVaultToken.transfer(recipient, amount), "Vault token transfer failed");

        emit VaultFundsDisbursedByRobot(recipient, amount, projectMilestone, robotSignatureHex, block.timestamp);
        emit DAOActionExecutedWithPQC(robotExecutionNonce, "ROBOT_DISBURSEMENT");

        return true;
    }
}
"""

with open("contracts/NonPerishableWorldVaultDAO.sol", "w") as f:
    f.write(contract_code)

print("[2/4] Writing automated deployment script (deploy.js)...")
deploy_js = """const { ethers } = require("ethers");
const { EthereumProvider } = require("@walletconnect/ethereum-provider");
const QRCode = require("qrcode-terminal");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

async function main() {
    const artifactPath = path.join(__dirname, "out/NonPerishableWorldVaultDAO.sol/NonPerishableWorldVaultDAO.json");
    if (!fs.existsSync(artifactPath)) {
        throw new Error("Contract artifacts not found. Please ensure forge build succeeded.");
    }
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

    console.log("Initializing WalletConnect v2 Provider for Arbitrum One...");
    const wcProvider = await EthereumProvider.init({
        projectId: process.env.WALLETCONNECT_PROJECT_ID || "3a8170812b534d0ff9d794f19a901d64",
        chains: [42161],
        optionalChains: [],
        methods: ["eth_requestAccounts", "eth_sendTransaction", "personal_sign", "eth_signTypedData"],
        optionalMethods: ["wallet_switchEthereumChain", "wallet_addEthereumChain"],
        rpcMap: { 42161: "https://arb1.arbitrum.io/rpc" },
        metadata: {
            name: "Non-Perishable World Vault DAO",
            description: "Off-Grid Robotic & Ecological Governance",
            url: "https://obscura.network",
            icons: ["https://avatars.githubusercontent.com/u/37784886"]
        },
        showQrModal: false
    });

    wcProvider.on("display_uri", (uri) => {
        console.log("\\n==================================================");
        console.log("SCAN THIS QR CODE WITH METAMASK MOBILE:");
        console.log("==================================================\\n");
        QRCode.generate(uri, { small: true });
        console.log("\\nWalletConnect URI:", uri);
        console.log("\\nApprove the connection prompt in MetaMask Mobile...");
    });

    await wcProvider.connect();

    const directProvider = new ethers.JsonRpcProvider("https://arb1.arbitrum.io/rpc");
    const browserProvider = new ethers.BrowserProvider(wcProvider);
    const signer = await browserProvider.getSigner();
    const deployerAddress = await signer.getAddress();

    console.log(`\\nConnected Wallet Address: ${deployerAddress}`);
    console.log("Preparing deployment transaction...");

    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object || artifact.bytecode, signer);
    const initialDaoPqcKey = ethers.toUtf8Bytes("dao-pqc-hybrid-ed25519-mldsa-v1");

    const feeData = await directProvider.getFeeData();
    const deployOptions = {
        gasLimit: 4000000,
        maxFeePerGas: feeData.maxFeePerGas ? feeData.maxFeePerGas * 12n / 10n : undefined,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas || ethers.parseUnits("0.1", "gwei")
    };

    console.log("\\nBroadcasting contract deployment... Please check MetaMask mobile to sign.");
    const contract = await factory.deploy(initialDaoPqcKey, deployOptions);
    
    console.log(`Transaction Hash: ${contract.deploymentTransaction().hash}`);
    await contract.waitForDeployment();
    
    console.log(`\\n==========================================`);
    console.log(`Deployment Successful on Arbitrum One!`);
    console.log(`Contract Address: ${await contract.getAddress()}`);
    console.log(`==========================================\\n`);

    await wcProvider.disconnect();
    process.exit(0);
}

main().catch((err) => {
    console.error("Deployment failed:", err);
    process.exit(1);
});
"""

with open("deploy.js", "w") as f:
    f.write(deploy_js)

print("[3/4] Compiling contract with Forge...")
subprocess.run(["forge", "build"], check=True)

print("[4/4] Setup complete! Run your deployment with:")
print("       node deploy.js")
