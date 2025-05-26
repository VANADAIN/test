// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NonZeroLib} from "./lib/NonZeroLib.sol";

import {console} from "forge-std/console.sol";

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

    event Claimed(address user, uint256 amount);

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
        uint256 totalRewardsUsed;
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

    function lockLicense(uint256 tokenId) external {
        Main storage $ = _getMainStorage();
        $.license.transferFrom(msg.sender, address(this), tokenId);

        // update pool info 
        $.rewardsData.totalLocked += 1;

        // accumulate position rewards
        Position storage position = $.rewardsData.position[msg.sender];
        position.accumulated += validatorPendingRewardsRaw(msg.sender);


        // if validator is not in set -> add 
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

    function unlockLicense(uint256 tokenId) external {
        Main storage $ = _getMainStorage();
        TokenSet storage set = $.validatorInfo.licenseInfo[msg.sender];

        uint256 lockedAt = set.lockedAt[tokenId];
        if (lockedAt == 0) {
            revert LicenseNotLocked(msg.sender, tokenId);
        }

        uint256 timePassed;
        if (block.timestamp > lockedAt) {
            timePassed = block.timestamp - lockedAt;
        } else {
            timePassed = 0;
        }

        if (timePassed < $.epochData.epochDuration) {
            revert UnlockCooldown();
        }

        // update locks 
        set.lockedAt[tokenId] = 0;
        _removeFromTSet(set, tokenId);

        if (set.ids.length == 0) {
            ValidatorSet storage vset = $.validatorInfo;
            _removeFromVSet(vset, msg.sender);
        }

        // accumulate rewards
        Position storage position = $.rewardsData.position[msg.sender];
        position.accumulated += validatorPendingRewardsRaw(msg.sender);

        // update RPS
        _updateRPS($);

        // update position
        _updatePosition(msg.sender);

        // update pool info
        $.rewardsData.totalLocked -= 1;

        $.license.transferFrom(address(this), msg.sender, tokenId);

        emit LicenseUnlocked(msg.sender, tokenId);
    }

    function claim() external {
        Main storage $ = _getMainStorage();

        //console.log("");
        //console.log("CLAIM BEGIN");
        
        _updateRPS($);
        uint256 pending = validatorPendingRewardsRaw(msg.sender);
        
        //console.log("TO CLAIM:", pending);

        if (pending > 0) {
            $.rewardToken.transfer(msg.sender, pending);
        }
        _updatePosition(msg.sender);

        emit Claimed(msg.sender, pending);
    }

    //
    //    FUNCTIONS: ADMIN & Roles
    //

    function setRewardAndStart(
        uint256 _firstEpochReward,
        uint256 _start
    ) external onlyRole(SETTER) {
        NonZeroLib._nonZeroV(_firstEpochReward);
        NonZeroLib._nonZeroV(_start);

        Main storage $ = _getMainStorage();
        // check duration is already set to prevent instant unlock
        if ($.epochData.epochDuration == 0) {
            revert DurationNotSet();
        }

        if (_start < block.timestamp) {
            revert InvalidStart(_start);
        }

        $.epochData.firstEpochStart = block.timestamp;
        $.epochData.firstEpochReward = _firstEpochReward;
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
        $.epochData.epochDuration = _epochDuration;

        emit EpochDurationSet(_epochDuration);
    }

    function setRewardToken(
        address token
    ) external onlyRole(SETTER) {
        Main storage $ = _getMainStorage();
        $.rewardToken = IERC20(token);
    }

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

    function nowEpoch() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 start = $.epochData.firstEpochStart;
        uint256 duration = $.epochData.epochDuration;
        if (start > block.timestamp) {
            return 0;
        } else {
            return (block.timestamp - start) / duration;
        }
    }

    function epochDuration() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return $.epochData.epochDuration;
    }

    function currentFullRewards() public view returns (uint256) {
        return epochRewards(nowEpoch());
    }

    function currentRewardPerSecond() public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return rewardPerSecond(nowEpoch());
    }

    function rewardPerSecond(
        uint256 epoch
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        return epochRewards(epoch) / $.epochData.epochDuration;
    }

    function currentEpochTimePassed() public view returns (uint256) {
        uint256 ce = nowEpoch();
        return epochTimePassed(ce);
    }

    function epochTimePassed(
        uint256 epoch
    ) public view returns(uint256) {
        Main storage $ = _getMainStorage();

        uint256 start = $.epochData.firstEpochStart + epoch * $.epochData.epochDuration;
        if (block.timestamp > start + $.epochData.epochDuration) {
            return $.epochData.epochDuration;
        } else if (block.timestamp < start) {
            return 0;
        } else {
            return block.timestamp - start;
        }
    }

    function pendingEpochRewards(
        uint256 epoch
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        EpochRewards storage rewardsData = $.rewardsData.epochRewards[epoch];
        return rewardPerSecond(epoch) * epochTimePassed(epoch) - rewardsData.rewardsUsed;
    }

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

    function validatorPendingRewards(
        address validator
    ) public view returns (uint256) {
        // show data as RPS change already applied
        Main storage $ = _getMainStorage();

        uint256 totalLock = $.rewardsData.totalLocked;
        uint256 pending = pendingPoolRewards();
        uint256 rewardPerShareChange = (pending * SHARE_DENOM) / totalLock;

        console.log("");
        console.log("DEBUG");
        console.log("RPS: ", $.rewardsData.RPS);
        console.log("pending: ", pending);
        console.log("RPS change: ", rewardPerShareChange);

        uint256 newRPS = $.rewardsData.RPS;
        if (rewardPerShareChange > 0) {
            newRPS += rewardPerShareChange;
        }

        Position storage position = $.rewardsData.position[validator];
        uint256 raw = (getValidatorShare(validator) * newRPS) / (SHARE_DENOM * MAX_PERCENT);
        
        console.log("raw: ", raw);

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

        //console.log("Pend RAW internal:", pendingRaw);

        if (pendingRaw <= position.rewardDebt) {
            return accumulatedReward;
        }

        //console.log("Accumulated:", accumulatedReward);

        return pendingRaw - position.rewardDebt + accumulatedReward;
    }

    function getValidatorShare(
        address validator
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        uint256 locked = $.validatorInfo.licenseInfo[validator].ids.length;
        return locked * MAX_PERCENT / $.rewardsData.totalLocked;
    }

    function getRewardDebt(
        address validator
    ) external view returns (uint256) {
        Main storage $ = _getMainStorage();
        Position storage position = $.rewardsData.position[validator];
        return position.rewardDebt;
    }

    function _getPendingRaw(
        address validator
    ) public view returns (uint256) {
        Main storage $ = _getMainStorage();
        
        //console.log("RPS", $.rewardsData.RPS);
        //console.log("Share", getValidatorShare(validator));

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


    function _updateRPS(Main storage $) private {
        uint256 newTotalLock = $.rewardsData.totalLocked;
        uint256 pending = pendingPoolRewards();

        //console.log("RPS");

        if (newTotalLock != 0) {
            uint256 rewardPerShareChange = (pending * SHARE_DENOM) / newTotalLock;
            if (rewardPerShareChange > 0) {
                //console.log("total lock: ", newTotalLock);
                //console.log("pending: ", pending);
                //console.log("_update RPS: ", $.rewardsData.RPS);
                //console.log("_update RPS change: ", rewardPerShareChange);
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

    function getTotalLocked() public view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.rewardsData.totalLocked;
    }

    function getValidatorLocked(address validator) public view returns(uint256) {
        Main storage $ = _getMainStorage();
        TokenSet storage tset = $.validatorInfo.licenseInfo[validator];
        return tset.ids.length;
    }

    function getValidatorCount() external view returns(uint256) {
        Main storage $ = _getMainStorage();
        return $.validatorInfo.validators.length;
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
        TokenSet storage set,
        uint256 tokenId
    ) private {
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
        ValidatorSet storage set,
        address validator
    ) private {
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
