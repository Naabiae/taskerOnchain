// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyAdapter } from "../../interfaces/IStrategyAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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

/// @notice Uniswap V3 Pool interface for price quotes
interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Uniswap V3 Factory interface
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @title UniswapV3LimitOrderAdapter
 * @notice Adapter for limit order swaps on Uniswap V3 (Base chain)
 * @dev Executes swaps when price reaches target threshold
 *
 * Base Mainnet Addresses:
 * - SwapRouter02: 0x2626664c2603336E57B271c5C0b26F421741e481
 * - Factory: 0x33128a8fC17869897dcE68Ed026d694621f6FDfD
 *
 * Base Sepolia Addresses:
 * - SwapRouter02: 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4
 * - Factory: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24
 */
contract UniswapV3LimitOrderAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V3 SwapRouter
    address public immutable swapRouter;

    /// @notice Uniswap V3 Factory for pool lookups
    address public immutable factory;

    /// @notice Track executed orders (orderId => executed)
    mapping(bytes32 => bool) public orderExecuted;

    /// @notice Order direction
    enum OrderType {
        LIMIT_BUY,   // Buy when price drops to target (or below)
        LIMIT_SELL,  // Sell when price rises to target (or above)
        STOP_LOSS,   // Sell when price drops to target (or below)
        TAKE_PROFIT  // Sell when price rises to target (or above)
    }

    /// @notice Common fee tiers on Uniswap V3
    uint24 public constant FEE_LOW = 500;      // 0.05%
    uint24 public constant FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant FEE_HIGH = 10000;   // 1%

    /// @notice Price precision (18 decimals)
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 private constant Q96 = 2 ** 96;

    struct LimitOrderParams {
        bytes32 orderId;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint256 targetPrice;
        uint8 orderType;
        uint256 minAmountOut;
        address recipient;
        uint256 expiry;
    }

    event LimitOrderExecuted(
        bytes32 indexed orderId,
        address indexed vault,
        OrderType orderType,
        uint256 currentPrice,
        uint256 targetPrice,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _swapRouter, address _factory) {
        require(_swapRouter != address(0), "Invalid router");
        require(_factory != address(0), "Invalid factory");
        swapRouter = _swapRouter;
        factory = _factory;
    }

    /**
     * @notice Execute a limit order swap on Uniswap V3
     * @param vault Address of the task vault
     * @param params ABI-encoded parameters:
     *        - bytes32 orderId: Unique order identifier
     *        - address tokenIn: Token to sell
     *        - address tokenOut: Token to buy
     *        - uint24 fee: Pool fee tier (500, 3000, or 10000)
     *        - uint256 amountIn: Amount of tokenIn to swap
     *        - uint256 targetPrice: Target price (tokenOut per tokenIn, 18 decimals)
     *        - uint8 orderType: 0=LIMIT_BUY, 1=LIMIT_SELL, 2=STOP_LOSS, 3=TAKE_PROFIT
     *        - uint256 minAmountOut: Minimum amount of tokenOut to receive
     *        - address recipient: Address to receive tokenOut
     *        - uint256 expiry: Unix timestamp expiry (0 = no expiry)
     */
    function execute(address vault, bytes calldata params) external override returns (bool, bytes memory) {
        LimitOrderParams memory orderParams = _decodeLimitOrderParams(params);

        // Check if already executed
        require(!orderExecuted[orderParams.orderId], "Order already executed");

        // Check expiry
        if (orderParams.expiry > 0) {
            require(block.timestamp <= orderParams.expiry, "Order expired");
        }

        // Get current price
        uint256 currentPrice = _getPrice(orderParams.tokenIn, orderParams.tokenOut, orderParams.fee);

        // Check price condition based on order type
        require(
            _checkPriceCondition(currentPrice, orderParams.targetPrice, OrderType(orderParams.orderType)),
            "Price condition not met"
        );

        // Mark as executed BEFORE external calls (CEI pattern)
        orderExecuted[orderParams.orderId] = true;

        uint256 amountOut = _executeSwap(vault, orderParams);

        emit LimitOrderExecuted(
            orderParams.orderId,
            vault,
            OrderType(orderParams.orderType),
            currentPrice,
            orderParams.targetPrice,
            orderParams.amountIn,
            amountOut
        );
        emit ActionExecuted(vault, swapRouter, true, abi.encode(amountOut));

        return (true, abi.encode(amountOut));
    }

    /**
     * @notice Check if limit order can be executed
     */
    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool, string memory) {
        (
            bytes32 orderId,
            address tokenIn,
            address tokenOut,
            uint24 fee,
            ,
            uint256 targetPrice,
            uint8 orderType,
            ,
            ,
            uint256 expiry
        ) = abi.decode(params, (bytes32, address, address, uint24, uint256, uint256, uint8, uint256, address, uint256));

        // Check if already executed
        if (orderExecuted[orderId]) {
            return (false, "Order already executed");
        }

        // Check expiry
        if (expiry > 0 && block.timestamp > expiry) {
            return (false, "Order expired");
        }

        // Get pool
        address pool = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) {
            return (false, "Pool does not exist");
        }

        // Get current price
        uint256 currentPrice = _getPrice(tokenIn, tokenOut, fee);

        // Check price condition
        if (_checkPriceCondition(currentPrice, targetPrice, OrderType(orderType))) {
            return (true, "Price target reached - ready to execute");
        }

        // Calculate distance to target
        uint256 priceDiff;
        if (currentPrice > targetPrice) {
            priceDiff = ((currentPrice - targetPrice) * 10000) / currentPrice;
        } else {
            priceDiff = ((targetPrice - currentPrice) * 10000) / targetPrice;
        }

        return (false, string(abi.encodePacked(
            "Waiting for price. Current: ",
            _formatPrice(currentPrice),
            " Target: ",
            _formatPrice(targetPrice),
            " (",
            _uintToString(priceDiff / 100),
            ".",
            _uintToString(priceDiff % 100),
            "% away)"
        )));
    }

    /**
     * @notice Get token requirements for the order
     */
    function getTokenRequirements(bytes calldata params)
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        (
            bytes32 orderId,
            address tokenIn,
            ,,
            uint256 amountIn,
            ,,,,
        ) = abi.decode(params, (bytes32, address, address, uint24, uint256, uint256, uint8, uint256, address, uint256));

        tokens = new address[](1);
        tokens[0] = tokenIn;

        amounts = new uint256[](1);
        // Return 0 if already executed
        amounts[0] = orderExecuted[orderId] ? 0 : amountIn;
    }

    function isProtocolSupported(address protocol) external view returns (bool) {
        return protocol == swapRouter || protocol == factory;
    }

    function name() external pure returns (string memory) {
        return "UniswapV3LimitOrderAdapter-Base";
    }

    function validateParams(bytes calldata params) external view override returns (bool, string memory) {
        if (params.length == 0) {
            return (false, "Empty params");
        }

        (
            bytes32 orderId,
            address tokenIn,
            address tokenOut,
            uint24 fee,
            uint256 amountIn,
            uint256 targetPrice,
            uint8 orderType,
            ,
            address recipient,
        ) = abi.decode(params, (bytes32, address, address, uint24, uint256, uint256, uint8, uint256, address, uint256));

        if (orderId == bytes32(0)) return (false, "Invalid orderId");
        if (tokenIn == address(0)) return (false, "Invalid tokenIn");
        if (tokenOut == address(0)) return (false, "Invalid tokenOut");
        if (tokenIn == tokenOut) return (false, "Same token");
        if (fee != 500 && fee != 3000 && fee != 10000) return (false, "Invalid fee tier");
        if (amountIn == 0) return (false, "Zero amount");
        if (targetPrice == 0) return (false, "Zero target price");
        if (orderType > 3) return (false, "Invalid order type");
        if (recipient == address(0)) return (false, "Invalid recipient");

        // Check pool exists
        address pool = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) return (false, "Pool does not exist");

        return (true, "");
    }

    /**
     * @notice Get current price from Uniswap V3 pool
     * @param tokenIn Token to sell
     * @param tokenOut Token to buy
     * @param fee Pool fee tier
     * @return price Price of tokenOut per tokenIn (18 decimals)
     */
    function _getPrice(address tokenIn, address tokenOut, uint24 fee) internal view returns (uint256 price) {
        address pool = IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee);
        require(pool != address(0), "Pool does not exist");

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        address token0 = IUniswapV3Pool(pool).token0();

        // Calculate price from sqrtPriceX96
        // price = (sqrtPriceX96 / 2^96)^2
        // For token0 -> token1: price = sqrtPrice^2
        // For token1 -> token0: price = 1/sqrtPrice^2

        uint256 ratioX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);
        if (ratioX96 == 0) return 0;

        if (tokenIn == token0) {
            // tokenIn is token0, price = sqrtPrice^2 / 2^192 * PRECISION
            price = Math.mulDiv(ratioX96, PRICE_PRECISION, Q96);
        } else {
            // tokenIn is token1, price = 2^192 / sqrtPrice^2 * PRECISION
            price = Math.mulDiv(Q96, PRICE_PRECISION, ratioX96);
        }
    }

    /**
     * @notice Get current price (external view)
     */
    function getCurrentPrice(address tokenIn, address tokenOut, uint24 fee) external view returns (uint256) {
        return _getPrice(tokenIn, tokenOut, fee);
    }

    /**
     * @notice Check if price condition is met
     */
    function _checkPriceCondition(
        uint256 currentPrice,
        uint256 targetPrice,
        OrderType orderType
    ) internal pure returns (bool) {
        if (orderType == OrderType.LIMIT_BUY || orderType == OrderType.STOP_LOSS) {
            // Execute when price drops to or below target
            return currentPrice <= targetPrice;
        } else {
            // LIMIT_SELL, TAKE_PROFIT: Execute when price rises to or above target
            return currentPrice >= targetPrice;
        }
    }

    /**
     * @notice Check if an order has been executed
     */
    function isOrderExecuted(bytes32 orderId) external view returns (bool) {
        return orderExecuted[orderId];
    }

    function _decodeLimitOrderParams(bytes calldata params)
        internal
        pure
        returns (LimitOrderParams memory orderParams)
    {
        orderParams = abi.decode(params, (LimitOrderParams));
    }

    function _executeSwap(address vault, LimitOrderParams memory orderParams) internal returns (uint256 amountOut) {
        IERC20(orderParams.tokenIn).safeTransferFrom(vault, address(this), orderParams.amountIn);
        IERC20(orderParams.tokenIn).safeIncreaseAllowance(swapRouter, orderParams.amountIn);

        amountOut = ISwapRouter(swapRouter).exactInputSingle(ISwapRouter.ExactInputSingleParams({
            tokenIn: orderParams.tokenIn,
            tokenOut: orderParams.tokenOut,
            fee: orderParams.fee,
            recipient: orderParams.recipient,
            amountIn: orderParams.amountIn,
            amountOutMinimum: orderParams.minAmountOut,
            sqrtPriceLimitX96: 0
        }));
        (bool okClear,) = address(IERC20(orderParams.tokenIn)).call(abi.encodeWithSignature("approve(address,uint256)", swapRouter, 0));
        if (!okClear) {
            // ignore
        }

        require(amountOut >= orderParams.minAmountOut, "Slippage exceeded");
    }

    /**
     * @dev Format price to string with 4 decimals
     */
    function _formatPrice(uint256 price) internal pure returns (string memory) {
        uint256 wholePart = price / PRICE_PRECISION;
        uint256 decimalPart = (price % PRICE_PRECISION) / (PRICE_PRECISION / 10000);
        return string(abi.encodePacked(_uintToString(wholePart), ".", _padZeros(decimalPart, 4)));
    }

    /**
     * @dev Pad number with leading zeros
     */
    function _padZeros(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory result = new bytes(length);
        for (uint256 i = length; i > 0; i--) {
            result[i - 1] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(result);
    }

    /**
     * @dev Convert uint to string
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
