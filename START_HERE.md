# Arbitrum Open House — 3 Week Build

## The Thing
Composable vaults + strategies + keeper network on Arbitrum.

## Why It Wins
- BaseVault (execution engine, shared across all vault types)
- Modules (SingleOwner, ShareAccounting, AIExecution) compose into vault types
- Public Keepers (anyone executes automations, earns rewards)
- Adapters (strategies are pluggable, can chain in one tx)

## Week 1
- BaseVault + SingleOwnerModule → UserVault
- ExecutorHub integrated
- Uniswap + Aave adapters
- Deploy to Sepolia

## Week 2
- ShareVault (BaseVault + ShareAccounting)
- PublicKeeperNetwork (public registration + rewards)
- 3 more adapters (GMX, Curve, Lido)
- Keeper bot executing automations

## Week 3
- Deploy to Arbitrum One
- Keeper bot running live
- Front-end skeleton
- Demo ready

## Start: Implement BaseVault scaffold, then compose UserVault
