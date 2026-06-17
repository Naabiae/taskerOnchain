import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  MockERC20,
  MockStrategyAdapter,
  UserVault,
  UserVaultFactory,
  StrategyRegistry,
  ExecutorHub,
  RewardManager,
} from "../typechain-types";

describe("Composability Integration Tests", function () {
  // Signers
  let deployer: SignerWithAddress;
  let user: SignerWithAddress;
  let operator: SignerWithAddress;
  let executor: SignerWithAddress;
  let nonOwner: SignerWithAddress;
  let recipient: SignerWithAddress;

  // Core contracts
  let vaultImplementation: UserVault;
  let strategyRegistry: StrategyRegistry;
  let executorHub: ExecutorHub;
  let rewardManager: RewardManager;
  let factory: UserVaultFactory;

  // Vault instance (deployed per user)
  let vault: UserVault;
  let vaultAddress: string;

  // Mock assets
  let mockToken: MockERC20;
  let mockAdapter: MockStrategyAdapter;
  let mockExecutorHub: any;

  // Constants
  const TOKEN_DECIMALS = 6;
  const INITIAL_TOKEN_BALANCE = ethers.parseUnits("10000", TOKEN_DECIMALS);
  const INITIAL_ETH_BALANCE = ethers.parseEther("10");
  const EXECUTE_AMOUNT = ethers.parseUnits("100", TOKEN_DECIMALS);
  const GAS_LIMIT = 300000;

  // Helper: build strategy params
  function buildParams(
    token: string,
    amount: bigint,
    to: string
  ): string {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256", "address"],
      [token, amount, to]
    );
  }

  before(async function () {
    [deployer, user, operator, executor, nonOwner, recipient] =
      await ethers.getSigners();
  });

  beforeEach(async function () {
    // ── Deploy mock token ──
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20Factory.deploy(
      "Mock USD",
      "mUSD",
      TOKEN_DECIMALS
    );
    await mockToken.waitForDeployment();

    // ── Deploy vault implementation ──
    const UserVaultFactory_ = await ethers.getContractFactory("UserVault");
    vaultImplementation = await UserVaultFactory_.deploy();
    await vaultImplementation.waitForDeployment();

    // ── Deploy StrategyRegistry ──
    const StrategyRegistryFactory =
      await ethers.getContractFactory("StrategyRegistry");
    strategyRegistry = await StrategyRegistryFactory.deploy(deployer.address);
    await strategyRegistry.waitForDeployment();

    // ── Deploy ExecutorHub ──
    const ExecutorHubFactory = await ethers.getContractFactory("ExecutorHub");
    executorHub = await ExecutorHubFactory.deploy(deployer.address);
    await executorHub.waitForDeployment();

    // ── Deploy RewardManager ──
    const RewardManagerFactory =
      await ethers.getContractFactory("RewardManager");
    rewardManager = await RewardManagerFactory.deploy(deployer.address);
    await rewardManager.waitForDeployment();

    // ── Deploy UserVaultFactory ──
    const UserVaultFactoryFactory =
      await ethers.getContractFactory("UserVaultFactory");
    factory = await UserVaultFactoryFactory.deploy(
      await vaultImplementation.getAddress(),
      await strategyRegistry.getAddress(),
      await executorHub.getAddress(),
      deployer.address
    );
    await factory.waitForDeployment();

    // ── Deploy MockStrategyAdapter ──
    const MockStrategyAdapterFactory =
      await ethers.getContractFactory("MockStrategyAdapter");
    mockAdapter = await MockStrategyAdapterFactory.deploy();
    await mockAdapter.waitForDeployment();

    // ── Create vault for user ──
    await factory.connect(user).createVault();
    vaultAddress = await factory.getVault(user.address);
    vault = await ethers.getContractAt("UserVault", vaultAddress);

    // ── Fund vault ──
    await mockToken.mint(vaultAddress, INITIAL_TOKEN_BALANCE);
    await deployer.sendTransaction({
      to: vaultAddress,
      value: INITIAL_ETH_BALANCE,
    });

    // ── Connect RewardManager to vault ──
    await vault.connect(user).setRewardManager(await rewardManager.getAddress());
    await rewardManager.setExecutorHub(await executorHub.getAddress());
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Strategy Registration
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Strategy Registration", function () {
    it("Owner can register a strategy in StrategyRegistry", async function () {
      const adapterAddr = await mockAdapter.getAddress();

      await expect(
        strategyRegistry.registerStrategy(
          adapterAddr,
          GAS_LIMIT,
          true,
          false,
          false,
          [await mockToken.getAddress()]
        )
      )
        .to.emit(strategyRegistry, "StrategyRegistered")
        .withArgs(adapterAddr, GAS_LIMIT, false);

      expect(await strategyRegistry.isStrategyActive(adapterAddr)).to.be.true;

      const info = await strategyRegistry.getStrategyInfo(adapterAddr);
      expect(info.adapter).to.equal(adapterAddr);
      expect(info.isActive).to.be.true;
      expect(info.gasLimit).to.equal(GAS_LIMIT);
      expect(info.requiresTokens).to.be.true;
    });

    it("Owner can deactivate a registered strategy", async function () {
      const adapterAddr = await mockAdapter.getAddress();
      await strategyRegistry.registerStrategy(
        adapterAddr,
        GAS_LIMIT,
        true,
        false,
        false,
        [await mockToken.getAddress()]
      );

      await expect(strategyRegistry.deactivateStrategy(adapterAddr))
        .to.emit(strategyRegistry, "StrategyDeactivated")
        .withArgs(adapterAddr);

      expect(await strategyRegistry.isStrategyActive(adapterAddr)).to.be.false;
    });

    it("Owner can reactivate a deactivated strategy", async function () {
      const adapterAddr = await mockAdapter.getAddress();
      await strategyRegistry.registerStrategy(
        adapterAddr,
        GAS_LIMIT,
        true,
        false,
        false,
        [await mockToken.getAddress()]
      );
      await strategyRegistry.deactivateStrategy(adapterAddr);

      await expect(strategyRegistry.activateStrategy(adapterAddr))
        .to.emit(strategyRegistry, "StrategyActivated")
        .withArgs(adapterAddr);

      expect(await strategyRegistry.isStrategyActive(adapterAddr)).to.be.true;
    });

    it("Non-owner cannot register strategies", async function () {
      await expect(
        strategyRegistry
          .connect(nonOwner)
          .registerStrategy(
            await mockAdapter.getAddress(),
            GAS_LIMIT,
            true,
            false,
            false,
            []
          )
      ).to.be.revertedWithCustomError(strategyRegistry, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Strategy Execution via UserVault
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Strategy Execution via UserVault", function () {
    beforeEach(async function () {
      await strategyRegistry.registerStrategy(
        await mockAdapter.getAddress(),
        GAS_LIMIT,
        true,
        false,
        false,
        [await mockToken.getAddress()]
      );
    });

    it("Owner can execute a registered strategy", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      const recipientBalanceBefore = await mockToken.balanceOf(recipient.address);

      await vault.connect(user).execute(await mockAdapter.getAddress(), 0, params);

      const recipientBalanceAfter = await mockToken.balanceOf(recipient.address);
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(EXECUTE_AMOUNT);
    });

    it("Owner can execute batch of strategies", async function () {
      const amount1 = ethers.parseUnits("50", TOKEN_DECIMALS);
      const amount2 = ethers.parseUnits("75", TOKEN_DECIMALS);

      const params1 = buildParams(await mockToken.getAddress(), amount1, recipient.address);
      const params2 = buildParams(
        await mockToken.getAddress(),
        amount2,
        operator.address
      );

      const recipientBalBefore = await mockToken.balanceOf(recipient.address);
      const operatorBalBefore = await mockToken.balanceOf(operator.address);

      await vault.connect(user).executeBatch([
        { strategy: await mockAdapter.getAddress(), value: 0, params: params1 },
        { strategy: await mockAdapter.getAddress(), value: 0, params: params2 },
      ]);

      const recipientBalAfter = await mockToken.balanceOf(recipient.address);
      const operatorBalAfter = await mockToken.balanceOf(operator.address);

      expect(recipientBalAfter - recipientBalBefore).to.equal(amount1);
      expect(operatorBalAfter - operatorBalBefore).to.equal(amount2);
    });

    it("Execution fails for unregistered strategy", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      await expect(
        vault.connect(user).execute(nonOwner.address, 0, params)
      ).to.be.revertedWithCustomError(vault, "StrategyNotRegistered");
    });

    it("Execution fails for deactivated strategy", async function () {
      await strategyRegistry.deactivateStrategy(await mockAdapter.getAddress());

      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      await expect(
        vault.connect(user).execute(await mockAdapter.getAddress(), 0, params)
      ).to.be.revertedWithCustomError(vault, "StrategyNotRegistered");
    });

    it("Operator with canExecuteImmediate can execute strategy", async function () {
      // Set operator
      await vault
        .connect(user)
        .setOperator(operator.address, false, false, false, true);

      // Set spending rule
      await vault
        .connect(user)
        .setSpendingRule(
          operator.address,
          await mockToken.getAddress(),
          EXECUTE_AMOUNT * 2n,
          EXECUTE_AMOUNT * 10n,
          EXECUTE_AMOUNT * 100n
        );

      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      const recipientBalanceBefore = await mockToken.balanceOf(recipient.address);

      await vault.connect(operator).execute(await mockAdapter.getAddress(), 0, params);

      const recipientBalanceAfter = await mockToken.balanceOf(recipient.address);
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(EXECUTE_AMOUNT);
    });

    it("Operator without canExecuteImmediate cannot execute", async function () {
      await vault
        .connect(user)
        .setOperator(operator.address, true, false, false, false);

      await vault
        .connect(user)
        .setSpendingRule(
          operator.address,
          await mockToken.getAddress(),
          EXECUTE_AMOUNT * 2n,
          EXECUTE_AMOUNT * 10n,
          EXECUTE_AMOUNT * 100n
        );

      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      await expect(
        vault.connect(operator).execute(await mockAdapter.getAddress(), 0, params)
      ).to.be.revertedWithCustomError(vault, "OperatorNotPermitted");
    });

    it("Spending rules are enforced on operator execution", async function () {
      await vault
        .connect(user)
        .setOperator(operator.address, false, false, false, true);

      // Set tight spending rule: maxPerExecution = 50 tokens
      const maxPerExec = ethers.parseUnits("50", TOKEN_DECIMALS);
      await vault
        .connect(user)
        .setSpendingRule(
          operator.address,
          await mockToken.getAddress(),
          maxPerExec,
          maxPerExec * 10n,
          maxPerExec * 100n
        );

      // Try to execute with 100 tokens (exceeds maxPerExecution)
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      await expect(
        vault.connect(operator).execute(await mockAdapter.getAddress(), 0, params)
      ).to.be.revertedWithCustomError(vault, "SpendingLimitExceeded");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Automation via ExecutorHub
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Automation via ExecutorHub", function () {
    beforeEach(async function () {
      await strategyRegistry.registerStrategy(
        await mockAdapter.getAddress(),
        GAS_LIMIT,
        true,
        false,
        false,
        [await mockToken.getAddress()]
      );
    });

    it("Owner can create an automation", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );

      await expect(
        vault
          .connect(user)
          .createAutomation(await mockAdapter.getAddress(), params, 5, "test-auto")
      )
        .to.emit(vault, "AutomationCreated")
        .withArgs(0, await mockAdapter.getAddress(), "test-auto");

      const automation = await vault.getAutomation(0);
      expect(automation.strategy).to.equal(await mockAdapter.getAddress());
      expect(automation.status).to.equal(0); // ACTIVE
      expect(automation.maxExecutions).to.equal(5);
    });

    it("Executor can be added by owner in ExecutorHub", async function () {
      await expect(executorHub.connect(deployer).addExecutor(executor.address))
        .to.emit(executorHub, "ExecutorAdded")
        .withArgs(executor.address);

      const execInfo = await executorHub.getExecutor(executor.address);
      expect(execInfo.isActive).to.be.true;
      expect(execInfo.totalExecutions).to.equal(0);
    });

    it("Registered executor can trigger automation via ExecutorHub", async function () {
      // Create automation
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 5, "auto-1");

      // Register executor (owner adds executor)
      await executorHub.connect(deployer).addExecutor(executor.address);

      const recipientBalBefore = await mockToken.balanceOf(recipient.address);

      // Trigger via ExecutorHub
      await expect(
        executorHub
          .connect(executor)
          .executeAutomation(vaultAddress, 0)
      )
        .to.emit(executorHub, "AutomationExecuted")
        .withArgs(vaultAddress, 0, executor.address, true);

      const recipientBalAfter = await mockToken.balanceOf(recipient.address);
      expect(recipientBalAfter - recipientBalBefore).to.equal(EXECUTE_AMOUNT);

      const automation = await vault.getAutomation(0);
      expect(automation.executionCount).to.equal(1);
    });

    it("Registered executor can trigger automation (verified access control)", async function () {
      // Create automation
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 5, "auto-2");

      // Only admin-added executors can call executeAutomation
      await executorHub.connect(deployer).addExecutor(nonOwner.address);

      const recipientBalBefore = await mockToken.balanceOf(recipient.address);

      await executorHub.connect(nonOwner).executeAutomation(vaultAddress, 0);

      const recipientBalAfter = await mockToken.balanceOf(recipient.address);
      expect(recipientBalAfter - recipientBalBefore).to.equal(EXECUTE_AMOUNT);
    });

    it("Automation respects maxExecutions limit", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 2, "auto-3");

      await executorHub.connect(deployer).addExecutor(executor.address);

      // First execution
      await executorHub.connect(executor).executeAutomation(vaultAddress, 0);

      // Second execution
      await executorHub.connect(executor).executeAutomation(vaultAddress, 0);

      let automation = await vault.getAutomation(0);
      expect(automation.executionCount).to.equal(2);
      expect(automation.status).to.equal(1); // COMPLETED

      // Third execution should revert because automation is now COMPLETED
      await expect(
        executorHub.connect(executor).executeAutomation(vaultAddress, 0)
      ).to.be.revertedWithCustomError(vault, "AutomationNotActive");
    });

    it("Cancelled automation cannot be triggered", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 5, "auto-4");

      await vault.connect(user).cancelAutomation(0);

      // Register executor
      await executorHub.connect(deployer).addExecutor(executor.address);

      // After cancel, the task is removed from ExecutorHub, so executeAutomation
      // will call triggerAutomation on the vault, which reverts AutomationNotActive
      await expect(
        executorHub.connect(executor).executeAutomation(vaultAddress, 0)
      ).to.be.revertedWithCustomError(vault, "AutomationNotActive");
    });

    it("Executor stats update after execution", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 10, "auto-5");

      await executorHub.connect(deployer).addExecutor(executor.address);

      let execInfo = await executorHub.getExecutor(executor.address);
      expect(execInfo.totalExecutions).to.equal(0);
      expect(execInfo.successfulExecutions).to.equal(0);

      // Execute once successfully
      await executorHub.connect(executor).executeAutomation(vaultAddress, 0);

      execInfo = await executorHub.getExecutor(executor.address);
      expect(execInfo.totalExecutions).to.equal(1);
      expect(execInfo.successfulExecutions).to.equal(1);
      expect(execInfo.failedExecutions).to.equal(0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Fee Accrual and Distribution
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Fee Accrual and Distribution", function () {
    beforeEach(async function () {
      await strategyRegistry.registerStrategy(
        await mockAdapter.getAddress(),
        GAS_LIMIT,
        true,
        false,
        false,
        [await mockToken.getAddress()]
      );

      // Create automation for fee distribution tests
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 10, "fee-auto");

      // Register executor (owner adds executor)
      await executorHub.connect(deployer).addExecutor(executor.address);

      // Execute automation so executor has execution stats
      await executorHub.connect(executor).executeAutomation(vaultAddress, 0);
    });

    it("RewardManager distributes fees to executor after automation", async function () {
      // Deploy mock executor hub and wire it up
      const MockExecutorHubFactory = await ethers.getContractFactory("MockExecutorHub");
      mockExecutorHub = await MockExecutorHubFactory.deploy();
      await mockExecutorHub.waitForDeployment();
      await rewardManager.setExecutorHub(await mockExecutorHub.getAddress());

      const baseReward = ethers.parseEther("0.01");
      const gasUsed = 100000;

      const executorBalBefore = await ethers.provider.getBalance(executor.address);

      await mockExecutorHub.callDistributeReward(
        await rewardManager.getAddress(),
        vaultAddress,
        executor.address,
        baseReward,
        gasUsed
      );

      const executorBalAfter = await ethers.provider.getBalance(executor.address);
      expect(executorBalAfter).to.be.gt(executorBalBefore);
    });

    it("Platform fees accumulate in RewardManager", async function () {
      const MockExecutorHubFactory = await ethers.getContractFactory("MockExecutorHub");
      mockExecutorHub = await MockExecutorHubFactory.deploy();
      await mockExecutorHub.waitForDeployment();
      await rewardManager.setExecutorHub(await mockExecutorHub.getAddress());

      const baseReward = ethers.parseEther("0.01");
      const gasUsed = 100000;

      const feesBefore = await rewardManager.totalFeesCollected();

      await mockExecutorHub.callDistributeReward(
        await rewardManager.getAddress(),
        vaultAddress,
        executor.address,
        baseReward,
        gasUsed
      );

      const feesAfter = await rewardManager.totalFeesCollected();
      expect(feesAfter).to.be.gt(feesBefore);

      // Platform fee should be 1% of baseReward (default 100 bps)
      const expectedPlatformFee = (baseReward * 100n) / 10000n;
      expect(feesAfter - feesBefore).to.equal(expectedPlatformFee);
    });

    it("Owner can collect accumulated platform fees", async function () {
      const MockExecutorHubFactory = await ethers.getContractFactory("MockExecutorHub");
      mockExecutorHub = await MockExecutorHubFactory.deploy();
      await mockExecutorHub.waitForDeployment();
      await rewardManager.setExecutorHub(await mockExecutorHub.getAddress());

      const baseReward = ethers.parseEther("0.01");
      await mockExecutorHub.callDistributeReward(
        await rewardManager.getAddress(),
        vaultAddress,
        executor.address,
        baseReward,
        100000
      );

      const feesAccumulated = await rewardManager.totalFeesCollected();
      expect(feesAccumulated).to.be.gt(0);

      const deployerBalBefore = await ethers.provider.getBalance(deployer.address);

      await expect(
        rewardManager.collectFees(deployer.address)
      )
        .to.emit(rewardManager, "PlatformFeeCollected")
        .withArgs(deployer.address, feesAccumulated);

      expect(await rewardManager.totalFeesCollected()).to.equal(0);

      const deployerBalAfter = await ethers.provider.getBalance(deployer.address);
      expect(deployerBalAfter).to.be.gt(deployerBalBefore);
    });

    it("Reward calculation returns base multiplier for all executors", async function () {
      await rewardManager.setExecutorHub(await executorHub.getAddress());

      const baseReward = ethers.parseEther("0.01");
      const gasUsed = 100000;

      // In the current simplified RewardManager, getReputationMultiplier returns BASIS_POINTS (10000)
      // for all executors regardless of execution history
      const execInfo = await executorHub.getExecutor(executor.address);
      expect(execInfo.totalExecutions).to.be.gte(1); // from beforeEach execution

      const calc = await rewardManager.calculateReward(
        baseReward,
        executor.address,
        gasUsed
      );

      // With base multiplier (10000 = 100%), executorReward equals baseReward
      expect(calc.executorReward).to.equal(baseReward);

      // Verify multiplier is exactly BASIS_POINTS (flat rate)
      const multiplier = (calc.executorReward * 10000n) / baseReward;
      expect(multiplier).to.equal(10000);
    });
  });
});
