// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyAdapter } from "../../interfaces/IStrategyAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Uniswap V3 SwapRouter interface (SwapRouter02)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title UniswapV3DCAAdapter
 * @notice Adapter for Dollar-Cost Averaging (DCA) swaps on Uniswap V3 (Base chain)
 * @dev Executes recurring swaps at specified intervals
 *
 * Base Mainnet Addresses:
 * - SwapRouter02: 0x2626664c2603336E57B271c5C0b26F421741e481
 *
 * Base Sepolia Addresses:
 * - SwapRouter02: 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4
 */
contract UniswapV3DCAAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V3 SwapRouter
    address public immutable swapRouter;

    /// @notice Track execution counts per task (taskId => executionCount)
    mapping(bytes32 => uint256) public executionCounts;

    /// @notice Track last execution time per task (taskId => timestamp)
    mapping(bytes32 => uint256) public lastExecutionTime;

    /// @notice Common fee tiers on Uniswap V3
    uint24 public constant FEE_LOW = 500;      // 0.05%
    uint24 public constant FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant FEE_HIGH = 10000;   // 1%

    struct DCAParams {
        bytes32 taskId;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountPerSwap;
        uint256 interval;
        uint256 totalSwaps;
        uint256 minAmountOut;
        address recipient;
    }

    event DCAExecuted(
        bytes32 indexed taskId,
        address indexed vault,
        uint256 executionNumber,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _swapRouter) {
        require(_swapRouter != address(0), "Invalid router");
        swapRouter = _swapRouter;
    }

    /**
     * @notice Execute a DCA swap on Uniswap V3
     * @param vault Address of the task vault
     * @param params ABI-encoded parameters:
     *        - bytes32 taskId: Unique task identifier
     *        - address tokenIn: Token to sell
     *        - address tokenOut: Token to buy
     *        - uint24 fee: Pool fee tier (500, 3000, or 10000)
     *        - uint256 amountPerSwap: Amount of tokenIn per swap
     *        - uint256 interval: Seconds between swaps
     *        - uint256 totalSwaps: Total number of swaps (0 = unlimited)
     *        - uint256 minAmountOut: Minimum amount of tokenOut per swap
     *        - address recipient: Address to receive tokenOut
     */
    function execute(address vault, bytes calldata params) external override returns (bool, bytes memory) {
        DCAParams memory dcaParams = _decodeDCAParams(params);

        // Check if we can execute
        uint256 currentCount = executionCounts[dcaParams.taskId];
        uint256 lastExec = lastExecutionTime[dcaParams.taskId];

        // Check total swaps limit (0 = unlimited)
        if (dcaParams.totalSwaps > 0 && currentCount >= dcaParams.totalSwaps) {
            return (false, abi.encode("DCA completed"));
        }

        // Check interval (skip for first execution)
        if (currentCount > 0 && block.timestamp < lastExec + dcaParams.interval) {
            return (false, abi.encode("Interval not passed"));
        }

        // Update state BEFORE external calls (CEI pattern)
        uint256 executionNumber = currentCount + 1;
        executionCounts[dcaParams.taskId] = executionNumber;
        lastExecutionTime[dcaParams.taskId] = block.timestamp;

        uint256 amountOut = _executeSwap(vault, dcaParams);

        emit DCAExecuted(dcaParams.taskId, vault, executionNumber, dcaParams.amountPerSwap, amountOut);
        emit ActionExecuted(vault, swapRouter, true, abi.encode(amountOut, executionNumber));

        return (true, abi.encode(amountOut, executionNumber));
    }

    /**
     * @notice Check if DCA swap can be executed
     */
    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool, string memory) {
        (
            bytes32 taskId,
            ,,,
            ,
            uint256 interval,
            uint256 totalSwaps,
            ,
        ) = abi.decode(params, (bytes32, address, address, uint24, uint256, uint256, uint256, uint256, address));

        uint256 currentCount = executionCounts[taskId];
        uint256 lastExec = lastExecutionTime[taskId];

        // Check total swaps limit
        if (totalSwaps > 0 && currentCount >= totalSwaps) {
            return (false, "DCA completed - all swaps executed");
        }

        // Check interval (skip for first execution)
        if (currentCount > 0 && block.timestamp < lastExec + interval) {
            uint256 nextExec = lastExec + interval;
            return (false, string(abi.encodePacked("Next swap in ", _uintToString(nextExec - block.timestamp), " seconds")));
        }

        return (true, string(abi.encodePacked("Ready for swap #", _uintToString(currentCount + 1))));
    }

    /**
     * @notice Get token requirements for DCA
     */
    function getTokenRequirements(bytes calldata params)
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        (
            bytes32 taskId,
            address tokenIn,
            ,,
            uint256 amountPerSwap,
            ,
            uint256 totalSwaps,
            ,
        ) = abi.decode(params, (bytes32, address, address, uint24, uint256, uint256, uint256, uint256, address));

        tokens = new address[](1);
        tokens[0] = tokenIn;

        amounts = new uint256[](1);

        if (totalSwaps > 0 && executionCounts[taskId] >= totalSwaps) {
            amounts[0] = 0;
        } else {
            amounts[0] = amountPerSwap;
        }
    }

    function isProtocolSupported(address protocol) external view returns (bool) {
        return protocol == swapRouter;
    }

    function name() external pure returns (string memory) {
        return "UniswapV3DCAAdapter-Base";
    }

    function validateParams(bytes calldata params) external pure override returns (bool, string memory) {
        if (params.length == 0) {
            return (false, "Empty params");
        }

        (
            bytes32 taskId,
            address tokenIn,
            address tokenOut,
            uint24 fee,
            uint256 amountPerSwap,
            uint256 interval,
            ,
            ,
            address recipient
        ) = abi.decode(params, (bytes32, address, address, uint24, uint256, uint256, uint256, uint256, address));

        if (taskId == bytes32(0)) return (false, "Invalid taskId");
        if (tokenIn == address(0)) return (false, "Invalid tokenIn");
        if (tokenOut == address(0)) return (false, "Invalid tokenOut");
        if (tokenIn == tokenOut) return (false, "Same token");
        if (fee != 500 && fee != 3000 && fee != 10000) return (false, "Invalid fee tier");
        if (amountPerSwap == 0) return (false, "Zero amount");
        if (interval == 0) return (false, "Zero interval");
        if (recipient == address(0)) return (false, "Invalid recipient");

        return (true, "");
    }

    /**
     * @notice Get DCA status for a task
     */
    function getDCAStatus(bytes32 taskId) external view returns (uint256 execCount, uint256 lastExec) {
        return (executionCounts[taskId], lastExecutionTime[taskId]);
    }

    function _decodeDCAParams(bytes calldata params) internal pure returns (DCAParams memory dcaParams) {
        dcaParams = abi.decode(params, (DCAParams));
    }

    function _executeSwap(address vault, DCAParams memory dcaParams) internal returns (uint256 amountOut) {
        IERC20(dcaParams.tokenIn).safeTransferFrom(vault, address(this), dcaParams.amountPerSwap);
        IERC20(dcaParams.tokenIn).safeIncreaseAllowance(swapRouter, dcaParams.amountPerSwap);

        amountOut = ISwapRouter(swapRouter).exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: dcaParams.tokenIn,
            tokenOut: dcaParams.tokenOut,
            fee: dcaParams.fee,
            recipient: dcaParams.recipient,
            amountIn: dcaParams.amountPerSwap,
            amountOutMinimum: dcaParams.minAmountOut,
            sqrtPriceLimitX96: 0
        }));
        (bool okClear,) = address(IERC20(dcaParams.tokenIn)).call(abi.encodeWithSignature("approve(address,uint256)", swapRouter, 0));
        if (!okClear) {
            // ignore
        }

        require(amountOut >= dcaParams.minAmountOut, "Slippage exceeded");
    }

    /**
     * @dev Convert uint to string (helper)
     */
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

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
}
