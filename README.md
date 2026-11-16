# EA-BOT

**A collection of MetaTrader 5 Expert Advisors and indicators written in MQL5.**

This repository brings together trading-system experiments and technical-analysis tools, including work around price action, market structure, session behaviour and strategy-based automation.

## Repository contents

The current repository includes MQL5 source files such as:

- `Blueprint_EA.mq5`
- `ICT_SilverBullet_EA.mq5`
- `LFT.mq5`
- `MTF,indic & sessions.mq5`
- `PriceAction_EA.mq5`
- `SMC_EA.mq5`

Review the source files for the exact logic, inputs and supported instruments for each tool.

## Technology

- MQL5
- MetaTrader 5
- Strategy testing and parameter evaluation

## Working with the code

1. Install MetaTrader 5 and open MetaEditor.
2. Clone or download this repository.
3. Open the required `.mq5` file in MetaEditor.
4. Compile and resolve any environment-specific issues.
5. Use the Strategy Tester and a demo environment to evaluate behaviour before considering any live use.

## Risk and testing

Automated trading systems can behave differently across symbols, brokers, spreads, execution conditions and market regimes. Backtests do not guarantee future results.

- Test with historical data and realistic transaction costs.
- Validate position sizing and protective order behaviour.
- Check for duplicate orders and unexpected trade states.
- Use demo testing before any live deployment.
- Never interpret an EA's presence in this repository as evidence of profitability.

## Author

**Babs Ahmed** · [GitHub](https://github.com/babzin) · [LinkedIn](https://www.linkedin.com/in/babs-ahmed-581b5a270) · [X](https://x.com/Saintbabz)
