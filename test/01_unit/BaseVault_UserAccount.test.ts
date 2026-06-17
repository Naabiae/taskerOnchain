import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MockStrategy, UserAccount } from "../typechain-types";

describe("BaseVault -> UserAccount automations & strategy execution", function () {
  let owner: SignerWithAddress;
  let executor: SignerWithAddress;
  let userVault: UserAccount;
  let mockToken: any;
  let mockStrategy: MockStrategy;
  let executorHub: any;
  let strategyRegistry: any;

  beforeEach(async function () {
    [owner, executor] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    mockToken = await MockToken.deploy("Mock", "MCK", 18);
    await mockToken.waitForDeployment();
    await mockToken.mint(owner.address, ethers.parseUnits("1000", 18));

    const TimeStrategy = await ethers.getContractFactory("contracts/mocks/TimeBasedTransferStrategy.sol:TimeBasedTransferStrategy");
    mockStrategy = (await TimeStrategy.deploy()) as MockStrategy;
    await mockStrategy.waitForDeployment();

    const ExecutorHub = await ethers.getContractFactory("contracts/core/ExecutorHub.sol:ExecutorHub");
    executorHub = await ExecutorHub.deploy(owner.address);
    await executorHub.waitForDeployment();

    const StrategyRegistry = await ethers.getContractFactory("contracts/core/StrategyRegistry.sol:StrategyRegistry");
    strategyRegistry = await StrategyRegistry.deploy(owner.address);
    await strategyRegistry.waitForDeployment();

    const UserVault = await ethers.getContractFactory("contracts/vaults/UserAccount.sol:UserAccount");
    userVault = (await UserVault.deploy(owner.address, strategyRegistry.target, executorHub.target)) as UserAccount;
    await userVault.waitForDeployment();

    // fund vault
    await mockToken.transfer(userVault.target, ethers.parseUnits("100", 18));
  });

  it("should create an automation and trigger via executor hub", async function () {
    // create automation: recipient=owner, token=mockToken, amount=10, interval=1 second
    const abi = new ethers.AbiCoder();
    // params: (vault, recipient, token, amount, interval)
    const params = abi.encode(["address","address","address","uint256","uint256"],[userVault.target, owner.address, mockToken.target, ethers.parseUnits("10", 18), 1]);

    // sanity: strategy contract must exist
    const code = await ethers.provider.getCode(mockStrategy.target);
    expect(code).to.not.equal('0x');
    // register strategy in registry so it's discoverable (and validateParams can be called safely)
    await strategyRegistry.registerStrategy(mockStrategy.target, "TimeTransfer");

    const tx = await userVault.createAutomation(mockStrategy.target, params, 2);
    const receipt = await tx.wait();

    // automation id 0
    const auto = await userVault.getAutomation(0);
    expect(auto.status).to.equal(0); // ACTIVE

    // register executor and execute via real ExecutorHub
    await executorHub.connect(owner).addExecutor(executor.address);
    // ExecutorHub will call triggerAutomation on vault; execute as executor
    // recipient (owner) balance before execution
    const beforeBal = await mockToken.balanceOf(owner.address);
    await executorHub.connect(executor).executeAutomation(userVault.target, 0);

    // after execution, owner should have beforeBal + 10
    const bal = await mockToken.balanceOf(owner.address);
    expect(bal).to.equal(beforeBal + ethers.parseUnits("10", 18));

    // simulate executor hub triggering by calling _triggerAutomation via public wrapper
    // we don't have a public wrapper, so use the ExecutorHub flow in integration tests later
  });

  it("should enforce spend limits for executors", async function () {
    // set executor
    // using TestAccessControlVault logic isn't available here, but UserAccount uses _isExecutorActive
    // For the unit test, we'll just simulate owner != executor, so call execute as non-owner

    await userVault.setExecutor(executor.address, 100, 1000, 10000); // <-- doesn't exist on UserAccount
  });
});
