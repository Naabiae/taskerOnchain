import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { StrategyRegistry } from "../typechain-types";

describe("StrategyRegistry", function () {
  let strategyRegistry: StrategyRegistry;
  let owner: SignerWithAddress;
  let other: SignerWithAddress;
  let adapter1: SignerWithAddress;
  let adapter2: SignerWithAddress;

  beforeEach(async function () {
    [owner, other, adapter1, adapter2] = await ethers.getSigners();

    const StrategyRegistry = await ethers.getContractFactory("contracts/core/StrategyRegistry.sol:StrategyRegistry");
    strategyRegistry = (await StrategyRegistry.deploy(owner.address)) as StrategyRegistry;
    await strategyRegistry.waitForDeployment();
  });

  describe("Registration", function () {
    it("should register a strategy adapter", async function () {
      await strategyRegistry.registerStrategy(adapter1.address, "SwapAdapter");

      const strategy = await strategyRegistry.getStrategy(adapter1.address);
      expect(strategy.adapter).to.equal(adapter1.address);
      expect(strategy.name).to.equal("SwapAdapter");
      expect(strategy.isActive).to.be.true;
    });

    it("should reject zero-address adapter", async function () {
      await expect(
        strategyRegistry.registerStrategy(ethers.ZeroAddress, "ZeroAdapter")
      ).to.be.revertedWithCustomError(strategyRegistry, "InvalidAdapter");
    });

    it("should allow owner to register multiple strategies", async function () {
      await strategyRegistry.registerStrategy(adapter1.address, "Adapter1");
      await strategyRegistry.registerStrategy(adapter2.address, "Adapter2");

      const count = await strategyRegistry.getStrategyCount();
      expect(count).to.equal(2);
    });

    it("should reject non-owner registration", async function () {
      await expect(
        strategyRegistry.connect(other).registerStrategy(adapter1.address, "Adapter")
      ).to.be.revertedWithCustomError(strategyRegistry, "OwnableUnauthorizedAccount");
    });
  });

  describe("Activation/Deactivation", function () {
    beforeEach(async function () {
      await strategyRegistry.registerStrategy(adapter1.address, "TestAdapter");
    });

    it("should deactivate an active strategy", async function () {
      await strategyRegistry.deactivateStrategy(adapter1.address);
      const strategy = await strategyRegistry.getStrategy(adapter1.address);
      expect(strategy.isActive).to.be.false;
    });

    it("should activate a deactivated strategy", async function () {
      await strategyRegistry.deactivateStrategy(adapter1.address);
      await strategyRegistry.activateStrategy(adapter1.address);

      const strategy = await strategyRegistry.getStrategy(adapter1.address);
      expect(strategy.isActive).to.be.true;
    });

    it("should reject deactivating non-existent strategy", async function () {
      await expect(
        strategyRegistry.deactivateStrategy(adapter2.address)
      ).to.be.revertedWithCustomError(strategyRegistry, "StrategyNotFound");
    });

    it("should only allow owner to deactivate", async function () {
      await expect(
        strategyRegistry.connect(other).deactivateStrategy(adapter1.address)
      ).to.be.revertedWithCustomError(strategyRegistry, "OwnableUnauthorizedAccount");
    });
  });

  describe("Queries", function () {
    beforeEach(async function () {
      await strategyRegistry.registerStrategy(adapter1.address, "Adapter1");
      await strategyRegistry.registerStrategy(adapter2.address, "Adapter2");
      await strategyRegistry.deactivateStrategy(adapter1.address);
    });

    it("should check if strategy is active", async function () {
      const active1 = await strategyRegistry.isStrategyActive(adapter1.address);
      const active2 = await strategyRegistry.isStrategyActive(adapter2.address);

      expect(active1).to.be.false;
      expect(active2).to.be.true;
    });

    it("should get all strategies", async function () {
      const all = await strategyRegistry.getAllStrategies();
      expect(all.length).to.equal(2);
      expect(all).to.include(adapter1.address);
      expect(all).to.include(adapter2.address);
    });

    it("should get total strategy count", async function () {
      const count = await strategyRegistry.getStrategyCount();
      expect(count).to.equal(2);
    });

    it("should get strategy info even if deactivated", async function () {
      const strategy = await strategyRegistry.getStrategy(adapter1.address);
      expect(strategy.adapter).to.equal(adapter1.address);
      expect(strategy.isActive).to.be.false;
    });

    it("should reject getting unregistered strategy", async function () {
      const randomAddr = ethers.getAddress("0x" + "1".repeat(40));
      await expect(
        strategyRegistry.getStrategy(randomAddr)
      ).to.be.revertedWithCustomError(strategyRegistry, "StrategyNotFound");
    });
  });

  describe("Events", function () {
    it("should emit StrategyRegistered event", async function () {
      await expect(strategyRegistry.registerStrategy(adapter1.address, "Test"))
        .to.emit(strategyRegistry, "StrategyRegistered")
        .withArgs(adapter1.address, "Test");
    });

    it("should emit StrategyDeactivated event", async function () {
      await strategyRegistry.registerStrategy(adapter1.address, "Test");

      await expect(strategyRegistry.deactivateStrategy(adapter1.address))
        .to.emit(strategyRegistry, "StrategyDeactivated")
        .withArgs(adapter1.address);
    });

    it("should emit StrategyActivated event", async function () {
      await strategyRegistry.registerStrategy(adapter1.address, "Test");
      await strategyRegistry.deactivateStrategy(adapter1.address);

      await expect(strategyRegistry.activateStrategy(adapter1.address))
        .to.emit(strategyRegistry, "StrategyActivated")
        .withArgs(adapter1.address);
    });
  });
});
