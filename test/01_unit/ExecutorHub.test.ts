import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { ExecutorHub } from "../typechain-types";

describe("ExecutorHub", function () {
  let executorHub: ExecutorHub;
  let owner: SignerWithAddress;
  let executor1: SignerWithAddress;
  let executor2: SignerWithAddress;
  let nonExecutor: SignerWithAddress;
  let vault: SignerWithAddress;

  beforeEach(async function () {
    [owner, executor1, executor2, nonExecutor, vault] = await ethers.getSigners();

    const ExecutorHub = await ethers.getContractFactory("contracts/core/ExecutorHub.sol:ExecutorHub");
    executorHub = (await ExecutorHub.deploy(owner.address)) as ExecutorHub;
    await executorHub.waitForDeployment();
  });

  describe("Executor Management", function () {
    it("should add executor", async function () {
      await executorHub.addExecutor(executor1.address);
      
      const executor = await executorHub.executors(executor1.address);
      expect(executor.isActive).to.be.true;
      expect(executor.totalExecutions).to.equal(0);
    });

    it("should reject duplicate executor", async function () {
      await executorHub.addExecutor(executor1.address);
      
      await expect(
        executorHub.addExecutor(executor1.address)
      ).to.be.revertedWithCustomError(executorHub, "AlreadyExecutor");
    });

    it("should deactivate executor", async function () {
      await executorHub.addExecutor(executor1.address);
      await executorHub.removeExecutor(executor1.address);
      
      const executor = await executorHub.executors(executor1.address);
      expect(executor.isActive).to.be.false;
    });

    it("should get all executors", async function () {
      await executorHub.addExecutor(executor1.address);
      await executorHub.addExecutor(executor2.address);
      
      const list = await executorHub.executorList(0);
      expect(list).to.equal(executor1.address);
    });

    it("should only allow owner to add executor", async function () {
      await expect(
        executorHub.connect(nonExecutor).addExecutor(executor1.address)
      ).to.be.revertedWithCustomError(executorHub, "OwnableUnauthorizedAccount");
    });
  });

  describe("Task Registration", function () {
    beforeEach(async function () {
      await executorHub.addExecutor(executor1.address);
    });

    it("should register automation task", async function () {
      // registerTask is called from vault (msg.sender = vault)
      await expect(executorHub.connect(vault).registerTask(1, executor1.address, "0x"))
        .to.emit(executorHub, "TaskRegistered");
    });

    it("should reject duplicate task registration", async function () {
      await executorHub.connect(vault).registerTask(1, executor1.address, "0x");
      
      await expect(
        executorHub.connect(vault).registerTask(1, executor1.address, "0x")
      ).to.be.revertedWithCustomError(executorHub, "TaskAlreadyRegistered");
    });

    it("should deactivate task", async function () {
      await executorHub.connect(vault).registerTask(1, executor1.address, "0x");
      
      // Should not revert
      await expect(executorHub.connect(vault).removeTask(1))
        .to.emit(executorHub, "TaskRemoved");
    });

    it("should reject non-existent task removal", async function () {
      await expect(
        executorHub.connect(vault).removeTask(999)
      ).to.be.revertedWithCustomError(executorHub, "TaskNotFound");
    });
  });

  describe("Executor Stats", function () {
    beforeEach(async function () {
      await executorHub.addExecutor(executor1.address);
    });

    it("should track execution stats", async function () {
      let executor = await executorHub.executors(executor1.address);
      expect(executor.totalExecutions).to.equal(0);
      expect(executor.successfulExecutions).to.equal(0);
      expect(executor.failedExecutions).to.equal(0);
    });
  });

  describe("Events", function () {
    it("should emit ExecutorAdded event", async function () {
      await expect(executorHub.addExecutor(executor1.address))
        .to.emit(executorHub, "ExecutorAdded")
        .withArgs(executor1.address);
    });

    it("should emit ExecutorRemoved event", async function () {
      await executorHub.addExecutor(executor1.address);
      
      await expect(executorHub.removeExecutor(executor1.address))
        .to.emit(executorHub, "ExecutorRemoved")
        .withArgs(executor1.address);
    });

    it("should emit TaskRegistered event", async function () {
      await executorHub.addExecutor(executor1.address);
      
      await expect(executorHub.connect(vault).registerTask(1, executor1.address, "0x"))
        .to.emit(executorHub, "TaskRegistered");
    });
  });
});
