// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ValidatorContract} from "../src/ValidatorContract.sol";
import {RewardToken} from "../src/RewardToken.sol";
import {License} from "../src/License.sol";

contract ValidatorContractTest is Test {
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

    function test_Increment() public {
    }
}
