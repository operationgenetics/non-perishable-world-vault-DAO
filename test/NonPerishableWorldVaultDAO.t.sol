// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/NonPerishableWorldVaultDAO.sol";

contract MockBindingCurve is IBindingCurveToken {
    uint256 public raisedDAI;

    function setRaisedDAI(uint256 _raisedDAI) external {
        raisedDAI = _raisedDAI;
    }

    function totalRaisedDAI() external view override returns (uint256) {
        return raisedDAI;
    }
}

contract MockERC20Vault is IERC20 {
    mapping(address => uint256) public balances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }
}

contract NonPerishableWorldVaultDAOTest is Test {
    NonPerishableWorldVaultDAO dao;
    MockBindingCurve bindingCurve;
    MockERC20Vault vaultToken;

    address masterController = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address roomieBot = address(0x444);
    address globalCitizen = address(0x333);
    address reliefRecipient = address(0x888);

    bytes initialDaoPqcKey = hex"1212121234343434";
    bytes roomiePqcKey = hex"ababababcdcdcdcd";

    function setUp() public {
        vaultToken = new MockERC20Vault();
        dao = new NonPerishableWorldVaultDAO(address(vaultToken), initialDaoPqcKey);
    }

    function test_DeploymentAndConstants() public view {
        assertEq(dao.MASTER_CONTROLLER_WALLET(), masterController);
        assertEq(dao.OBS_TOKEN_ADDRESS(), 0x2D8760e2877148d239a54952A458710553B2B54b);
        assertEq(dao.FUNDING_GOAL_DAI(), 5_000_000_000 * 10**18);
    }

    function test_MembershipAndVaultLocationProposal() public {
        vm.prank(globalCitizen);
        dao.joinDAO();

        assertEq(dao.getVotingPower(globalCitizen), 100 * 10**18);

        // Create proposal for a global non-perishable food vault location (costs 50 LP)
        vm.prank(globalCitizen);
        dao.createVaultLocationProposal(
            "Central European Emergency Food Depot", 
            "Latitude: 50.0880 N, Longitude: 14.4208 E (Underground reinforced bunker)", 
            250_000 * 10**18, 
            14
        );

        assertEq(dao.getVotingPower(globalCitizen), 50 * 10**18);
    }

    function test_MasterControllerRobotLockAndRevocation() public {
        vm.startPrank(masterController);
        dao.setupRoomieRobotAndLock(roomieBot, roomiePqcKey);
        assertEq(dao.connectedRoomieRobotAddress(), roomieBot);
        assertTrue(dao.systemPermanentlyLocked());

        dao.revokeRobotConfigUpdates();
        assertFalse(dao.robotConfigUpdatable());
        vm.stopPrank();
    }
}
