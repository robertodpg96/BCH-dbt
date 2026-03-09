# Bitcoin Cash dbt Project

A [dbt-core](https://docs.getdbt.com/) project that transforms raw Bitcoin Cash blockchain data from the public BigQuery dataset (`bigquery-public-data.crypto_bitcoin_cash`) into analytics-ready staging views and data mart tables on Google BigQuery.

---

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Data Sources](#data-sources)
- [Models](#models)
  - [Staging](#staging)
  - [Data Mart](#data-mart)
- [Data Quality Tests](#data-quality-tests)
- [Schema Design](#schema-design)
- [Prerequisites](#prerequisites)
- [Local Setup](#local-setup)
- [Running dbt](#running-dbt)
- [CI/CD](#cicd)
- [Required Secrets](#required-secrets)

---

## Overview

This project implements a two-layer transformation pipeline:

1. **Staging** — a lightweight view on top of the raw `transactions` table, filtered to the last 90 days to stay within BigQuery's free tier.
2. **Data Mart** — a materialised table that calculates the current BCH balance for every address, excluding addresses associated with coinbase (block reward) transactions.

---

## Project Structure

```
astrafy-dbt/
├── bitcoin_cash/                       # dbt project root
│   ├── .github/
│   │   └── workflows/
│   │       └── dbt_ci.yml              # GitHub Actions CI workflow
│   ├── macros/
│   │   └── generate_schema_name.sql    # Overrides default schema naming
│   ├── models/
│   │   ├── staging/
│   │   │   ├── _sources.yml            # Source declarations with freshness checks
│   │   │   ├── schema.yml              # Staging model documentation and tests
│   │   │   └── stg_bitcoin_cash__transactions.sql
│   │   └── datamarts/
│   │       ├── schema.yml              # Data mart documentation and tests
│   │       └── mart_address_balances.sql
│   ├── dbt_project.yml
│   └── requirements.txt
├── .gitignore
└── README.md
```

---

## Data Sources

| Source | Dataset | Table |
|---|---|---|
| BigQuery public data | `bigquery-public-data.crypto_bitcoin_cash` | `transactions` |

The `transactions` table contains every transaction recorded on the Bitcoin Cash blockchain, with nested `inputs` and `outputs` arrays representing the UTXO (Unspent Transaction Output) model.

Source freshness is monitored automatically — dbt will warn if data is older than 24 hours and error if older than 48 hours.

---

## Models

### Staging

**`stg_bitcoin_cash__transactions`**

- **Materialization:** view
- **Target dataset:** `staging`
- **Source:** `bigquery-public-data.crypto_bitcoin_cash.transactions`

Selects and renames columns from the raw transactions table, filtering to the **last 90 days** only. This ensures all queries remain within BigQuery's free tier on new GCP projects. The lookback window is configurable via the `lookback_days` project variable (default: `90`).

Key columns:

| Column | Type | Description |
|---|---|---|
| `transaction_hash` | STRING | Unique transaction identifier |
| `block_timestamp` | TIMESTAMP | When the block containing this transaction was mined |
| `block_number` | INT64 | Block height |
| `is_coinbase` | BOOL | Whether this is a block reward transaction |
| `input_value_satoshis` | INT64 | Total value of all inputs |
| `output_value_satoshis` | INT64 | Total value of all outputs |
| `fee_satoshis` | INT64 | Miner fee (`input_value - output_value`) |
| `inputs` | ARRAY\<STRUCT\> | Nested input records |
| `outputs` | ARRAY\<STRUCT\> | Nested output records |

---

### Data Mart

**`mart_address_balances`**

- **Materialization:** table
- **Target dataset:** `datamart`
- **Clustering:** `address`
- **Depends on:** `stg_bitcoin_cash__transactions`

Calculates the current BCH balance for every address observed in the last 90 days.

**Balance logic (UTXO model):**

```
balance = Σ output values received  −  Σ input values spent
```

Values are stored both in satoshis and BCH (1 BCH = 100,000,000 satoshis).

**Coinbase exclusion:** addresses that appear as recipients in any coinbase transaction (i.e. miner reward addresses) are excluded from the result set.

The table is clustered by `address` to optimise query performance and reduce BigQuery costs when filtering or joining on address.

Output columns:

| Column | Type | Description |
|---|---|---|
| `address` | STRING | Bitcoin Cash address |
| `total_received_satoshis` | INT64 | Total BCH received across all outputs |
| `total_spent_satoshis` | INT64 | Total BCH spent across all inputs |
| `balance_satoshis` | INT64 | Net balance in satoshis |
| `balance_bch` | FLOAT64 | Net balance in BCH |

---

## Data Quality Tests

All models are covered by dbt tests defined in their respective `schema.yml` files. Tests run automatically in CI after every `dbt run`.

| Model | Column | Tests |
|---|---|---|
| `stg_bitcoin_cash__transactions` | `transaction_hash` | `not_null`, `unique` |
| `stg_bitcoin_cash__transactions` | `block_hash` | `not_null` |
| `stg_bitcoin_cash__transactions` | `block_number` | `not_null` |
| `stg_bitcoin_cash__transactions` | `block_timestamp` | `not_null` |
| `stg_bitcoin_cash__transactions` | `block_timestamp_month` | `not_null` |
| `stg_bitcoin_cash__transactions` | `is_coinbase` | `not_null` |
| `mart_address_balances` | `address` | `not_null`, `unique` |
| `mart_address_balances` | `total_received_satoshis` | `not_null` |
| `mart_address_balances` | `total_spent_satoshis` | `not_null` |
| `mart_address_balances` | `balance_satoshis` | `not_null` |
| `mart_address_balances` | `balance_bch` | `not_null` |

---

## Schema Design

The `macros/generate_schema_name.sql` macro overrides dbt's default schema naming behaviour. Instead of prefixing the target schema to custom schema names (e.g. `bitcoin_cash_staging`), it uses the custom schema name directly:

| Layer | dbt folder | BigQuery dataset |
|---|---|---|
| Staging | `models/staging/` | `staging` |
| Data Mart | `models/datamarts/` | `datamart` |

> These datasets must exist in your GCP project before running dbt. They are provisioned via Terraform in the companion infrastructure repository.

---

## Prerequisites

- Python 3.13+
- A Google Cloud project with BigQuery enabled
- A service account with the following BigQuery roles:
  - `roles/bigquery.dataEditor` — to create and write tables
  - `roles/bigquery.jobUser` — to run queries
- BigQuery datasets `staging` and `datamart` created in your project
- Access to `bigquery-public-data.crypto_bitcoin_cash` (available by default on GCP)

---

## Local Setup

1. **Clone the repository:**

   ```bash
   git clone <repo-url>
   cd astrafy-dbt
   ```

2. **Create and activate a virtual environment:**

   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   ```

3. **Install dependencies:**

   ```bash
   pip install -r bitcoin_cash/requirements.txt
   ```

4. **Configure your profile.**

   Create `~/.dbt/profiles.yml`:

   ```yaml
   bitcoin_cash:
     target: dev
     outputs:
       dev:
         type: bigquery
         method: service-account
         project: "your-gcp-project-id"
         dataset: bitcoin_cash
         threads: 4
         keyfile: /path/to/service-account-key.json
         timeout_seconds: 300
         location: US
   ```

5. **Set environment variables** (if using the env-var-based profile):

   ```bash
   export GCP_PROJECT_ID=your-gcp-project-id
   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account-key.json
   ```

---

## Running dbt

All dbt commands must be run from inside the `bitcoin_cash/` directory:

```bash
cd bitcoin_cash

# Validate your connection
dbt debug

# Parse and validate all models and YAML files
dbt parse

# Compile models without executing
dbt compile

# Run all models
dbt run

# Run data quality tests
dbt test

# Run a specific model and its dependencies
dbt run --select stg_bitcoin_cash__transactions+

# Run only the data mart
dbt run --select mart_address_balances

# Check source data freshness
dbt source freshness

# Override the lookback window (e.g. last 30 days)
dbt run --vars 'lookback_days: 30'
```

---

## CI/CD

A GitHub Actions workflow (`.github/workflows/dbt_ci.yml`) automatically runs on every pull request.

**Trigger:** `pull_request` — on `opened`, `synchronize`, and `reopened` events.

**Steps:**

1. Checkout the repository
2. Set up Python 3.13 with pip cache
3. Authenticate with Google Cloud using the provisioned service account key
4. Install dbt and dependencies from `requirements.txt`
5. Parse and validate all models (`dbt parse --target ci`)
6. Execute all models (`dbt run --target ci`)
7. Run all data quality tests (`dbt test --target ci`)

The `ci` profile target authenticates using `service-account-json`, reading the key directly from the `GCP_SERVICE_ACCOUNT_KEY` GitHub secret — no key file on disk.

---

## Required Secrets

Add the following secrets to your GitHub repository (`Settings → Secrets and variables → Actions`):

| Secret | Description |
|---|---|
| `GCP_PROJECT_ID` | The GCP project ID where BigQuery datasets are hosted |
| `GCP_SERVICE_ACCOUNT_KEY` | Full JSON content of the service account key file |
