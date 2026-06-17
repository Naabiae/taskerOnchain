import { expect } from "chai";
import { ethers } from "hardhat";
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

describe("ExecutorHub", function () {
  let deployer: SignerWithAddress;
  let user: SignerWithAddress;
  let executor: SignerWithAddress;
  let nonExecutor: SignerWithAddress;
  let recipient: SignerWithAddress;
  let user2: SignerWithAddress;

  // Core contracts
  let mockToken: MockERC20;
  let mockAdapter: MockStrategyAdapter;
  let strategyRegistry: StrategyRegistry;
  let executorHub: ExecutorHub;
  let rewardManager: RewardManager;
  let vaultFactory: UserVaultFactory;
  let vaultImpl: UserVault;

  // Per-user vault instances
  let vault: UserVault;
  let vaultAddress: string;
  let vault2: UserVault;
  let vault2Address: string;

  // Constants
  const TOKEN_DECIMALS = 6;
  const INITIAL_TOKEN_BALANCE = ethers.parseUnits("10000", TOKEN_DECIMALS);
  const INITIAL_ETH_BALANCE = ethers.parseEther("10");
  const EXECUTE_AMOUNT = ethers.parseUnits("100", TOKEN_DECIMALS);
  const GAS_LIMIT = 300000;

  // Helper: build strategy params for MockStrategyAdapter
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
    [deployer, user, executor, nonExecutor, recipient, user2] =
      await ethers.getSigners();

    // ── Deploy MockERC20 ──
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20Factory.deploy("Mock USD", "mUSD", TOKEN_DECIMALS);
    await mockToken.waitForDeployment();

    // ── Deploy vault implementation ──
    const VaultFactory = await ethers.getContractFactory("UserVault");
    vaultImpl = await VaultFactory.deploy();
    await vaultImpl.waitForDeployment();

    // ── Deploy StrategyRegistry ──
    const StrategyRegistryFactory = await ethers.getContractFactory("StrategyRegistry");
    strategyRegistry = await StrategyRegistryFactory.deploy(deployer.address);
    await strategyRegistry.waitForDeployment();

    // ── Deploy ExecutorHub ──
    const ExecutorHubFactory = await ethers.getContractFactory("ExecutorHub");
    executorHub = await ExecutorHubFactory.deploy(deployer.address);
    await executorHub.waitForDeployment();

    // ── Deploy RewardManager ──
    const RewardManagerFactory = await ethers.getContractFactory("RewardManager");
    rewardManager = await RewardManagerFactory.deploy(deployer.address);
    await rewardManager.waitForDeployment();

    // ── Wire RewardManager ↔ ExecutorHub ──
    await rewardManager.setExecutorHub(await executorHub.getAddress());
    await executorHub.setRewardManager(await rewardManager.getAddress());

    // ── Deploy UserVaultFactory ──
    const VaultFactoryFactory = await ethers.getContractFactory("UserVaultFactory");
    vaultFactory = await VaultFactoryFactory.deploy(
      await vaultImpl.getAddress(),
      await strategyRegistry.getAddress(),
      await executorHub.getAddress(),
      deployer.address
    );
    await vaultFactory.waitForDeployment();

    // ── Deploy MockStrategyAdapter ──
    const MockStrategyAdapterFactory = await ethers.getContractFactory("MockStrategyAdapter");
    mockAdapter = await MockStrategyAdapterFactory.deploy();
    await mockAdapter.waitForDeployment();

    // ── Register strategy ──
    await strategyRegistry.registerStrategy(
      await mockAdapter.getAddress(),
      GAS_LIMIT,
      true,
      false,
      false,
      [await mockToken.getAddress()]
    );

    // ── Create vault for user ──
    await vaultFactory.connect(user).createVault();
    vaultAddress = await vaultFactory.getVault(user.address);
    vault = await ethers.getContractAt("UserVault", vaultAddress);

    // ── Create vault for user2 ──
    await vaultFactory.connect(user2).createVault();
    vault2Address = await vaultFactory.getVault(user2.address);
    vault2 = await ethers.getContractAt("UserVault", vault2Address);

    // ── Fund vaults with tokens (mint directly to vault address) ──
    await mockToken.mint(vaultAddress, INITIAL_TOKEN_BALANCE);
    await mockToken.mint(vault2Address, INITIAL_TOKEN_BALANCE);

    // ── Fund vaults with ETH (send directly) ──
    await deployer.sendTransaction({
      to: vaultAddress,
      value: INITIAL_ETH_BALANCE,
    });
    await deployer.sendTransaction({
      to: vault2Address,
      value: INITIAL_ETH_BALANCE,
    });

    // ── Set RewardManager on vaults ──
    await vault.connect(user).setRewardManager(await rewardManager.getAddress());
    await vault2.connect(user2).setRewardManager(await rewardManager.getAddress());

    // ── Add executor ──
    await executorHub.addExecutor(executor.address);
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Task Registration
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Task Registration", function () {
    it("task is registered in ExecutorHub when automation is created on vault", async function () {
      const countBefore = await executorHub.getTaskCount();

      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 5, "test-auto");

      const countAfter = await executorHub.getTaskCount();
      expect(countAfter).to.equal(countBefore + 1n);
    });

    it("getTasks returns the registered task with correct data", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const tx = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 10, "data-check");

      // Find the automationId from event
      const receipt = await tx.wait();
      const createdEvent = receipt!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog = vault.interface.parseLog(createdEvent!);
      const automationId = parsedLog!.args[0];

      const tasks = await executorHub.getTasks();
      const task = tasks[tasks.length - 1];

      expect(task.vault).to.equal(vaultAddress);
      expect(task.automationId).to.equal(automationId);
      expect(task.strategy).to.equal(await mockAdapter.getAddress());
      expect(task.active).to.be.true;
    });

    it("getTasksByVault filters correctly", async function () {
      // user2's vault should have no tasks yet
      let tasksForVault2 = await executorHub.getTasksByVault(vault2Address);
      expect(tasksForVault2.length).to.equal(0);

      // Create an automation on user2's vault
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      await vault2
        .connect(user2)
        .createAutomation(await mockAdapter.getAddress(), params, 3, "vault2-auto");

      tasksForVault2 = await executorHub.getTasksByVault(vault2Address);
      expect(tasksForVault2.length).to.equal(1);
      expect(tasksForVault2[0].vault).to.equal(vault2Address);

      // user1's vault should still have its own tasks
      const tasksForVault1 = await executorHub.getTasksByVault(vaultAddress);
      expect(tasksForVault1.length).to.be.greaterThan(0);
      for (const t of tasksForVault1) {
        expect(t.vault).to.equal(vaultAddress);
      }
    });

    it("task is removed from ExecutorHub when automation is cancelled", async function () {
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const tx = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 5, "cancel-test");

      const receipt = await tx.wait();
      const createdEvent = receipt!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog = vault.interface.parseLog(createdEvent!);
      const automationId = parsedLog!.args[0];

      const countBefore = await executorHub.getTaskCount();

      // Cancel the automation
      await vault.connect(user).cancelAutomation(automationId);

      const countAfter = await executorHub.getTaskCount();
      expect(countAfter).to.equal(countBefore - 1n);

      // Verify the task is gone from getTasksByVault
      const tasks = await executorHub.getTasksByVault(vaultAddress);
      const found = tasks.find((t: any) => t.automationId === automationId);
      expect(found).to.be.undefined;
    });

    it("getTaskCount reflects registrations and removals", async function () {
      const initialCount = await executorHub.getTaskCount();

      // Create two automations
      const params1 = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const params2 = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT * 2n,
        recipient.address
      );

      const tx1 = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params1, 5, "count-a");
      const tx2 = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params2, 5, "count-b");

      const afterCreate = await executorHub.getTaskCount();
      expect(afterCreate).to.equal(initialCount + 2n);

      // Cancel first automation
      const receipt1 = await tx1.wait();
      const createdEvent1 = receipt1!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog1 = vault.interface.parseLog(createdEvent1!);
      const automationId1 = parsedLog1!.args[0];

      await vault.connect(user).cancelAutomation(automationId1);

      const afterCancel = await executorHub.getTaskCount();
      expect(afterCancel).to.equal(initialCount + 1n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // canExecute
  // ═══════════════════════════════════════════════════════════════════════════

  describe("canExecute", function () {
    let canExecAutomationId: bigint;

    beforeEach(async function () {
      // Create a fresh automation for canExecute tests
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const tx = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 10, "canexec-test");

      const receipt = await tx.wait();
      const createdEvent = receipt!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog = vault.interface.parseLog(createdEvent!);
      canExecAutomationId = parsedLog!.args[0];

      // Ensure canExecute is true by default
      await mockAdapter.setCanExecute(true, "");
    });

    it("returns true when strategy adapter conditions are met", async function () {
      await mockAdapter.setCanExecute(true, "");
      const [canExec, reason] = await executorHub.canExecute(vaultAddress, canExecAutomationId);
      expect(canExec).to.be.true;
      expect(reason).to.equal("");
    });

    it("returns false when strategy adapter conditions are not met", async function () {
      await mockAdapter.setCanExecute(false, "Price not reached");
      const [canExec, reason] = await executorHub.canExecute(vaultAddress, canExecAutomationId);
      expect(canExec).to.be.false;
      expect(reason).to.equal("Price not reached");
    });

    it("returns false for non-existent task", async function () {
      // Use an automationId that was never registered or was removed
      await mockAdapter.setCanExecute(true, "");

      const [canExec, reason] = await executorHub.canExecute(vaultAddress, 99999n);
      expect(canExec).to.be.false;
      expect(reason).to.equal("Task not active");
    });

    it("returns false for a cancelled/removed task", async function () {
      await mockAdapter.setCanExecute(true, "");

      // Cancel the automation (which removes the task)
      await vault.connect(user).cancelAutomation(canExecAutomationId);

      const [canExec, reason] = await executorHub.canExecute(vaultAddress, canExecAutomationId);
      expect(canExec).to.be.false;
      expect(reason).to.equal("Task not active");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Task Execution
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Task Execution", function () {
    let execAutomationId: bigint;

    beforeEach(async function () {
      // Ensure canExecute returns true
      await mockAdapter.setCanExecute(true, "");

      // Create a fresh automation for each execution test
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const tx = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 10, "exec-test");

      const receipt = await tx.wait();
      const createdEvent = receipt!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog = vault.interface.parseLog(createdEvent!);
      execAutomationId = parsedLog!.args[0];
    });

    it("active executor can execute automation via ExecutorHub", async function () {
      const recipientBalBefore = await mockToken.balanceOf(recipient.address);

      await executorHub
        .connect(executor)
        .executeAutomation(vaultAddress, execAutomationId);

      const recipientBalAfter = await mockToken.balanceOf(recipient.address);
      expect(recipientBalAfter - recipientBalBefore).to.equal(EXECUTE_AMOUNT);

      // Verify automation execution count increased
      const automation = await vault.getAutomation(execAutomationId);
      expect(automation.executionCount).to.equal(1n);
    });

    it("non-executor cannot execute automation", async function () {
      await expect(
        executorHub
          .connect(nonExecutor)
          .executeAutomation(vaultAddress, execAutomationId)
      ).to.be.revertedWithCustomError(executorHub, "NotExecutor");
    });

    it("executor stats are updated after execution", async function () {
      const execBefore = await executorHub.getExecutor(executor.address);
      const totalBefore = execBefore.totalExecutions;
      const successBefore = execBefore.successfulExecutions;

      await executorHub
        .connect(executor)
        .executeAutomation(vaultAddress, execAutomationId);

      const execAfter = await executorHub.getExecutor(executor.address);
      expect(execAfter.totalExecutions).to.equal(totalBefore + 1n);
      expect(execAfter.successfulExecutions).to.equal(successBefore + 1n);
    });

    it("task is removed after automation reaches maxExecutions", async function () {
      // Create an automation with maxExecutions = 1
      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const tx = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 1, "max-exec-test");

      const receipt = await tx.wait();
      const createdEvent = receipt!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog = vault.interface.parseLog(createdEvent!);
      const maxExecAutomationId = parsedLog!.args[0];

      const countBefore = await executorHub.getTaskCount();

      // Execute once — this should hit maxExecutions and auto-remove
      await executorHub
        .connect(executor)
        .executeAutomation(vaultAddress, maxExecAutomationId);

      // Task should be removed from ExecutorHub
      const countAfter = await executorHub.getTaskCount();
      expect(countAfter).to.equal(countBefore - 1n);

      // canExecute should return false for the removed task
      const [canExec, reason] = await executorHub.canExecute(vaultAddress, maxExecAutomationId);
      expect(canExec).to.be.false;
      expect(reason).to.equal("Task not active");

      // Automation status should be COMPLETED on the vault
      const automation = await vault.getAutomation(maxExecAutomationId);
      // AutomationStatus.COMPLETED = 1
      expect(automation.status).to.equal(1n);
    });

    it("getExecutableTasks returns only tasks where canExecute is true", async function () {
      // Set canExecute to true
      await mockAdapter.setCanExecute(true, "");

      let executableTasks = await executorHub.getExecutableTasks();
      const countWhenTrue = executableTasks.length;
      expect(countWhenTrue).to.be.greaterThan(0);

      // Now set canExecute to false
      await mockAdapter.setCanExecute(false, "Conditions not met");

      executableTasks = await executorHub.getExecutableTasks();
      expect(executableTasks.length).to.equal(0);

      // Reset for subsequent tests
      await mockAdapter.setCanExecute(true, "");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Executor Management
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Executor Management", function () {
    it("owner can add an executor", async function () {
      // Use a fresh address that hasn't been added yet
      const newExec = (await ethers.getSigners())[7];
      await expect(executorHub.addExecutor(newExec.address))
        .to.emit(executorHub, "ExecutorAdded")
        .withArgs(newExec.address);

      expect(await executorHub.isExecutor(newExec.address)).to.be.true;
    });

    it("owner can remove an executor", async function () {
      // Add a fresh executor then remove
      const newExec = (await ethers.getSigners())[8];
      await executorHub.addExecutor(newExec.address);

      await expect(executorHub.removeExecutor(newExec.address))
        .to.emit(executorHub, "ExecutorRemoved")
        .withArgs(newExec.address);

      expect(await executorHub.isExecutor(newExec.address)).to.be.false;
    });

    it("cannot add executor twice", async function () {
      const newExec = (await ethers.getSigners())[9];
      await executorHub.addExecutor(newExec.address);
      await expect(
        executorHub.addExecutor(newExec.address)
      ).to.be.revertedWithCustomError(executorHub, "AlreadyExecutor");
    });

    it("cannot remove non-existent executor", async function () {
      await expect(
        executorHub.removeExecutor(nonExecutor.address)
      ).to.be.revertedWithCustomError(executorHub, "NotActiveExecutor");
    });

    it("non-owner cannot add executor", async function () {
      const newExec = (await ethers.getSigners())[10];
      await expect(
        executorHub.connect(nonExecutor).addExecutor(newExec.address)
      ).to.be.revertedWithCustomError(executorHub, "OwnableUnauthorizedAccount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Task Update
  // ═══════════════════════════════════════════════════════════════════════════

  describe("Task Update", function () {
    it("vault can update task params via updateAutomation", async function () {
      await mockAdapter.setCanExecute(true, "");

      const params = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT,
        recipient.address
      );
      const tx = await vault
        .connect(user)
        .createAutomation(await mockAdapter.getAddress(), params, 5, "update-test");

      const receipt = await tx.wait();
      const createdEvent = receipt!.logs.find(
        (log: any) => {
          try {
            const parsed = vault.interface.parseLog(log);
            return parsed?.name === "AutomationCreated";
          } catch { return false; }
        }
      );
      const parsedLog = vault.interface.parseLog(createdEvent!);
      const automationId = parsedLog!.args[0];

      const newParams = buildParams(
        await mockToken.getAddress(),
        EXECUTE_AMOUNT * 2n,
        recipient.address
      );

      await vault.connect(user).updateAutomation(automationId, newParams);

      // Verify params were updated in ExecutorHub
      const tasks = await executorHub.getTasksByVault(vaultAddress);
      const updatedTask = tasks.find((t: any) => t.automationId === automationId);
      expect(updatedTask).to.not.be.undefined;
    });
  });
});
