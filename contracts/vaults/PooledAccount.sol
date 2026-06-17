// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../core/BaseVault.sol";
import "../modules/SharedAccountModule.sol";

contract PooledAccount is BaseVault, SharedAccountModule {
    using SafeERC20 for IERC20;

    address public manager;

    // ─── Performance fee (Phase 2) ────────────────────────────────────────────
    // Fee is taken only from gains above the high-water mark.
    // Expressed in basis points: 200 = 2%.
    uint256 public feePercentage;       // e.g. 200 for 2%
    address public feeRecipient;        // keeper / AI agent wallet

    // tracks the NAV at which we last extracted a fee — prevents double-dipping
    uint256 public lastFeeExtractionNAV;

    // ─── Circuit breaker ──────────────────────────────────────────────────────
    // If NAV drops > maxDrawdownBps below highWaterMark, halt new strategy calls.
    uint256 public maxDrawdownBps = 3000; // 30%
    bool    public circuitBreakerTripped;

    // ─── Events ───────────────────────────────────────────────────────────────
    event FeePercentageUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event PerformanceFeeExtracted(address indexed recipient, uint256 assetAmount, uint256 navAtExtraction);
    event CircuitBreakerTripped(uint256 currentNAV, uint256 hwm, uint256 drawdownBps);
    event CircuitBreakerReset(uint256 currentNAV);
    event MaxDrawdownUpdated(uint256 oldBps, uint256 newBps);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error OnlyManager();
    error ZeroAddress();
    error InvalidFee();
    error InvalidMaxDrawdown();
    error NoGainsToExtract();
    error CircuitBreakerActive();

    // ─── Constructor ──────────────────────────────────────────────────────────
    // 4-arg form: compatible with existing tests.
    // Fee defaults to 0; call setFeePercentage after deployment to configure.
    constructor(
        address _asset,
        address _manager,
        address _strategyRegistry,
        address _executorHub
    ) {
        if (_asset == address(0)) revert ZeroAddress();
        if (_executorHub == address(0)) revert ZeroAddress();

        asset            = IERC20(_asset);
        manager          = _manager;
        strategyRegistry = _strategyRegistry;   // optional (address(0) = no registry check)
        executorHub      = _executorHub;
        feeRecipient     = _manager;            // default: fees go to manager
        feePercentage    = 0;                   // set via setFeePercentage
    }

    // ─── onlyPoolManager (implements SharedAccountModule modifier) ─────────────
    modifier onlyPoolManager() override {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    // ─── Manager config ───────────────────────────────────────────────────────

    function setManager(address _manager) external {
        if (msg.sender != manager) revert OnlyManager();
        if (_manager == address(0)) revert ZeroAddress();
        address old = manager;
        manager = _manager;
        emit ManagerUpdated(old, _manager);
    }

    function setFeePercentage(uint256 _feePercentage) external {
        if (msg.sender != manager) revert OnlyManager();
        if (_feePercentage > 5000) revert InvalidFee(); // cap at 50%
        uint256 old = feePercentage;
        feePercentage = _feePercentage;
        emit FeePercentageUpdated(old, _feePercentage);
    }

    function setFeeRecipient(address _feeRecipient) external {
        if (msg.sender != manager) revert OnlyManager();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(old, _feeRecipient);
    }

    function setMaxDrawdown(uint256 _maxDrawdownBps) external {
        if (msg.sender != manager) revert OnlyManager();
        if (_maxDrawdownBps == 0 || _maxDrawdownBps > 10000) revert InvalidMaxDrawdown();
        uint256 old = maxDrawdownBps;
        maxDrawdownBps = _maxDrawdownBps;
        emit MaxDrawdownUpdated(old, _maxDrawdownBps);
    }

    // ─── Performance fee extraction ───────────────────────────────────────────

    /**
     * @notice Extract performance fee from gains above the high-water mark.
     *
     * Only callable by manager. Only extracts from NEW gains — gains already
     * taxed (below lastFeeExtractionNAV) are not double-counted.
     *
     * Fee is paid by transferring liquid assets to feeRecipient.
     * If vault is illiquid, manager must replenish before extracting.
     *
     * After extraction, lastFeeExtractionNAV is updated so next call starts fresh.
     */
    function extractPerformanceFee() external nonReentrant returns (uint256 feeAmount) {
        if (msg.sender != manager) revert OnlyManager();
        if (feePercentage == 0) revert NoGainsToExtract();

        uint256 nav = totalAssets();
        uint256 baseline = lastFeeExtractionNAV > 0 ? lastFeeExtractionNAV : totalCapitalDeposited;

        if (nav <= baseline) revert NoGainsToExtract();

        uint256 newGains = nav - baseline;
        feeAmount = (newGains * feePercentage) / 10000;

        if (feeAmount == 0) revert NoGainsToExtract();
        require(liquidAssets() >= feeAmount, "Insufficient liquid assets for fee");

        lastFeeExtractionNAV = nav - feeAmount; // advance baseline past this extraction
        if (nav - feeAmount > highWaterMark) highWaterMark = nav - feeAmount;

        asset.safeTransfer(feeRecipient, feeAmount);
        emit PerformanceFeeExtracted(feeRecipient, feeAmount, nav);
    }

    // ─── Circuit breaker ──────────────────────────────────────────────────────

    /**
     * @notice Check and trip the circuit breaker if drawdown exceeds max.
     * Called internally before strategy execution.
     */
    function _checkCircuitBreaker() internal {
        if (highWaterMark == 0) return;
        uint256 nav = totalAssets();
        if (nav >= highWaterMark) return;

        uint256 drawdownBps = ((highWaterMark - nav) * 10000) / highWaterMark;
        if (drawdownBps >= maxDrawdownBps) {
            circuitBreakerTripped = true;
            emit CircuitBreakerTripped(nav, highWaterMark, drawdownBps);
        }
    }

    /// @notice Expose circuit breaker check externally (manager can force a check).
    function checkAndTripCircuitBreaker() external {
        if (msg.sender != manager) revert OnlyManager();
        _checkCircuitBreaker();
    }

    function resetCircuitBreaker() external {
        if (msg.sender != manager) revert OnlyManager();
        circuitBreakerTripped = false;
        emit CircuitBreakerReset(totalAssets());
    }

    // ─── Strategy execution (wires into BaseVault) ────────────────────────────

    function execute(
        address strategy,
        uint256 value,
        bytes calldata params
    ) external nonReentrant returns (bool success, bytes memory result) {
        if (msg.sender != manager) revert OnlyManager();
        if (circuitBreakerTripped) revert CircuitBreakerActive();

        _checkCircuitBreaker();
        if (circuitBreakerTripped) revert CircuitBreakerActive();

        (address[] memory tokens, uint256[] memory amounts) =
            _getTokenRequirements(strategy, params);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                _enforceSpendingLimit(msg.sender, amounts[i]);
            }
        }

        _beforeExecution(msg.sender, strategy, params);
        nonce++;
        (success, result) = _executeStrategy(strategy, value, params);
        emit StrategyExecuted(strategy, success, nonce);
    }

    // ─── BaseVault overrides ──────────────────────────────────────────────────

    function _canExecute(address caller) internal view override(BaseVault, SharedAccountModule) returns (bool) {
        return caller == manager;
    }

    function _canWithdraw(address caller) internal view override(BaseVault, SharedAccountModule) returns (bool) {
        return false;
    }

    function _beforeExecution(
        address caller,
        address strategy,
        bytes memory params
    ) internal override {}

    function _getTokenRequirements(address strategy, bytes memory params)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        bytes memory callDataNew = abi.encodeWithSignature(
            "getTokenRequirements(address,bytes)", address(this), params
        );
        (bool success, bytes memory result) = strategy.staticcall(callDataNew);
        if (!success) {
            bytes memory callData = abi.encodeWithSignature("getTokenRequirements(bytes)", params);
            (success, result) = strategy.staticcall(callData);
        }
        if (success) {
            (tokens, amounts) = abi.decode(result, (address[], uint256[]));
        } else {
            tokens   = new address[](0);
            amounts  = new uint256[](0);
        }
    }
}
