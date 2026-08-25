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
    address public masterController = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    function setUp() public {
        bytes memory initialDaoPqcKey = "dao-pqc-hybrid-key-v1";
        dao = new NonPerishableWorldVaultDAO(initialDaoPqcKey);
    }

    function testJoinDAO() public {
        vm.prank(user1);
        dao.joinDAO();
        
        (bool isMember, , , ) = dao.members(user1);
        assertTrue(isMember);
    }

    function testMonthlyLPClaim() public {
        vm.prank(user1);
        dao.joinDAO();

        vm.prank(user1);
        dao.claimMonthlyLP();

        uint256 votingPower = dao.getVotingPower(user1);
        assertEq(votingPower, 100 * 1e18);
    }
}
