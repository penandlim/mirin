// SPDX-License-Identifier: MIT

pragma solidity =0.8.2;

import "./MirinHelpers.sol";
import "./interfaces/IMasterChefV2.sol";

contract MirinYieldRebalancer is MirinHelpers {
    struct Checkpoint {
        uint128 fromBlock;
        uint128 value;
    }

    struct Reward {
        uint128 block;
        uint128 amount;
        uint256 lpTotal;
    }

    uint256 internal constant FACTOR_BASE = 1e10;

    IMasterChefV2 public immutable masterChef;
    IERC20 public immutable sushi;

    uint256 public lastSushiBalance;
    mapping(uint256 => Reward[]) public rewards;
    mapping(uint256 => mapping(address => uint256)) public lastRewardReceived;

    mapping(uint256 => Checkpoint[]) private _poolFactors;
    mapping(uint256 => mapping(address => Checkpoint[])) private _lpBalances;

    event Deposit(uint256 indexed pid, uint256 amount, address indexed owner);
    event Withdraw(uint256 indexed pid, uint256 amount, address indexed owner);
    event ClaimReward(uint256 indexed pid, uint256 amount, address indexed owner);
    event Rebalance(uint256 indexed fromPid, uint256 fromAmount, uint256 indexed toPid, uint256 toAmount);

    modifier onlyWETHPool(uint256 pid) {
        IMirinPool pool = IMirinPool(masterChef.lpToken(pid));
        (address token0, address token1) = (pool.token0(), pool.token1());
        require(token0 == weth || token1 == weth, "MIRIN: INVALID_POOL");
        _;
    }

    constructor(
        IMasterChefV2 _masterChef,
        IERC20 _sushi,
        address _factory,
        address _legacyFactory,
        address _weth
    ) MirinHelpers(_factory, _legacyFactory, _weth) {
        masterChef = _masterChef;
        sushi = _sushi;
    }

    function pendingSushi(uint256 pid, address owner) external view returns (uint256 amount) {
        for (uint256 i = lastRewardReceived[pid][owner]; i < rewards[pid].length; i++) {
            Reward storage reward = rewards[pid][i];
            uint256 lpBalance = _valueAt(_lpBalances[pid][owner], reward.block);
            amount += (reward.amount * lpBalance) / reward.lpTotal;
        }
    }

    function deposit(uint256 pid, uint256 amount) external onlyWETHPool(pid) {
        require(amount > 0, "MIRIN: INVALID_AMOUNT");

        // TODO: consider pool factor
        Checkpoint[] storage checkpoints = _lpBalances[pid][msg.sender];
        _updateValueAtNow(checkpoints, _latestValue(checkpoints, 0) + amount);

        address lpToken = masterChef.lpToken(pid);
        _safeTransferFrom(lpToken, msg.sender, address(this), amount);
        IERC20(lpToken).approve(address(masterChef), amount);
        masterChef.deposit(pid, amount, address(this));

        emit Deposit(pid, amount, msg.sender);
    }

    function withdraw(uint256 pid, uint256 amount) external onlyWETHPool(pid) {
        require(amount > 0, "MIRIN: INVALID_AMOUNT");

        // TODO: consider pool factor
        Checkpoint[] storage checkpoints = _lpBalances[pid][msg.sender];
        _updateValueAtNow(checkpoints, _latestValue(checkpoints, 0) - amount);

        _withdraw(pid, amount, msg.sender);
        claimReward(pid);

        emit Withdraw(pid, amount, msg.sender);
    }

    function rebalance(
        uint256 fromPid,
        uint256 fromAmount,
        uint256 toPid,
        uint256 toAmountMin
    ) external {
        (address fromPool, address fromToken, uint256 fromReward) = _computeReward(fromPid, fromAmount);
        (address toPool, address toToken, uint256 toRewardMin) = _computeReward(toPid, toAmountMin);
        require(fromReward < toRewardMin, "MIRIN: DEFICIT");

        uint256 fromLpTotal = masterChef.userInfo(fromPid, address(this)).amount;
        _updatePoolFactor(_poolFactors[fromPid], fromPid, fromLpTotal - fromAmount, fromLpTotal);
        _withdraw(fromPid, fromAmount, address(this));
        uint256 toAmount = _swapPoolToPool(fromPool, fromToken, fromAmount, toPool, toToken, toAmountMin);

        uint256 toLpTotal = masterChef.userInfo(toPid, address(this)).amount;
        _updatePoolFactor(_poolFactors[toPid], toPid, toLpTotal + toAmount, toLpTotal);
        IERC20(toPool).approve(address(masterChef), toAmount);
        masterChef.deposit(toPid, toAmount, address(this));

        emit Rebalance(fromPid, fromAmount, toPid, toAmount);
    }

    function claimReward(uint256 pid) public {
        uint256 amountReceived;
        uint256 toIndex = rewards[pid].length;
        for (uint256 i = lastRewardReceived[pid][msg.sender]; i < toIndex; i++) {
            Reward storage reward = rewards[pid][i];
            uint256 lpBalance = _valueAt(_lpBalances[pid][msg.sender], reward.block);
            uint256 amount = (reward.amount * lpBalance) / reward.lpTotal;
            amountReceived += amount;
        }
        lastRewardReceived[pid][msg.sender] = toIndex;
        lastSushiBalance = sushi.balanceOf(address(this)) - amountReceived;

        _safeTransfer(address(sushi), msg.sender, amountReceived);

        emit ClaimReward(pid, amountReceived, msg.sender);
    }

    function _deposit(
        uint256 pid,
        uint256 amount,
        address from
    ) internal {}

    function _withdraw(
        uint256 pid,
        uint256 amount,
        address to
    ) internal {
        uint256 lpTotal = masterChef.userInfo(pid, address(this)).amount;
        masterChef.withdraw(pid, amount, to);
        masterChef.harvest(pid, address(this));

        uint256 sushiBalance = sushi.balanceOf(address(this));
        rewards[pid].push(Reward(uint128(block.number), uint128(sushiBalance - lastSushiBalance), lpTotal));
    }

    function _computeReward(uint256 pid, uint256 lpAmount)
        internal
        view
        returns (
            address pool,
            address token,
            uint256 reward
        )
    {
        pool = masterChef.lpToken(pid);

        (address token0, address token1) = (IMirinPool(pool).token0(), IMirinPool(pool).token1());
        require(token0 == weth || token1 == weth, "MIRIN: INVALID_POOL");
        token = token0 == weth ? token1 : token0;

        uint64 allocPoint = masterChef.poolInfo(pid).allocPoint;
        uint256 lpSupply = IMirinPool(pool).balanceOf(address(masterChef));
        (uint112 reserve0, uint112 reserve1, ) = IMirinPool(pool).getReserves();
        uint112 wethReserve = token0 == weth ? reserve0 : reserve1;

        reward = (lpAmount * allocPoint) / (lpSupply * wethReserve);
    }

    function _updatePoolFactor(
        Checkpoint[] storage poolFactors,
        uint256 pid,
        uint256 numerator,
        uint256 denominator
    ) internal {
        uint256 fromLpTotal = masterChef.userInfo(pid, address(this)).amount;
        uint256 newFromLpFactor = (_latestValue(poolFactors, FACTOR_BASE) * numerator) / denominator;
        _updateValueAtNow(poolFactors, newFromLpFactor);
    }

    function _swapPoolToPool(
        address fromPool,
        address fromToken,
        uint256 fromAmount,
        address toPool,
        address toToken,
        uint256 toAmountMin
    ) internal returns (uint256 toAmount) {
        _safeTransfer(fromPool, fromPool, fromAmount);
        (uint256 amount0, uint256 amount1) = IMirinPool(fromPool).burn(address(this));
        (uint256 amountIn, uint256 wethAmount) =
            fromToken == IMirinPool(fromPool).token0() ? (amount0, amount1) : (amount1, amount0);
        _safeTransfer(fromToken, _getPool(fromToken, weth, 0), amountIn);
        address[] memory path = _path(fromToken, toToken);
        uint256[] memory pids = new uint256[](3);
        uint256[] memory amounts = _getAmountsOut(amountIn, path, pids);
        _swap(amounts, path, pids, toPool);
        _safeTransfer(weth, toPool, wethAmount);
        toAmount = IMirinPool(toPool).mint(address(this));
        require(toAmount >= toAmountMin, "MIRIN: INSUFFICIENT_TO_AMOUNT");
    }

    function _path(address fromToken, address toToken) internal returns (address[] memory path) {
        path = new address[](3);
        path[0] = fromToken;
        path[1] = weth;
        path[2] = toToken;
    }

    function _latestValue(Checkpoint[] storage checkpoints, uint256 defaultValue) internal view returns (uint256) {
        if (checkpoints.length == 0) {
            return defaultValue;
        } else {
            return checkpoints[checkpoints.length - 1].value;
        }
    }

    function _valueAt(Checkpoint[] storage checkpoints, uint256 blockNumber) internal view returns (uint256) {
        if (checkpoints.length == 0) return 0;

        // Shortcut for the actual value
        if (blockNumber >= checkpoints[checkpoints.length - 1].fromBlock)
            return checkpoints[checkpoints.length - 1].value;
        if (blockNumber < checkpoints[0].fromBlock) return 0;

        // Binary search of the value in the array
        uint256 min = 0;
        uint256 max = checkpoints.length - 1;
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (checkpoints[mid].fromBlock <= blockNumber) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return checkpoints[min].value;
    }

    function _updateValueAtNow(Checkpoint[] storage checkpoints, uint256 value) internal {
        if ((checkpoints.length == 0) || (checkpoints[checkpoints.length - 1].fromBlock < block.number)) {
            Checkpoint storage newCheckPoint = checkpoints.push();
            newCheckPoint.fromBlock = uint128(block.number);
            newCheckPoint.value = uint128(value);
        } else {
            Checkpoint storage oldCheckPoint = checkpoints[checkpoints.length - 1];
            oldCheckPoint.value = uint128(value);
        }
    }
}
