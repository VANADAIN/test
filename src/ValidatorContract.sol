// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NonZeroLib} from "./lib/NonZeroLib.sol";


/**
 * @title  Validator Contract
 * @notice Smart-contract for managing validator's licenses and rewards
 * @author Ivan M.
*/
contract ValidatorContract is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;


    //
    //    ERRORS
    // 

    error LicenseNotLocked(address user, uint256 tokenId);
    error DurationNotSet();
    error InvalidStart(uint256 start);
    error InvalidPercent(uint256 percent);
    error UnlockCooldown();


    //
    //    EVENTS
    // 

    event LicenseLocked(address from, uint256 licenseId);
    event LicenseUnlocked(address to, uint256 licenseId);

    event DecreasePercentSet(uint256 percent);
    event EpochDurationSet(uint256 duration);

    //
    //    CONSTANTS
    // 

    bytes32 public constant ADMIN  = keccak256("ADMIN");
    bytes32 public constant SETTER = keccak256("SETTER");


    /// @dev We want to have precision
    uint256 public constant MAX_PERCENT = 10_000;

    /// @dev keccak256(abi.encode(uint256(keccak256("Validators.storage.ValidatorContract.Main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x5381ff65829da98890ffb35a63efeb022dfb732b29445662c000933bcf078b00;


    //
    //    STORAGE
    //

    struct Lock {
        bool    locked;
        uint256 lockedAt;
    }

    struct TokenSet {
        uint256[] ids;
        mapping(uint256 tokenId => Lock) lock; 
    }

    struct ValidatorSet {
        address[] validators;
        TokenSet  licenseInfo;
    }


    struct Main {
        IERC20  rewardToken;
        IERC721 license;
        uint256 firstEpochReward;
        uint256 firstEpochStart;
        uint256 epochDuration;
        uint256 decreasePercent;
        uint256 totalRewardsGiven;
        mapping(uint256 epoch => uint256) rewardsGiven;
        mapping(address validator => ValidatorSet) validatorInfo;
    }


    //
    //    FUNCTIONS: Init
    // 

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _admin
    )
        initializer public
    {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(ADMIN, SETTER);

        _grantRole(ADMIN, _admin);

    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(ADMIN)
        override
    {}


    //
    //    FUNCTIONS: NON-View
    // 

    function lockLicense(
        uint256 tokenId
    ) external {
        Main storage $ = _getMainStorage();
        $.license.safeTransferFrom(msg.sender, address(this), tokenId);

        TokenSet storage set = $.validatorInfo[msg.sender].licenseInfo;

        set.ids.push(tokenId);
        set.lock[tokenId].locked = true;
        set.lock[tokenId].lockedAt = block.timestamp;

        emit LicenseLocked(msg.sender, tokenId);
    }


    function unlockLicense(
        uint256 tokenId
    ) external {
        Main storage $ = _getMainStorage();
        TokenSet storage set = $.validatorInfo[msg.sender].licenseInfo;

        if (!set.lock[tokenId].locked) {
            revert LicenseNotLocked(msg.sender, tokenId);
        }

        uint256 timePassed;
        uint256 lockedAt = set.lock[tokenId].lockedAt;
        if (block.timestamp > lockedAt) {
            timePassed = block.timestamp - lockedAt;
        } else {
            timePassed = 0;
        }

        if (timePassed < $.epochDuration) {
            revert UnlockCooldown();
        }

        // TODO: delete from token set


        $.license.transferFrom(address(this), msg.sender, tokenId);

        emit LicenseUnlocked(msg.sender, tokenId);
    }


    //
    //    FUNCTIONS: ADMIN & Roles
    // 

    function setRewardAndStart(
        uint256 _firstEpochReward,
        uint256 _start
    ) 
        external 
        onlyRole(SETTER) 
    {
        NonZeroLib._nonZeroV(_firstEpochReward);
        NonZeroLib._nonZeroV(_start);

        Main storage $ = _getMainStorage();
        // check duration is set to prevent instant unlock
        if ($.epochDuration == 0) {
            revert DurationNotSet();
        }

        if (_start < block.timestamp) {
            revert InvalidStart(_start);
        }

        $.firstEpochStart = block.timestamp;
        $.firstEpochReward = _firstEpochReward;
    }

    function setDecreasePercent(
        uint256 _decreasePercent
    ) external onlyRole(SETTER) {
        NonZeroLib._nonZeroV(_decreasePercent);

        Main storage $ = _getMainStorage();
        if (_decreasePercent > MAX_PERCENT) {
            revert InvalidPercent(_decreasePercent);
        }

        $.decreasePercent = _decreasePercent;

        emit DecreasePercentSet(_decreasePercent);
    }


    /**
     * @notice Set epoch duration
     * @param _epochDuration - new epoch duration
     */
    function setEpochDuration(
        uint256 _epochDuration
    ) external onlyRole(SETTER) {
        NonZeroLib._nonZeroV(_epochDuration);
        Main storage $ = _getMainStorage();
        $.epochDuration = _epochDuration;

        emit EpochDurationSet(_epochDuration);
    }


    //
    //    UTILS
    // 

    function _getMainStorage() private pure returns(Main storage $) {
        assembly {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }


    //
    //    FUNCTIONS: Rewards
    // 


    /**
     * @notice Calculate epoch rewards
     * @dev    Use exponential decay for each epoch 
     * @param  epoch - epoch number
     * @return reward of X epoch
     */
    function epochRewards(
        uint256 epoch
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 initial = $.firstEpochReward;

        if (epoch == 0) return initial;
        else
            return (initial * $.decreasePercent ** epoch) / (MAX_PERCENT ** epoch);
    }

    function nowEpoch() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 start = $.firstEpochStart;
        uint256 duration = $.epochDuration;
        if (start > block.timestamp) {
            return 0;
        } else {
            return (block.timestamp - start) / duration;
        }
    }

    function currentFullRewards() public view returns (uint256) {
        return epochRewards(nowEpoch());
    }

    function currentRewardPerSecond() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return currentFullRewards() / $.epochDuration;
    }


    function epochTimePassed() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 ce = nowEpoch();
        uint256 start = $.firstEpochStart + ce * $.epochDuration;

        return block.timestamp - start;
    }

    function pendingPoolRewards() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return currentRewardPerSecond() * epochTimePassed() - $.rewardsGiven[nowEpoch()];
    }
}
