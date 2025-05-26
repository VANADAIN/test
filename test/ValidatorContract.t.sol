// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ValidatorContract} from "../src/ValidatorContract.sol";
import {RewardToken} from "../src/RewardToken.sol";
import {License} from "../src/License.sol";

contract ValidatorContractTest is Test {
    error UnlockCooldown();
    
    ValidatorContract public vc;
    RewardToken public rt;
    License l;

    // validators
    address public v1;
    address public v2;


    function setUp() public {
        // deploy tokens 
        rt = new RewardToken(address(this), address(this));
        l = new License(address(this));
        

        // deploy impl
        ValidatorContract impl = new ValidatorContract();

        // deploy proxy
        address proxyRaw = UnsafeUpgrades.deployUUPSProxy(
            address(impl),
            abi.encodeCall(ValidatorContract.initialize, address(this))
        );
        vc = ValidatorContract(address(proxyRaw));

        // setup contract settings
        vc.setRewardToken(address(rt));
        vc.setLicense(address(l));
        vc.setEpochDuration(1 hours);
        vc.setDecreasePercent(1000); // 10%
        vc.setRewardAndStart(10_000 * 1e18, block.timestamp + 1);



        // create validators
        v1 = vm.addr(1);
        v2 = vm.addr(2);

        // transfer reward tokena
        rt.transfer(address(vc), 100_000 * 1e18);

        // mint licences
        l.safeMint(v1);
        l.safeMint(v1);
        l.safeMint(v1);

        l.safeMint(v2);
        l.safeMint(v2);
        l.safeMint(v2);

        uint256 balance = rt.balanceOf(address(vc));
        assertEq(balance, 100_000 * 1e18);
        assertEq(l.ownerOf(0), v1);
    }

    function test_rewardsActive() public {
        // wait 1 minute and check rewards
        skip(1 minutes);

        uint256 epoch = vc.nowEpoch();
        uint256 epochRewards = vc.epochRewards(epoch);

        assertEq(epoch, 0);
        assertEq(epochRewards, 10_000 * 1e18);

        epochRewards = vc.epochRewards(epoch + 1);
        assertEq(epochRewards, 9_000 * 1e18);

        epochRewards = vc.currentFullRewards();
        assertEq(epochRewards, 10_000 * 1e18);

        uint256 expected = epochRewards / vc.epochDuration();
        epochRewards = vc.currentRewardPerSecond();
        console.log("current rewards per second: ", epochRewards);
        assertEq(epochRewards, expected);

        uint256 timeP = vc.currentEpochTimePassed();
        console.log("time passed: ", timeP);
        assertEq(timeP, 60);


        timeP = vc.epochTimePassed(epoch + 1);
        assertEq(timeP, 0);

        epochRewards = vc.pendingEpochRewards(epoch);
        console.log("pending now: ", epochRewards);
        expected = (10_000 * 1e18);
        expected = expected / 60;
        /// !!! division rounding
        assertApproxEqRel(epochRewards, expected, 1000);
        assertNotEq(epochRewards, 0);

        epochRewards = vc.pendingPoolRewards();
        console.log("POOL: ", epochRewards);
        assertEq(epochRewards, vc.pendingEpochRewards(epoch));

        epochRewards = vc.pendingEpochRewards(epoch + 1);
        assertEq(epochRewards, 0);

        skip(1 hours + 1 minutes);

        // pool now != epoch, bcz 2 epochs
        uint256 epochPending = vc.pendingEpochRewards(epoch + 1);
        uint256 poolRewards = vc.pendingPoolRewards();
        console.log("NOW");
        console.log("POOL: ", poolRewards);
        console.log("PENDING: ", epochPending);

        assertNotEq(poolRewards, epochPending);
        assertGt(poolRewards, epochPending);
        assertGt(poolRewards, vc.epochRewards(0));
    }

    function v1Lock() public {
        vm.startPrank(v1);

        assertNotEq(address(vc), address(0));
        l.approve(address(vc), 0);

        vm.expectEmit(address(vc));
        emit ValidatorContract.LicenseLocked(address(v1), 0);

        vc.lockLicense(0);
        vm.stopPrank();
    }

    function test_Lock() public {
        v1Lock();

        address newOwner = l.ownerOf(0);
        assertEq(newOwner, address(vc));

        uint256 locked = vc.getTotalLocked();
        assertEq(locked, 1);

        locked = vc.getValidatorLocked(v1);
        assertEq(locked, 1);

        skip(1 minutes);

        uint256 pending = vc.validatorPendingRewards(v1);
        console.log("pending v1: ", pending);
        assertNotEq(pending, 0);

        skip(1 minutes); 

        uint256 pendingNew = vc.validatorPendingRewards(v1);
        console.log("pending v1 new: ", pendingNew);
        assertNotEq(pendingNew, 0);
        assertGt(pendingNew, pending);
    }

    function testRevert_Unlock() public {
        v1Lock();

        vm.startPrank(v1);
        vm.expectRevert(UnlockCooldown.selector);
        vc.unlockLicense(0);

        vm.stopPrank();
    }

    function test_Unlock() public {
        v1Lock();
        
        uint256 epochDuration = vc.epochDuration();
        skip(epochDuration);

        vm.startPrank(v1);
        vm.expectEmit(address(vc));
        emit ValidatorContract.LicenseUnlocked(address(v1), 0);
        vc.unlockLicense(0);
        vm.stopPrank();
    }

    function test_Claim() public {
        v1Lock();
    }

}
