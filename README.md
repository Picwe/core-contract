🌉 Picwe Cross-Chain Trade Auction System

This system consists of 3 core smart contracts:

1. 🤝 Client Contract
   
Location: Source Chain

Purpose:
- Handles customer interactions.
- Manages order processing on the source chain.
- Interacts with the WeUSD contract for fund management.

2. 🔨 Auction Contract
   
Location: Target Chain

Purpose:
- Facilitates the auctioning of customer orders.
- Manages interactions with agents/bidders.
- Interacts with the WeUSD contract for fund management.

3. 💰 WeUSD Contract
   
Location: Both Source and Target Chains

Purpose:
- Manages the WeUSD stablecoin for cross-chain fund transfers.
- Ensures balanced liquidity across different chains.
- Facilitates atomic cross-chain transfers of WeUSD.
- Integrates with the Client and Auction contracts for seamless fund management.
