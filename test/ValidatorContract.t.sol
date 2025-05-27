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
        rt = new RewardToken(address(this), address(this));
        l = new License(address(this));
        
        ValidatorContract impl = new ValidatorContract();
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
        vc.setRewardAndStart(10_000 * 1e18, block.timestamp + 10_000);
        skip(10_000);


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

    function vxLock(address who, uint256 token) public {
        vm.startPrank(who);

        assertNotEq(address(vc), address(0));
        l.approve(address(vc), token);

        vm.expectEmit(address(vc));
        emit ValidatorContract.LicenseLocked(address(who), token);

        vc.lockLicense(token);
        vm.stopPrank();
    }

    function test_rewardsActive() public {
        // wait 1 minute and check rewards
        skip(1 minutes);

        uint256 epoch = vc.nowEpoch();
        uint256 epochRewards = vc.epochRewards(epoch);
        console.log("0 epoch rewards: ", epochRewards);

        assertEq(epoch, 0);
        assertEq(epochRewards, 10_000 * 1e18);

        epochRewards = vc.epochRewards(epoch + 1);
        console.log("1 epoch rewards: ", epochRewards);
        assertEq(epochRewards, 9_000 * 1e18);

        epochRewards = vc.currentFullRewards();
        assertEq(epochRewards, 10_000 * 1e18);

        uint256 expected = epochRewards / vc.epochDuration();
        epochRewards = vc.currentRewardPerSecond();
        console.log("epoch rewards per second: ", epochRewards);
        assertEq(epochRewards, expected);

        uint256 timeP = vc.currentEpochTimePassed();
        assertEq(timeP, 60);
        console.log("time passed in 0 epoch: ", timeP);

        timeP = vc.epochTimePassed(epoch + 1);
        console.log("time passed in 1 epoch: ", timeP);
        assertEq(timeP, 0);

        epochRewards = vc.pendingEpochRewards(epoch);
        expected = (10_000 * 1e18);
        expected = expected / 60;
        /// !!! division rounding
        assertApproxEqRel(epochRewards, expected, 1000);
        assertNotEq(epochRewards, 0);

        epochRewards = vc.pendingPoolRewards();
        console.log("pool rewards pending: ", epochRewards);
        assertEq(epochRewards, vc.pendingEpochRewards(epoch));

        epochRewards = vc.pendingEpochRewards(epoch + 1);
        assertEq(epochRewards, 0);

        skip(1 hours + 1 minutes);

        // pool now != epoch, bcz 2 epochs
        uint256 epochPending = vc.pendingEpochRewards(epoch + 1);
        uint256 poolRewards = vc.pendingPoolRewards();
        console.log("skip epoch");
        console.log("pool rewards pending: ", poolRewards);

        assertNotEq(poolRewards, epochPending);
        assertGt(poolRewards, epochPending);
        assertGt(poolRewards, vc.epochRewards(0));
    }

    function test_Lock() public {
        vxLock(v1, 0);

        address newOwner = l.ownerOf(0);
        assertEq(newOwner, address(vc));

        uint256 locked = vc.getTotalLocked();
        assertEq(locked, 1);

        locked = vc.getValidatorLocked(v1);
        assertEq(locked, 1);

        uint256 validators = vc.getValidatorCount();
        assertEq(validators, 1);

        skip(1 minutes);

        uint256 pending = vc.validatorPendingRewards(v1);
        assertNotEq(pending, 0);

        skip(1 minutes); 

        uint256 pendingNew = vc.validatorPendingRewards(v1);
        assertNotEq(pendingNew, 0);
        assertGt(pendingNew, pending);
    }

    function testRevert_Unlock() public {
        vxLock(v1, 0);

        vm.startPrank(v1);
        vm.expectRevert(UnlockCooldown.selector);
        vc.unlockLicense(0);

        vm.stopPrank();
    }

    function test_Unlock() public {
        vxLock(v1, 0);
        
        uint256 epochDuration = vc.epochDuration();
        skip(epochDuration);

        vm.startPrank(v1);
        vm.expectEmit(address(vc));
        emit ValidatorContract.LicenseUnlocked(address(v1), 0);
        vc.unlockLicense(0);
        vm.stopPrank();

        uint256 locked = vc.getTotalLocked();
        assertEq(locked, 0);

        locked = vc.getValidatorLocked(v1);
        assertEq(locked, 0);

        uint256 validators = vc.getValidatorCount();
        assertEq(validators, 0);
    }

    function test_Claim() public {
        vxLock(v1, 0);

        skip(30 minutes);

        uint256 pending = vc.validatorPendingRewards(v1);
        console.log("pending before claim: ", pending);
        assertNotEq(pending, 0);

        vm.startPrank(v1);

        uint256 balance = rt.balanceOf(v1);
        console.log("balance before claim: ", balance);
        assertEq(balance, 0);

        vm.expectEmit(address(vc));
        emit ValidatorContract.Claimed(address(v1), pending);
        vc.claim();
        vm.stopPrank();

        balance = rt.balanceOf(v1);
        console.log("balance after claim: ", balance);
        assertEq(balance, pending);

        uint256 given = vc.rewardsGiven(vc.nowEpoch());
        uint256 totalGiven = vc.totalRewardsGiven();
        assertNotEq(given, 0);
        assertNotEq(totalGiven, 0);
        assertEq(given, pending);
        assertEq(totalGiven, given);

        // rewards to zero after claim (discrete) 
        pending = vc.validatorPendingRewards(v1);
        console.log("pending after claim: ", pending);
        assertEq(pending, 0);
    }

    function test_LockTwoUsers() public {
        vxLock(v1, 0);
        skip(30 minutes);

        vxLock(v2, 3);

        uint256 pendingV2 = vc.validatorPendingRewards(v2);
        console.log("pendingV2: ", pendingV2);
        assertEq(pendingV2, 0);

        skip(5 minutes);

        uint256 pendingV1 = vc.validatorPendingRewards(v1);
        console.log("pending V1 35 mins: ", pendingV1);
        assertNotEq(pendingV1, 0);

        pendingV2 = vc.validatorPendingRewards(v2);
        console.log("pendingV2 5 min: ", pendingV2);
        assertNotEq(pendingV2, 0);

        // same share but v2 locked later
        assertGt(pendingV1, pendingV2);

        // claim does not affect second user
        vm.prank(v1);
        vc.claim();

        uint256 balance = rt.balanceOf(v1);
        assertEq(balance, pendingV1);

        uint256 pendingV1new = vc.validatorPendingRewards(v1);
        assertEq(pendingV1new, 0);

        // does not affect second user
        uint256 pendingV2new = vc.validatorPendingRewards(v2);
        assertNotEq(pendingV2new, 0);
        assertEq(pendingV2, pendingV2new);
    }

    function test_endEpoch() public {
        vxLock(v1, 0);
        vxLock(v2, 3);
        skip(30 minutes);

        uint256 pendingV1 = vc.validatorPendingRewards(v1);
        uint256 pendingV2 = vc.validatorPendingRewards(v2);
        assertNotEq(pendingV1, 0);
        assertNotEq(pendingV2, 0);

        uint256 epoch = vc.nowEpoch();
        vm.expectEmit(address(vc));
        emit ValidatorContract.EpochEnded(epoch);
        vc.endEpoch();

        assertEq(vc.nowEpoch(), epoch);
        assertEq(vc.epochTimePassed(epoch + 1), 0);

        uint256 pendingV1new = vc.validatorPendingRewards(v1);
        uint256 pendingV2new = vc.validatorPendingRewards(v2);

        assertEq(pendingV1new, 0);
        assertEq(pendingV2new, 0);

        assertApproxEqRel(rt.balanceOf(v1), 5_000 * 1e18, 1 * 1e18);
        assertApproxEqRel(rt.balanceOf(v2), 5_000 * 1e18, 1 * 1e18);
    }

    function test_rewardsAccumulate() public {
        vxLock(v1, 0);
        skip(30 minutes);
        
        uint256 pendingBefore = vc.validatorPendingRewards(v1);
        assertNotEq(pendingBefore, 0);
        console.log("pendingBefore", pendingBefore);

        vxLock(v1, 1);

        uint256 pendingAfter = vc.validatorPendingRewards(v1);
        console.log("pendingAfter", pendingAfter);

        assertNotEq(pendingAfter, 0);
        assertEq(pendingAfter, pendingBefore);

        skip(5 minutes);
        uint256 pendingAfterSkip = vc.validatorPendingRewards(v1);
        console.log("pendingAfterSkip", pendingAfterSkip);
        assertNotEq(pendingAfterSkip, 0);
        assertNotEq(pendingAfterSkip, pendingAfter);
        assertGt(pendingAfterSkip, pendingAfter);

        vxLock(v1, 2);
        pendingAfter = vc.validatorPendingRewards(v1);
        console.log("pendingAfter all stakes", pendingAfter);
        assertEq(pendingAfter, pendingAfterSkip);

        skip(5 minutes);
        pendingAfterSkip = vc.validatorPendingRewards(v1);
        console.log("pendingAfterSkip and all stakes", pendingAfterSkip);
        assertNotEq(pendingAfterSkip, 0);
        assertGt(pendingAfterSkip, pendingAfter);
    }
}
