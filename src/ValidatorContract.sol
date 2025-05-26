// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NonZeroLib} from "./lib/NonZeroLib.sol";

// import {console} from "forge-std/console.sol";

/**
 * @title  Validator Contract
 * @notice Smart-contract for managing validator's licenses and rewards
 * @author Ivan M.
 */
contract ValidatorContract is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    //
    //    ERRORS
    //

    error LicenseNotLocked(address user, uint256 tokenId);
    error InvalidPercent(uint256 percent);
    error InvalidStart(uint256 start);
    error DurationNotSet();
    error UnlockCooldown();
    error NoValidators();
    error AtTheEnd();

    //
    //    EVENTS
    //

    event LicenseLocked(address from, uint256 licenseId);
    event LicenseUnlocked(address to, uint256 licenseId);
    event Claimed(address user, uint256 amount);
    event DecreasePercentSet(uint256 percent);
    event EpochDurationSet(uint256 duration);
    event EpochEnded(uint256 epoch);

    //
    //    CONSTANTS
    //

    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant SETTER = keccak256("SETTER");

    /// @dev We want to have precision
    uint256 public constant MAX_PERCENT = 10_000;
    uint256 public constant SHARE_DENOM = 1e18;

    /// @dev keccak256(abi.encode(uint256(keccak256("Validators.storage.ValidatorContract.Main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x5381ff65829da98890ffb35a63efeb022dfb732b29445662c000933bcf078b00;

    //
    //    STORAGE
    //

    struct TokenSet {
        uint256[] ids;
        mapping(uint256 tokenId => uint256) lockedAt;
    }

    struct ValidatorSet {
        address[] validators;
        mapping(address => TokenSet) licenseInfo;
    }

    struct EpochData {
        uint256 firstEpochReward;
        uint256 firstEpochStart;
        uint256 epochDuration;
        uint256 lastEpochSeen;
    }

    struct EpochRewards {
        uint256 rewardsUsed;
        uint256 rewardsGiven;
    }

    struct Position {
        uint256 accumulated;
        uint256 rewardDebt;
    }

    struct RewardsData {
        uint256 RPS;
        uint256 totalLocked;
        uint256 totalRewardsGiven;
        mapping(uint256 epoch => EpochRewards) epochRewards;
        mapping(address validator => Position) position;
    }

    struct Main {
        IERC20  rewardToken;
        IERC721 license;
        uint256 decreasePercent;
        EpochData    epochData;
        RewardsData  rewardsData;
        ValidatorSet validatorInfo;
    }

    //
    //    FUNCTIONS: Init
    //

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _admin) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(ADMIN, SETTER);

        _grantRole(ADMIN, _admin);
        _grantRole(SETTER, _admin);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ADMIN) {}

    //
    //    FUNCTIONS: NON-View
    //

    /**
     * @notice Locks a license for validator
     * @param  tokenId - ID of the license
     */
    function lockLicense(uint256 tokenId) external {
        Main storage $ = _getMainStorage();
        $.license.transferFrom(msg.sender, address(this), tokenId);

        // update pool info 
        $.rewardsData.totalLocked += 1;

        // accumulate position rewards
        $.rewardsData.position[msg.sender].accumulated += validatorPendingRewardsRaw(msg.sender);

        if ($.validatorInfo.licenseInfo[msg.sender].ids.length == 0) {
            ValidatorSet storage vset = $.validatorInfo;
            vset.validators.push(msg.sender);
        }

        TokenSet storage tset = $.validatorInfo.licenseInfo[msg.sender];
        tset.ids.push(tokenId);
        tset.lockedAt[tokenId] = block.timestamp;

        // update RPS
        _updateRPS($);

        // update position
        _updatePosition(msg.sender);

        // update last seen epoch
        $.epochData.lastEpochSeen = nowEpoch();

        emit LicenseLocked(msg.sender, tokenId);
    }

    /**
     * @notice Unlocks a license for a validator
     * @param  tokenId - ID of the license
     */
    function unlockLicense(uint256 tokenId) external {
        Main storage $ = _getMainStorage();

        TokenSet storage set = $.validatorInfo.licenseInfo[msg.sender];
        uint256 lockedAt = set.lockedAt[tokenId];
        if (lockedAt == 0) revert LicenseNotLocked(msg.sender, tokenId);

        uint256 timePassed;
        if (block.timestamp > lockedAt) timePassed = block.timestamp - lockedAt;
        else timePassed = 0;

        if (timePassed < epochDuration()) revert UnlockCooldown();

        // update locks 
        set.lockedAt[tokenId] = 0;
        _removeFromTSet(msg.sender, tokenId);

        if (set.ids.length == 0) {
            _removeFromVSet(msg.sender);
        }

        _updateRPS($);

        // accumulate rewards
        Position storage position = $.rewardsData.position[msg.sender];
        position.accumulated += validatorPendingRewardsRaw(msg.sender);

        _updatePosition(msg.sender);

        $.rewardsData.totalLocked -= 1;
        $.epochData.lastEpochSeen = nowEpoch();

        $.license.transferFrom(address(this), msg.sender, tokenId);

        emit LicenseUnlocked(msg.sender, tokenId);
    }

    /**
     * @notice Claims pending rewards
     */
    function claim() external {
        Main storage $ = _getMainStorage();

        _updateRPS($);
        uint256 pending = validatorPendingRewardsRaw(msg.sender);
        
        if (pending > 0) {
            $.rewardToken.transfer(msg.sender, pending);
        }
        _updatePosition(msg.sender);

        $.rewardsData.position[msg.sender].accumulated = 0;
        $.rewardsData.epochRewards[nowEpoch()].rewardsGiven += pending;
        $.rewardsData.totalRewardsGiven += pending;

        emit Claimed(msg.sender, pending);
    }

    //
    //    FUNCTIONS: ADMIN & Roles
    //

    /**
     * @notice Ends the current epoch & distributes rewards
     * @dev    Caution! Gas-heavy
     */
    function endEpoch() external onlyRole(ADMIN) {
        Main storage $ = _getMainStorage();
        uint256 epoch = nowEpoch();
        uint256 timeLeft = epochTimeLeft(epoch);
        if (timeLeft == 0) {
            revert AtTheEnd();
        }

        // use timeframe shifting to update pending rewards
        $.epochData.firstEpochStart -= timeLeft - 1;

        // distribute rewards
        address[] memory validators = $.validatorInfo.validators;
        uint256 len = validators.length;
        if (len == 0) {
            revert NoValidators();
        }

        _updateRPS($);
        uint256 claimed;
        for (uint256 i = 0; i < len; i++) {
            uint256 pending = validatorPendingRewardsRaw(validators[i]);
            if (pending > 0) {
                $.rewardToken.transfer(validators[i], pending);
                _updatePosition(validators[i]);
                claimed += pending;
                emit Claimed(validators[i], pending);
            }
        }

        $.epochData.lastEpochSeen = epoch;
        $.rewardsData.epochRewards[nowEpoch()].rewardsGiven += claimed;
        $.rewardsData.totalRewardsGiven += claimed;

        emit EpochEnded(epoch);
    }

    /**
     * @notice Set first epoch reward
     * @param  _firstEpochReward - First epoch reward
     * @param  _start - First epoch start timestamp
     */
    function setRewardAndStart(
        uint256 _firstEpochReward,
        uint256 _start
    ) external onlyRole(SETTER) {
        NonZeroLib._nonZeroV(_firstEpochReward);
        NonZeroLib._nonZeroV(_start);

        Main storage $ = _getMainStorage();
        // check duration is already set to prevent instant unlock
        if (epochDuration() == 0) {
            revert DurationNotSet();
        }

        if (_start < block.timestamp) {
            revert InvalidStart(_start);
        }

        $.epochData.firstEpochStart = _start;
        $.epochData.firstEpochReward = _firstEpochReward;
    }

    /**
     * @notice Set decrease percent for each next epoch
     * @param _decreasePercent - new decrease percent from 1 to 10_000 
     */
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
        $.epochData.epochDuration = _epochDuration;

        emit EpochDurationSet(_epochDuration);
    }

    /**
     * @notice Set reward token
     * @dev    Reward token must be ERC20-compatible
     * @param  token - new reward token
     */
    function setRewardToken(
        address token
    ) external onlyRole(SETTER) {
        Main storage $ = _getMainStorage();
        $.rewardToken = IERC20(token);
    }

    /**
     * @notice Set license
     * @dev    License must be ERC721-compatible
     * @param  license - new license address
     */
    function setLicense(
        address license
    ) external onlyRole(SETTER) {
        Main storage $ = _getMainStorage();
        $.license = IERC721(license);
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
        uint256 initial = $.epochData.firstEpochReward;

        if (epoch == 0) return initial;
        else return (initial * (MAX_PERCENT - $.decreasePercent) ** epoch) / (MAX_PERCENT ** epoch);
    }

    /**
     * @notice Get current epoch
     * @return current epoch number
     */
    function nowEpoch() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 start = $.epochData.firstEpochStart;
        uint256 duration = epochDuration();
        if (start > block.timestamp) {
            return 0;
        } else {
            return (block.timestamp - start) / duration;
        }
    }

    /**
     * @notice Get epoch duration
     * @return epoch duration in seconds
     */
    function epochDuration() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return $.epochData.epochDuration;
    }

    /** 
     * @notice Get current full rewards per epoch
     * @return reward per second
     */
    function currentFullRewards() public view returns (uint256) {
        return epochRewards(nowEpoch());
    }

    /**
     * @notice Get current reward per second
     * @return reward per second
     */
    function currentRewardPerSecond() public view returns (uint256) {
        return rewardPerSecond(nowEpoch());
    }

    /** 
     * @notice Get epoch reward per second
     * @param  epoch - epoch number
     * @return pending rewards
     */
    function rewardPerSecond(
        uint256 epoch
    ) public view returns (uint256) {
        return epochRewards(epoch) / epochDuration();
    }

    /**
     * @notice Get time passed from start of current epoch
     * @return time passed in seconds
     */
    function currentEpochTimePassed() public view returns (uint256) {
        return epochTimePassed(nowEpoch());
    }

    /**
     * @notice Get time passed in epoch
     * @param  epoch - epoch number
     * @return time left in seconds
     */
    function epochTimePassed(
        uint256 epoch
    ) public view returns(uint256) {
        Main storage $ = _getMainStorage();

        uint256 duration = epochDuration();
        uint256 start = $.epochData.firstEpochStart + epoch * duration;
        if (block.timestamp > start + duration) {
            return duration;
        } else if (block.timestamp < start) {
            return 0;
        } else {
            return block.timestamp - start;
        }
    }

    /**
     * @notice Get time left in epoch
     * @param  epoch - epoch number
     * @return time left in seconds
     */
    function epochTimeLeft(
        uint256 epoch
    ) public view returns(uint256) {
        return epochDuration() - epochTimePassed(epoch);
    }

    /**
     * @notice Get pending epoch rewards
     * @param  epoch - epoch number
     * @return pending rewards
     */
    function pendingEpochRewards(
        uint256 epoch
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        EpochRewards storage rewardsData = $.rewardsData.epochRewards[epoch];

        uint256 time = epochTimePassed(epoch);
        if (time == 0) {
            return 0;
        } else {
            return rewardPerSecond(epoch) * epochTimePassed(epoch) - rewardsData.rewardsUsed;
        }
    }

    /**
     * @notice Get total pending rewards
     * @dev    Can be a sum of two or more epochs
     * @return total pending rewards
     */
    function pendingPoolRewards() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 lastSeen = $.epochData.lastEpochSeen;
        uint256 current = nowEpoch();

        uint256 totalPending;
        for (uint256 i = lastSeen; i <= current; i++) {
            totalPending += pendingEpochRewards(i);
        }

        return totalPending;
    }

    /**
     * @notice Get pending rewards for validator
     * @param  validator - address of validator
     * @return pending rewards
     */
    function validatorPendingRewards(
        address validator
    ) public view returns (uint256) {
        // show data as RPS change already applied
        Main storage $ = _getMainStorage();

        uint256 rewardPerShareChange = (pendingPoolRewards() * SHARE_DENOM) / $.rewardsData.totalLocked;
        uint256 newRPS = $.rewardsData.RPS;
        if (rewardPerShareChange > 0) {
            newRPS += rewardPerShareChange;
        }

        Position storage position = $.rewardsData.position[validator];
        uint256 raw = (getValidatorShare(validator) * newRPS) / (SHARE_DENOM * MAX_PERCENT);
        uint256 accumulatedReward = position.accumulated;

        if (raw <= position.rewardDebt) {
            return accumulatedReward;
        }
        return raw - position.rewardDebt + accumulatedReward;
    }

    function validatorPendingRewardsRaw(
        address validator
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        Position storage position = $.rewardsData.position[validator];
        uint256 accumulatedReward = position.accumulated;
        uint256 pendingRaw = _getPendingRaw(validator);

        if (pendingRaw <= position.rewardDebt) {
            return accumulatedReward;
        }

        return pendingRaw - position.rewardDebt + accumulatedReward;
    }

    /**
     * @notice Get validator locked licenses share
     * @param  validator - address of validator
     * @return validator share
     */
    function getValidatorShare(
        address validator
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 locked = $.validatorInfo.licenseInfo[validator].ids.length;
        return locked * MAX_PERCENT / $.rewardsData.totalLocked;
    }

    /**
     * @dev Get validator rewardDebt
     * @param  validator - address of validator
     * @return validator rewardDebt
     */
    function getRewardDebt(
        address validator
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return $.rewardsData.position[validator].rewardDebt;
    }

    function _getPendingRaw(
        address validator
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return (getValidatorShare(validator) * $.rewardsData.RPS) / (SHARE_DENOM * MAX_PERCENT);
    }

    /**
     * @dev Update personal position based on pool RPS
     */
    function _updatePosition(
        address validator
    ) private {
        Main storage $ = _getMainStorage();
        Position storage position = $.rewardsData.position[validator];
        position.rewardDebt = _getPendingRaw(validator);
    }

    /**
     * @dev Update RPS based on pending rewards
     */
    function _updateRPS(Main storage $) private {
        uint256 newTotalLock = $.rewardsData.totalLocked;
        uint256 pending = pendingPoolRewards();

        if (newTotalLock != 0) {
            uint256 rewardPerShareChange = (pending * SHARE_DENOM) / newTotalLock;
            if (rewardPerShareChange > 0) {
                $.rewardsData.RPS += rewardPerShareChange;

                // "flush" rewards
                EpochRewards storage rewardsData = $.rewardsData.epochRewards[nowEpoch()];
                rewardsData.rewardsUsed += pending;
            }
        }
    }

    //
    //    GETTERS
    //

    /**
     * @notice Get total locked licenses
     * @return total locked
     */
    function getTotalLocked() public view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.rewardsData.totalLocked;
    }

    /**
     * @notice Get number of validator locked licenses
     * @param  validator - address of validator
     * @return number of licenses locked
     */
    function getValidatorLocked(address validator) public view returns(uint256) {
        Main storage $ = _getMainStorage();
        TokenSet storage tset = $.validatorInfo.licenseInfo[validator];
        return tset.ids.length;
    }

    /**
     * @notice Get number of validators, who locked licenses
     * @return number of validators
     */
    function getValidatorCount() external view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.validatorInfo.validators.length;
    }

    /**
      * @dev Get rewards used for RPS calculation in epoch
      * @param  epoch - epoch
      * @return rewards used
      */
    function rewardsUsed(
        uint256 epoch
    ) external view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.rewardsData.epochRewards[epoch].rewardsUsed;
    }

    /**
      * @dev Get rewards claimed in epoch
      * @param  epoch - epoch
      * @return rewards given
      */
    function rewardsGiven(
        uint256 epoch
    ) external view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.rewardsData.epochRewards[epoch].rewardsGiven;
    }

    /**
      * @dev Get total rewards given
      * @return total rewards given
      */
    function totalRewardsGiven() external view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.rewardsData.totalRewardsGiven;
    }

    //
    //    UTILS
    //

    function _getMainStorage() private pure returns (Main storage $) {
        assembly {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    function _removeFromTSet(
        address validator,
        uint256 tokenId
    ) private {
        Main storage $ = _getMainStorage();
        TokenSet storage set = $.validatorInfo.licenseInfo[validator];
        uint256 len = set.ids.length;
        for (uint256 i = 0; i < len; i++) {
            if (set.ids[i] == tokenId) {
                set.ids[i] = set.ids[len - 1];
                set.ids.pop();
                break;
            }
        } 
    }

    function _removeFromVSet(
        address validator
    ) private {
        Main storage $ = _getMainStorage();
        ValidatorSet storage set = $.validatorInfo;
        uint256 len = set.validators.length;
        for (uint256 i = 0; i < len; i++) {
            if (set.validators[i] == validator) {
                set.validators[i] = set.validators[len - 1];
                set.validators.pop();
                break;
            }
        } 
    }
}
