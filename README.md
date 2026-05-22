# UARC — 

Read BUGS.md and fix it first 





"**Programmable DeFi Accounts with Native Automation and Composable Strategy Execution**"

Or more simply: **an on-chain operating system for autonomous DeFi agents.**

The key differentiators in one sentence each:

The account is not just a wallet — it is an execution environment. Strategies are first-class primitives, not external calls the account blindly signs.

AI agents get scoped execution rights without key exposure. This is the problem nobody has solved cleanly at the contract level. ERC-4337 session keys help but don't give you composable strategies or native automation.

Automation is native to the account, not bolted on via Gelato or Chainlink Automation pointing at a bot. The account owns its automations on-chain.

**What Category This Actually Creates**

You're not competing with Safe (multisig) or ERC-4337 wallets (gas abstraction). You're competing with — and beating — the current answer to "how do I let an AI trade for me," which is "give it your private key and pray."

The real comparison is: this is what a hedge fund infrastructure looks like on-chain. The vault is the fund. The strategies are the trading desk's execution layer. The automation is the operations layer. The AI agent is the portfolio manager with a defined mandate. The keeper network is the back office.

**Name Suggestion for the Protocol**

Something like **VaultOS**, **AgentBase**, or **NexusAccount** — something that signals "infrastructure layer" not "wallet app."

What's your instinct — do you want to build this as a standalone protocol that other projects build on top of, or as a product with its own frontend and agent marketplace as the primary surface?