import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TestAccessControlVault } from "../typechain-types";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("AccessControlModule (via TestAccessControlVault)", function () {
  let accessControl: TestAccessControlVault;
  let owner: SignerWithAddress;
  let executor1: SignerWithAddress;
  let executor2: SignerWithAddress;

  beforeEach(async function () {
    [owner, executor1, executor2] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("contracts/TestAccessControlVault.sol:TestAccessControlVault");
    accessControl = (await Factory.deploy(owner.address)) as TestAccessControlVault;
    await accessControl.waitForDeployment();
  });

  describe("Executor Management", function () {
    it("should add executor with spending limits", async function () {
      await accessControl.setExecutor(executor1.address, 100, 500, 1000);

      const role = await accessControl.getExecutorInfo(executor1.address);
      expect(role.active).to.be.true;
      expect(role.maxPerExecution).to.equal(100);
      expect(role.maxPerDay).to.equal(500);
      expect(role.maxTotal).to.equal(1000);
      expect(role.spentToday).to.equal(0);
      expect(role.spentTotal).to.equal(0);
    });

    it("should reject zero-address executor", async function () {
      await expect(
        accessControl.setExecutor(ethers.ZeroAddress, 100, 500, 1000)
      ).to.be.revertedWith("Zero address");
    });

    it("should revoke executor", async function () {
      await accessControl.setExecutor(executor1.address, 100, 500, 1000);
      await accessControl.revokeExecutor(executor1.address);

      const role = await accessControl.getExecutorInfo(executor1.address);
      expect(role.active).to.be.false;
    });

    it("should reject revoking inactive executor", async function () {
      await expect(
        accessControl.revokeExecutor(executor1.address)
      ).to.be.revertedWithCustomError(accessControl, "ExecutorNotActive");
    });
  });

  describe("Spending Limit Enforcement", function () {
    it("should enforce per-execution limit", async function () {
      // per-execution 100, large daily/lifetime so per-execution checks only
      await accessControl.setExecutor(executor1.address, 100, 10000, 10000);
      // verify stored limits
      let r = await accessControl.getExecutorInfo(executor1.address);
      expect(r.maxPerExecution).to.equal(100);

      // Valid: 100 tokens (at limit)
      await accessControl.enforceSpendingLimit(executor1.address, 100);

      // Invalid: 101 tokens (over limit)
      await expect(
        accessControl.enforceSpendingLimit(executor1.address, 101)
      ).to.be.revertedWithCustomError(accessControl, "SpendingLimitExceeded");
    });

    it("should enforce daily limit", async function () {
      // allow large per-execution so we can test daily aggregation
      await accessControl.setExecutor(executor1.address, 1000, 500, 10000);
      let r2 = await accessControl.getExecutorInfo(executor1.address);
      expect(r2.maxPerExecution).to.equal(1000);

      // Spend 400 tokens
      await accessControl.enforceSpendingLimit(executor1.address, 400);

      // Try to spend 200 more (total 600 > daily limit of 500)
      await expect(
        accessControl.enforceSpendingLimit(executor1.address, 200)
      ).to.be.revertedWithCustomError(accessControl, "SpendingLimitExceeded");

      // But spending 100 should work (total 500)
      await accessControl.enforceSpendingLimit(executor1.address, 100);
    });

    it("should enforce lifetime limit", async function () {
      // Set high per-exec and per-day but lifetime 1000
      await accessControl.setExecutor(executor1.address, 1000, 10000, 1000);
      let r3 = await accessControl.getExecutorInfo(executor1.address);
      expect(r3.maxTotal).to.equal(1000);

      // Spend 800 tokens in two calls
      await accessControl.enforceSpendingLimit(executor1.address, 400);
      await accessControl.enforceSpendingLimit(executor1.address, 400);

      let role = await accessControl.getExecutorInfo(executor1.address);
      expect(role.spentTotal).to.equal(800);

      // Try to spend 300 more (total 1100 > limit of 1000)
      await expect(
        accessControl.enforceSpendingLimit(executor1.address, 300)
      ).to.be.revertedWithCustomError(accessControl, "SpendingLimitExceeded");
    });

    it("should reset daily limit after 24 hours", async function () {
      // allow large per-execution so single call can hit daily cap
      await accessControl.setExecutor(executor1.address, 1000, 500, 10000);
      let r4 = await accessControl.getExecutorInfo(executor1.address);
      expect(r4.maxPerDay).to.equal(500);

      // Spend 500 tokens (hits daily limit)
      await accessControl.enforceSpendingLimit(executor1.address, 500);

      // Try to spend 1 more token (should fail)
      await expect(
        accessControl.enforceSpendingLimit(executor1.address, 1)
      ).to.be.revertedWithCustomError(accessControl, "SpendingLimitExceeded");

      // Advance time by 24 hours
      await time.increase(24 * 60 * 60);

      // Now should be able to spend again (daily resets, lifetime still counts)
      await accessControl.enforceSpendingLimit(executor1.address, 100);

      let role = await accessControl.getExecutorInfo(executor1.address);
      expect(role.spentToday).to.equal(100);
      expect(role.spentTotal).to.equal(600); // 500 + 100
    });

    it("should not allow inactive executor", async function () {
      await accessControl.setExecutor(executor1.address, 1000, 10000, 10000);
      await accessControl.revokeExecutor(executor1.address);

      await expect(
        accessControl.enforceSpendingLimit(executor1.address, 10)
      ).to.be.revertedWithCustomError(accessControl, "ExecutorNotActive");
    });
  });

  describe("Multiple Executors", function () {
    it("should track spending independently per executor", async function () {
      // give executor1 a high per-execution limit so they can spend 400 in one call
      await accessControl.setExecutor(executor1.address, 1000, 500, 1000);
      // give executor2 a per-execution equal to their daily cap so a single call can fill it
      await accessControl.setExecutor(executor2.address, 300, 300, 600);

      // Executor1 spends 400
      await accessControl.enforceSpendingLimit(executor1.address, 400);

      // Executor2 spends 300 (their daily limit)
      await accessControl.enforceSpendingLimit(executor2.address, 300);

      // Executor2 should be out of daily budget
      await expect(
        accessControl.enforceSpendingLimit(executor2.address, 1)
      ).to.be.revertedWithCustomError(accessControl, "SpendingLimitExceeded");

      // But executor1 can still spend 100 more (500 daily limit - 400 spent)
      await accessControl.enforceSpendingLimit(executor1.address, 100);
    });
  });
});
