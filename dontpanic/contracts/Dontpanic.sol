// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title enum ActivityStatus
 * @dev only for struct Activity
 * @notice start from 0
 */
enum ActivityStatus {
    Inactive,
    Active,
    Completed,
    Settled,
    Cancelled
}

/**
 * @dev struct for activity meta informations
 * @param id: activityId, derived from activity name hashed, id == zero means undefined activity
 * @param startTime: unix time for activity startTime
 * @param endTime: unix time for activity endTime
 * @param status: marked the status of activity
 * @param bitPool: total balance in this pool
 */
struct Activity {
    uint256 id;
    uint256 startTime;
    uint256 endTime;
    ActivityStatus status;
    uint256 bitPool;
}

/**
 * @title enum Opcode
 * @dev only for return code
 * @notice start from 0
 */
enum Opcode {
    CreateActivity,
    StartActivity,
    EndActivity,
    SettleActivity,
    RemoveActivity,
    JoinActivityUser,
    DepositActivityUser
}

/**
 * @title enum ErrorCode
 * @dev only for return code
 * @notice start from 0
 */
enum ErrorCode {
    Null,
    InvalidActivity,
    InvalidActivityId,
    InvalidActivityStatus,
    InvalidActivityTime,
    InvalidUser,
    InvalidScale,
    InvalidPayment
}

/**
 * @title Return Code
 * @dev for normal operations returned informations
 * @param op: enum for operations checkout
 * @param errorc: enum for errors checkout
 * @param status: is succeed, true for success, false for failure
 * @param desc: brief descriptions for this return
 */
struct ReturnCode {
    Opcode op;
    ErrorCode errorc;
    bool status;
    string desc;
}

/**
 * @title UserScale
 * @dev only used in settleActivity
 * @param userid: useraddress
 * @param scale: scale for users balance settlement
 */
struct UserScale {
    address userid;
    uint32 scale;
}

interface EnvManagement {
    function getUserActivityBalance(
        uint256 activityId,
        address userid
    ) external view returns (uint256);

    function getUserBalance(address userid) external view returns (uint256);

    function getActivityBalance(
        uint256 activityId
    ) external view returns (uint256);

    function getActivityStatus(
        uint256 activityId
    ) external view returns (ActivityStatus);

    function getActivityEndTime(
        uint256 activityId
    ) external view returns (uint256);

    function getActivityStartTime(
        uint256 activityId
    ) external view returns (uint256);

    function getContractBalance() external view returns (uint256);
}

// public operations
interface NormalOp {
    /**
     * @dev user join a valid activity
     * @param activityId: activityId hashed with name
     */
    function joinActivityUser(
        uint256 activityId
    ) external payable returns (ReturnCode memory);

    /**
     * @dev user deposit balance from contract
     * @param amount: deposited total count
     */
    function depositActivityUser(
        uint256 amount
    ) external returns (ReturnCode memory);
}

// must add ownable modifier
// supervisor operations
interface OwnerOp {
    /**
     * @dev create a new activity, when using it, make sure that activityId is not conflicted
     * @param activityId: specific marked id for activity
     * @param starttime: unix time unit
     * @param durations: unix time unit
     */
    function createActivity(
        uint256 activityId,
        uint256 starttime,
        uint256 durations
    ) external returns (ReturnCode memory);

    function startActivity(
        uint256 activityId
    ) external returns (ReturnCode memory);

    /**
     * @dev end an activated activity
     * @param activityId: specific marked id for activity
     */
    function endActivity(
        uint256 activityId
    ) external returns (ReturnCode memory);

    /**
     * @dev settle an activated activity
     * @param activityId: specific marked id for activity
     */
    function settleActivity(
        uint256 activityId,
        UserScale[] calldata scaleOfUsers
    ) external returns (ReturnCode memory);

    // warning: this function will delete activity no matter what status it has,
    // literally only for test.
    function removeActivity(
        uint256 activityId,
        UserScale[] calldata scaleOfUsers
    ) external returns (ReturnCode memory);
}

contract Dontpanic is Ownable, Pausable, OwnerOp, NormalOp, EnvManagement {
    // Events
    event ActivityCreated(
        uint256 indexed activityId,
        uint256 startTime,
        uint256 endTime
    );
    event ActivityStarted(uint256 indexed activityId);
    event ActivityEnded(uint256 indexed activityId);
    event ActivitySettled(uint256 indexed activityId, uint256 totalDistributed);
    event ActivityRemoved(uint256 indexed activityId);
    event UserJoinedActivity(
        uint256 indexed activityId,
        address indexed user,
        uint256 amount
    );
    event UserWithdrawn(address indexed user, uint256 amount);

    // basic constructor
    constructor(address initialOwner) Ownable(initialOwner) {}

    // variables for services

    // activity
    // list for on-chain activity
    mapping(uint256 => Activity) public activityList;

    // users
    // (cannot withdraw) userActivityBalance[activityId][userId]
    mapping(uint256 => mapping(address => uint256)) public userActivityBalance;
    // (can withdraw) user's total Balance userBalance[userId]
    mapping(address => uint256) public userBalance;

    // utils
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _initActivityStatus(
        uint256 starttime,
        uint256 durations
    ) internal view returns (ActivityStatus) {
        uint256 nowTime = block.timestamp;
        if (starttime > nowTime) {
            return ActivityStatus.Inactive;
        } else if (starttime + durations <= nowTime) {
            return ActivityStatus.Cancelled;
        }
        return ActivityStatus.Active;
    }

    function _activityStatusToString(
        ActivityStatus act
    ) internal pure returns (string memory) {
        if (act == ActivityStatus.Inactive) {
            return "Inactive";
        } else if (act == ActivityStatus.Active) {
            return "Active";
        } else if (act == ActivityStatus.Completed) {
            return "Completed";
        } else if (act == ActivityStatus.Settled) {
            return "Settled";
        } else {
            return "Cancelled";
        }
    }

    function _settleBalanceForEveryone(
        uint256 activityId,
        UserScale[] calldata scaleOfUsers,
        uint32 totalScale
    ) internal {
        Activity memory act = activityList[activityId];
        uint256 totalBalance = act.bitPool;
        for (uint i = 0; i < scaleOfUsers.length; ++i) {
            address userid = scaleOfUsers[i].userid;
            uint32 scale = scaleOfUsers[i].scale;
            userActivityBalance[activityId][userid] = 0;

            uint256 benefit = (totalBalance * scale) / totalScale;
            userBalance[userid] += benefit;
        }
        activityList[activityId].bitPool = 0;
    }

    // OwnerOp
    function createActivity(
        uint256 activityId,
        uint256 starttime,
        uint256 durations
    ) external onlyOwner returns (ReturnCode memory) {
        // if found one exists
        // return InvalidActivityId
        if (activityList[activityId].id != 0) {
            return
                ReturnCode({
                    op: Opcode.CreateActivity,
                    errorc: ErrorCode.InvalidActivityId,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "activityId ",
                            _toString(activityId),
                            " already exists"
                        )
                    )
                });
        }

        ActivityStatus statusNow = _initActivityStatus(starttime, durations);

        Activity memory act = Activity({
            id: activityId,
            startTime: starttime,
            endTime: starttime + durations,
            status: statusNow,
            bitPool: 0
        });

        activityList[activityId] = act;
        emit ActivityCreated(activityId, starttime, starttime + durations);
        return
            ReturnCode({
                op: Opcode.CreateActivity,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in CreateActivity"
            });
    }

    function startActivity(
        uint256 activityId
    ) external onlyOwner returns (ReturnCode memory) {
        if (activityList[activityId].id == 0) {
            return
                ReturnCode({
                    op: Opcode.StartActivity,
                    errorc: ErrorCode.InvalidActivityId,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "activityId ",
                            _toString(activityId),
                            " not exist"
                        )
                    )
                });
        }

        Activity memory act = activityList[activityId];
        ActivityStatus actStatus = act.status;
        uint256 nowTime = block.timestamp;
        uint256 starttime = act.startTime;
        if (actStatus != ActivityStatus.Inactive) {
            return
                ReturnCode({
                    op: Opcode.StartActivity,
                    errorc: ErrorCode.InvalidActivityStatus,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "Wrong activity status, expect: Inactive, actual: ",
                            _activityStatusToString(actStatus)
                        )
                    )
                });
        }

        if (starttime > nowTime) {
            return
                ReturnCode({
                    op: Opcode.StartActivity,
                    errorc: ErrorCode.InvalidActivityTime,
                    status: false,
                    desc: "Activity still pending"
                });
        }

        activityList[activityId].status = ActivityStatus.Active;
        emit ActivityStarted(activityId);
        return
            ReturnCode({
                op: Opcode.StartActivity,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in StartActivity"
            });
    }

    function endActivity(
        uint256 activityId
    ) external onlyOwner returns (ReturnCode memory) {
        if (activityList[activityId].id == 0) {
            return
                ReturnCode({
                    op: Opcode.EndActivity,
                    errorc: ErrorCode.InvalidActivityId,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "activityId ",
                            _toString(activityId),
                            " not exist"
                        )
                    )
                });
        }

        Activity memory act = activityList[activityId];
        ActivityStatus actStatus = act.status;
        uint256 nowTime = block.timestamp;
        uint256 endtime = act.endTime;
        if (actStatus != ActivityStatus.Active) {
            return
                ReturnCode({
                    op: Opcode.EndActivity,
                    errorc: ErrorCode.InvalidActivityStatus,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "Wrong activity status, expect: Active, actual: ",
                            _activityStatusToString(actStatus)
                        )
                    )
                });
        }

        if (endtime > nowTime) {
            return
                ReturnCode({
                    op: Opcode.EndActivity,
                    errorc: ErrorCode.InvalidActivityTime,
                    status: false,
                    desc: "Activity end time not reached yet"
                });
        }

        activityList[activityId].status = ActivityStatus.Completed;
        emit ActivityEnded(activityId);
        return
            ReturnCode({
                op: Opcode.EndActivity,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in EndActivity"
            });
    }

    function settleActivity(
        uint256 activityId,
        UserScale[] calldata scaleOfUsers
    ) external onlyOwner returns (ReturnCode memory) {
        if (activityList[activityId].id == 0) {
            return
                ReturnCode({
                    op: Opcode.SettleActivity,
                    errorc: ErrorCode.InvalidActivityId,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "activityId ",
                            _toString(activityId),
                            " not exist"
                        )
                    )
                });
        }
        Activity memory act = activityList[activityId];
        ActivityStatus actStatus = act.status;

        if (actStatus != ActivityStatus.Completed) {
            return
                ReturnCode({
                    op: Opcode.SettleActivity,
                    errorc: ErrorCode.InvalidActivityStatus,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "Wrong activity status, expect: Complete, actual: ",
                            _activityStatusToString(actStatus)
                        )
                    )
                });
        }

        uint32 totalScale;
        for (uint i = 0; i < scaleOfUsers.length; i++) {
            totalScale += scaleOfUsers[i].scale;
            if (userActivityBalance[activityId][scaleOfUsers[i].userid] == 0) {
                return
                    ReturnCode({
                        op: Opcode.SettleActivity,
                        errorc: ErrorCode.InvalidUser,
                        status: false,
                        desc: Strings.toHexString(scaleOfUsers[i].userid)
                    });
            }
        }

        if (totalScale <= 0) {
            return
                ReturnCode({
                    op: Opcode.SettleActivity,
                    errorc: ErrorCode.InvalidScale,
                    status: false,
                    desc: "Total scale must be positive"
                });
        }

        uint256 totalDistributed = act.bitPool;
        _settleBalanceForEveryone(activityId, scaleOfUsers, totalScale);

        activityList[activityId].status = ActivityStatus.Settled;
        emit ActivitySettled(activityId, totalDistributed);

        return
            ReturnCode({
                op: Opcode.SettleActivity,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in SettleActivity"
            });
    }

    function removeActivity(
        uint256 activityId,
        UserScale[] calldata scaleOfUsers
    ) external onlyOwner returns (ReturnCode memory) {
        if (activityList[activityId].id == 0) {
            return
                ReturnCode({
                    op: Opcode.RemoveActivity,
                    errorc: ErrorCode.InvalidActivityId,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "activityId ",
                            _toString(activityId),
                            " not exist"
                        )
                    )
                });
        }

        Activity memory act = activityList[activityId];
        ActivityStatus actStatus = act.status;

        if (actStatus < ActivityStatus.Settled) {
            uint32 totalScale;
            for (uint i = 0; i < scaleOfUsers.length; i++) {
                totalScale += scaleOfUsers[i].scale;
                if (
                    userActivityBalance[activityId][scaleOfUsers[i].userid] == 0
                ) {
                    return
                        ReturnCode({
                            op: Opcode.RemoveActivity,
                            errorc: ErrorCode.InvalidUser,
                            status: false,
                            desc: Strings.toHexString(scaleOfUsers[i].userid)
                        });
                }
            }
            _settleBalanceForEveryone(activityId, scaleOfUsers, totalScale);
        }

        activityList[activityId].status = ActivityStatus.Cancelled;
        emit ActivityRemoved(activityId);

        return
            ReturnCode({
                op: Opcode.RemoveActivity,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in RemoveActivity"
            });
    }

    function joinActivityUser(
        uint256 activityId
    ) external payable whenNotPaused returns (ReturnCode memory) {
        uint256 amountPaid = msg.value;
        address paidAccount = msg.sender;
        if (amountPaid <= 0) {
            return
                ReturnCode({
                    op: Opcode.JoinActivityUser,
                    errorc: ErrorCode.InvalidPayment,
                    status: false,
                    desc: "Expect value > 0, Received value <= 0"
                });
        }

        if (activityList[activityId].id == 0) {
            return
                ReturnCode({
                    op: Opcode.JoinActivityUser,
                    errorc: ErrorCode.InvalidActivityId,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "activityId ",
                            _toString(activityId),
                            " not exist"
                        )
                    )
                });
        }

        if (activityList[activityId].status != ActivityStatus.Active) {
            return
                ReturnCode({
                    op: Opcode.JoinActivityUser,
                    errorc: ErrorCode.InvalidActivityStatus,
                    status: false,
                    desc: string(
                        abi.encodePacked(
                            "Activity not active, status: ",
                            _activityStatusToString(
                                activityList[activityId].status
                            )
                        )
                    )
                });
        }

        userActivityBalance[activityId][paidAccount] += amountPaid;
        activityList[activityId].bitPool += amountPaid;
        emit UserJoinedActivity(activityId, paidAccount, amountPaid);
        return
            ReturnCode({
                op: Opcode.JoinActivityUser,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in joinActivityUser"
            });
    }

    function depositActivityUser(
        uint256 amount
    ) external whenNotPaused returns (ReturnCode memory) {
        if (address(this).balance <= amount) {
            return
                ReturnCode({
                    op: Opcode.DepositActivityUser,
                    errorc: ErrorCode.InvalidPayment,
                    status: false,
                    desc: "Insufficient contract balance"
                });
        }

        if (userBalance[msg.sender] < amount) {
            return
                ReturnCode({
                    op: Opcode.DepositActivityUser,
                    errorc: ErrorCode.InvalidPayment,
                    status: false,
                    desc: "Insufficient user balance"
                });
        }

        userBalance[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit UserWithdrawn(msg.sender, amount);

        return
            ReturnCode({
                op: Opcode.DepositActivityUser,
                errorc: ErrorCode.Null,
                status: true,
                desc: "Succeed in DepositActivityUser"
            });
    }

    // Env Management
    function getUserActivityBalance(
        uint256 activityId,
        address userid
    ) external view returns (uint256) {
        return userActivityBalance[activityId][userid];
    }

    function getUserBalance(address userid) external view returns (uint256) {
        return userBalance[userid];
    }

    function getActivityBalance(
        uint256 activityId
    ) external view returns (uint256) {
        return activityList[activityId].bitPool;
    }

    function getActivityStatus(
        uint256 activityId
    ) external view returns (ActivityStatus) {
        return activityList[activityId].status;
    }

    function getActivityEndTime(
        uint256 activityId
    ) external view returns (uint256) {
        return activityList[activityId].endTime;
    }

    function getActivityStartTime(
        uint256 activityId
    ) external view returns (uint256) {
        return activityList[activityId].startTime;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // fallback
    receive() external payable {
        revert("Direct ETH send not allowed");
    }
}
