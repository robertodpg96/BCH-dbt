{{
    config(
        materialized='view',
        schema='staging'
    )
}}

/*
    Staging model for Bitcoin Cash transactions.

    Selects the last 3 months of transactions from the public BigQuery dataset.
    This filter keeps queries within the BigQuery free tier on new GCP projects.

    Source: bigquery-public-data.crypto_bitcoin_cash.transactions
*/

select
    transactions.hash                   as transaction_hash,
    transactions.block_hash,
    transactions.block_number,
    transactions.block_timestamp,
    transactions.block_timestamp_month,
    transactions.size                   as transaction_size_bytes,
    transactions.virtual_size           as virtual_size_bytes,
    transactions.version,
    transactions.lock_time,
    transactions.is_coinbase,
    transactions.input_count,
    transactions.output_count,
    transactions.input_value            as input_value_satoshis,
    transactions.output_value           as output_value_satoshis,
    transactions.fee                    as fee_satoshis,
    transactions.inputs,
    transactions.outputs

from {{ source('crypto_bitcoin_cash', 'transactions') }} as transactions

where transactions.block_timestamp >= timestamp_sub(current_timestamp(), interval 90 day)
