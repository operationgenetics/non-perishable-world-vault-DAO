// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/NonPerishableWorldVaultDAO.sol";

contract MockERC20 is IERC20, IBindingCurveToken {
    mapping(address => uint256) public balances;
    uint256 public totalDaiRaised;

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        balances[sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function bondingCurveTotalDaiRaised() external view returns (uint256) {
        return totalDaiRaised;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function setDaiRaised(uint256 amount) external {
        totalDaiRaised = amount;
    }
}

contract NonPerishableWorldVaultDAOTest is Test {
    NonPerishableWorldVaultDAO public dao;
    MockERC20 public mockToken;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public masterController = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address public robotAddress = address(0x1234567890123456789012345678901234567890);

    bytes public constant INITIAL_DAO_PQC_KEY = "dao-pqc-hybrid-key-v1";
    bytes public constant ROBOT_PQC_KEY = "robot-pqc-hybrid-key-v1";

    function setUp() public {
        bytes memory initialDaoPqcKey = INITIAL_DAO_PQC_KEY;
        dao = new NonPerishableWorldVaultDAO(initialDaoPqcKey);

        mockToken = new MockERC20();
        vm.label(address(mockToken), "MockOBS");
    }

    function testJoinDAO() public {
        vm.prank(user1);
        dao.joinDAO();

        (bool isMember, , , ) = dao.members(user1);
        assertTrue(isMember);
    }

    function testMaxMembers() public {
        for (uint256 i = 0; i < 1000; i++) {
            vm.prank(address(uint160(i + 100)));
            dao.joinDAO();
        }

        vm.prank(address(0x9999));
        vm.expectRevert("Max members reached");
        dao.joinDAO();
    }

    function testMonthlyLPClaim() public {
        vm.prank(user1);
        dao.joinDAO();

        vm.prank(user1);
        dao.claimMonthlyLP();

        uint256 votingPower = dao.getVotingPower(user1);
        assertEq(votingPower, 100 * 1e18);
    }

    function testMonthlyLPExpiration() public {
        vm.prank(user1);
        dao.joinDAO();

        vm.prank(user1);
        dao.claimMonthlyLP();

        assertEq(dao.getVotingPower(user1), 100 * 1e18);

        vm.warp(block.timestamp + 31 days);

        vm.prank(user1);
        dao.claimMonthlyLP();

        assertEq(dao.getVotingPower(user1), 100 * 1e18);
        assertEq(dao.getMemberLPBalance(user1, 0), 0);
    }

    function testCannotClaimTwiceSameMonth() public {
        vm.prank(user1);
        dao.joinDAO();

        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user1);
        vm.expectRevert("Already claimed LP for this month");
        dao.claimMonthlyLP();
    }

    function testCreateProposal() public {
        vm.prank(user1);
        dao.joinDAO();

        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user1);
        uint256 proposalId = dao.createProposal("Test proposal", "Build vault", 1000 * 1e18, 7);

        assertEq(proposalId, 1);
        assertEq(dao.getMemberLPBalance(user1, 0), 50 * 1e18);
    }

    function testCreateProposalInsufficientLP() public {
        vm.prank(user1);
        dao.joinDAO();

        vm.prank(user1);
        vm.expectRevert("Insufficient monthly LP tokens for proposal (need 50 LP)");
        dao.createProposal("Test", "Scope", 1000, 7);
    }

    function testVote() public {
        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user2);
        dao.joinDAO();
        vm.prank(user2);
        dao.claimMonthlyLP();

        vm.prank(user1);
        uint256 proposalId = dao.createProposal("Test", "Scope", 1000, 7);

        vm.prank(user1);
        dao.vote(proposalId, true);

        vm.prank(user2);
        dao.vote(proposalId, false);

        assertEq(dao.getProposalYesVotes(proposalId), 100 * 1e18);
        assertEq(dao.getProposalNoVotes(proposalId), 100 * 1e18);
    }

    function testVoteExpiredLP() public {
        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user1);
        uint256 proposalId = dao.createProposal("Test", "Scope", 1000, 7);

        vm.warp(block.timestamp + 31 days);

        vm.prank(user1);
        vm.expectRevert("No active LP voting weight for current month (LP expires at month end)");
        dao.vote(proposalId, true);
    }

    function testVaultLocationProposalRequiresOffGrid() public {
        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user1);
        vm.expectRevert("Vault location MUST be fully off-grid: solar, battery, atmospheric water, composting toilets required");
        dao.createVaultLocationProposal("Location", "coords", true, false, true, true, 7);
    }

    function testVaultLocationProposalSuccess() public {
        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user1);
        uint256 proposalId = dao.createVaultLocationProposal(
            "Tucson Vault", "32.2226,-110.9747", true, true, true, true, 7
        );

        assertEq(proposalId, 1);

        (string memory desc, , bool solar, bool battery, bool water, bool compost, bool offgrid, , , , ,) = dao.getVaultLocationProposal(proposalId);
        assertEq(desc, "Tucson Vault");
        assertTrue(solar);
        assertTrue(battery);
        assertTrue(water);
        assertTrue(compost);
        assertTrue(offgrid);
    }

    function testVoteVaultLocation() public {
        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user2);
        dao.joinDAO();
        vm.prank(user2);
        dao.claimMonthlyLP();

        vm.prank(user1);
        uint256 proposalId = dao.createVaultLocationProposal("Loc", "coords", true, true, true, true, 7);

        vm.prank(user1);
        dao.voteVaultLocation(proposalId, true);

        vm.prank(user2);
        dao.voteVaultLocation(proposalId, true);

        (,,,,,,,, uint256 yesVotes, uint256 noVotes,,) = dao.getVaultLocationProposal(proposalId);
        assertEq(yesVotes, 200 * 1e18);
        assertEq(noVotes, 0);
    }

    function testCheckAndUnlockFunds() public {
        assertFalse(dao.fundsUnlocked());

        mockToken.setDaiRaised(4_999_999_999 * 1e18);
        assertFalse(dao.checkAndUnlockFunds());

        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        assertTrue(dao.checkAndUnlockFunds());
        assertTrue(dao.fundsUnlocked());

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);
        assertEq(dao.connectedRoomieRobotAddress(), robotAddress);
    }

    function testSetupRoomieRobotAndLock() public {
        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        assertEq(dao.connectedRoomieRobotAddress(), robotAddress);
        assertEq(dao.roomiePqcPublicKey(), ROBOT_PQC_KEY);
    }

    function testRevokeRobotConfigUpdates() public {
        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        vm.prank(masterController);
        dao.revokeRobotConfigUpdates();

        assertTrue(dao.systemPermanentlyLocked());
        assertFalse(dao.robotConfigUpdatable());

        vm.prank(masterController);
        vm.expectRevert("Robot configuration updates have been permanently revoked");
        dao.setupRoomieRobotAndLock(address(0x9988776655443322110099887766554433221100), ROBOT_PQC_KEY);
    }

    function testCreateProjectMilestone() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        vm.prank(masterController);
        dao.createProjectMilestone("Install solar array", 1_000_000 * 1e18, 30);

        assertEq(dao.projectMilestoneCount(), 1);
        assertEq(dao.getMilestoneDescription(1), "Install solar array");
        assertEq(dao.getMilestoneAllocatedAmount(1), 1_000_000 * 1e18);
        assertGt(dao.getMilestoneDeadline(1), block.timestamp);
    }

    function testVerifyMilestoneByRobot() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        vm.prank(masterController);
        dao.createProjectMilestone("Install solar", 1_000_000 * 1e18, 30);

        vm.prank(masterController);
        dao.verifyMilestoneByRobot(1, "robot-sig-hex", "pqc-sig-bytes");

        assertTrue(dao.getMilestoneRobotVerified(1));
        assertEq(dao.getMilestoneRobotVerificationTimestamp(1), block.timestamp);
        assertEq(dao.getMilestoneRobotSignatureHex(1), "robot-sig-hex");
        assertEq(dao.getMilestoneHybridPqcSignature(1), "pqc-sig-bytes");
    }

    function testVerifyMilestoneRobotPacing() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        vm.prank(masterController);
        dao.createProjectMilestone("Milestone 1", 1_000_000 * 1e18, 30);
        vm.prank(masterController);
        dao.createProjectMilestone("Milestone 2", 1_000_000 * 1e18, 30);

        vm.prank(masterController);
        dao.verifyMilestoneByRobot(1, "sig1", "pqc1");

        vm.prank(masterController);
        vm.expectRevert("Robot enforces mathematical pacing: biometric authorization required only once every 2 months");
        dao.verifyMilestoneByRobot(2, "sig2", "pqc2");

        vm.warp(block.timestamp + 61 days);

        vm.prank(masterController);
        dao.verifyMilestoneByRobot(2, "sig2", "pqc2");
    }

    function testCompleteMilestoneAndDisburse() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        mockToken.mint(address(dao), 10_000_000 * 1e18);

        vm.prank(masterController);
        dao.createProjectMilestone("Install solar", 1_000_000 * 1e18, 30);
        vm.prank(masterController);
        dao.verifyMilestoneByRobot(1, "robot-sig", "pqc-sig");

        vm.prank(masterController);
        dao.completeMilestoneAndDisburse(1, user1, 500_000 * 1e18, "Solar installation complete");

        assertEq(mockToken.balanceOf(user1), 500_000 * 1e18);
        assertTrue(dao.getMilestoneCompleted(1));
    }

    function testFinalizeVaultLocation() public {
        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();

        vm.prank(user2);
        dao.joinDAO();
        vm.prank(user2);
        dao.claimMonthlyLP();

        vm.prank(user1);
        uint256 proposalId = dao.createVaultLocationProposal("Tucson", "coords", true, true, true, true, 7);

        vm.prank(user1);
        dao.voteVaultLocation(proposalId, true);
        vm.prank(user2);
        dao.voteVaultLocation(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        vm.prank(masterController);
        dao.finalizeVaultLocation(proposalId);

        (,,,,,,,,,, bool executed, bool selected) = dao.getVaultLocationProposal(proposalId);
        assertTrue(executed);
        assertTrue(selected);
    }

    function testExecuteVaultDisbursementWithPQC() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        mockToken.mint(address(dao), 10_000_000 * 1e18);

        vm.prank(user1);
        dao.joinDAO();
        vm.prank(user1);
        dao.claimMonthlyLP();
        vm.prank(user1);
        uint256 proposalId = dao.createProposal("Fund vault", "Build Tucson vault", 1_000_000 * 1e18, 7);
        vm.prank(user1);
        dao.vote(proposalId, true);

        vm.prank(masterController);
        dao.executeVaultDisbursementWithPQC(user1, 500_000 * 1e18, "Initial funding", proposalId, "robot-sig", "pqc-sig");

        assertEq(mockToken.balanceOf(user1), 500_000 * 1e18);
    }

    function testGetProjectStatus() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);

        vm.prank(masterController);
        dao.createProjectMilestone("Milestone 1", 1_000_000 * 1e18, 30);
        vm.prank(masterController);
        dao.createProjectMilestone("Milestone 2", 1_000_000 * 1e18, 30);

        (bool fundsUnlocked_, uint256 count, uint256 current, bool locked, bool updatable) = dao.getProjectStatus();
        assertTrue(fundsUnlocked_);
        assertEq(count, 2);
        assertEq(current, 1);
        assertFalse(locked);
        assertTrue(updatable);
    }

    function testOnlyMasterController() public {
        vm.prank(user1);
        vm.expectRevert("Unauthorized: Master controller only");
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);
    }

    function testSystemImmutableAfterRevoke() public {
        mockToken.setDaiRaised(5_000_000_000 * 1e18);
        dao.checkAndUnlockFunds();

        vm.prank(masterController);
        dao.setupRoomieRobotAndLock(robotAddress, ROBOT_PQC_KEY);
        vm.prank(masterController);
        dao.revokeRobotConfigUpdates();

        vm.prank(masterController);
        vm.expectRevert("System is permanently immutable");
        dao.createProjectMilestone("Test", 1000, 10);
    }

    function testMissionString() public {
        assertEq(dao.DAO_MISSION(), "Non-perishable food vaults for global emergencies - fully off-grid with solar, battery storage, atmospheric water generation, and composting toilets");
    }

    function testObsTokenAddress() public {
        assertEq(dao.OBS_TOKEN_ADDRESS(), 0x2D8760e2877148d239a54952A458710553B2B54b);
    }

    function testMasterControllerWallet() public {
        assertEq(dao.MASTER_CONTROLLER_WALLET(), 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e);
    }
}