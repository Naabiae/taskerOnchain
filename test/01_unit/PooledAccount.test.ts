import { expect } from "chai";
import { ethers } from "hardhat";

describe("PooledAccount automations & manager execution", function () {
  let deployer, manager, executor, recipient;
  let mockToken: any;
  let timeStrategy: any;
  let executorHub: any;
  let strategyRegistry: any;
  let pooled: any;

  beforeEach(async function () {
    [deployer, manager, executor, recipient] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    mockToken = await MockToken.deploy("Mock", "MCK", 18);
    await mockToken.waitForDeployment();
    await mockToken.mint(deployer.address, ethers.parseUnits("10000", 18));

    const TimeStrategy = await ethers.getContractFactory("contracts/mocks/TimeBasedTransferStrategy.sol:TimeBasedTransferStrategy");
    timeStrategy = await TimeStrategy.deploy();
    await timeStrategy.waitForDeployment();

    const ExecutorHub = await ethers.getContractFactory("contracts/core/ExecutorHub.sol:ExecutorHub");
    executorHub = await ExecutorHub.deploy(deployer.address);
    await executorHub.waitForDeployment();

    const StrategyRegistry = await ethers.getContractFactory("contracts/core/StrategyRegistry.sol:StrategyRegistry");
    strategyRegistry = await StrategyRegistry.deploy(deployer.address);
    await strategyRegistry.waitForDeployment();

    const Pooled = await ethers.getContractFactory("contracts/vaults/PooledAccount.sol:PooledAccount");
    pooled = await Pooled.deploy(mockToken.target, manager.address, strategyRegistry.target, executorHub.target);
    await pooled.waitForDeployment();

    // fund pooled account
    await mockToken.transfer(pooled.target, ethers.parseUnits("1000", 18));

    // register strategy
    await strategyRegistry.connect(deployer).registerStrategy(timeStrategy.target, "TimeTransfer");
  });

  it("manager can create automation and executor hub can trigger it", async function () {
    // params: (vault, recipient, token, amount, interval)
    const abi = new ethers.AbiCoder();
    const params = abi.encode(["address","address","address","uint256","uint256"],[pooled.target, recipient.address, mockToken.target, ethers.parseUnits("50", 18), 1]);

    // manager creates automation
    await pooled.connect(manager).createAutomation(timeStrategy.target, params, 1);

    const auto = await pooled.getAutomation(0);
    expect(auto.status).to.equal(0); // ACTIVE

    // add executor and execute via real ExecutorHub
    await executorHub.connect(deployer).addExecutor(executor.address);
    await executorHub.connect(executor).executeAutomation(pooled.target, 0);

    // recipient should have received 50 tokens
    const bal = await mockToken.balanceOf(recipient.address);
    expect(bal).to.equal(ethers.parseUnits("50", 18));

    // automation should be completed (maxExecutions=1)
    const autoAfter = await pooled.getAutomation(0);
    expect(autoAfter.status).to.equal(1); // COMPLETED
  });
});
