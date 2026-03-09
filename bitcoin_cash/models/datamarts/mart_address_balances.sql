{{
    config(
        materialized='table',
        schema='datamart',
        cluster_by=['address']
    )
}}

/*
    Data mart: current balance for all Bitcoin Cash addresses.

    Logic:
      - Balance = total BCH received (outputs) - total BCH spent (inputs)
      - Values are in satoshis (1 BCH = 100,000,000 satoshis)
      - Addresses that appear in any coinbase transaction are excluded.
        Coinbase transactions are the first transaction in each block and
        create new coins as the block reward for miners.

    Source: stg_bitcoin_cash__transactions (last 3 months of data)
*/

with

-- Addresses that received outputs from a coinbase (block reward) transaction.
-- These are excluded from the final result per business requirements.
coinbase_addresses as (

    select distinct addr as address
    from {{ ref('stg_bitcoin_cash__transactions') }}
    cross join unnest(outputs) as output
    cross join unnest(output.addresses) as addr
    where is_coinbase = true

),

-- Total BCH received per address: sum of all output values directed to the address.
received as (

    select
        addr                as address,
        sum(output.value)   as total_received_satoshis

    from {{ ref('stg_bitcoin_cash__transactions') }}
    cross join unnest(outputs) as output
    cross join unnest(output.addresses) as addr

    group by addr

),

-- Total BCH spent per address: sum of all input values originating from the address.
-- Coinbase inputs are excluded as they have no real sender address.
spent as (

    select
        addr                as address,
        sum(input.value)    as total_spent_satoshis

    from {{ ref('stg_bitcoin_cash__transactions') }}
    cross join unnest(inputs) as input
    cross join unnest(input.addresses) as addr
    where is_coinbase = false

    group by addr

)

select
    r.address,
    r.total_received_satoshis,
    coalesce(s.total_spent_satoshis, 0)                                     as total_spent_satoshis,
    r.total_received_satoshis - coalesce(s.total_spent_satoshis, 0)         as balance_satoshis,
    (r.total_received_satoshis - coalesce(s.total_spent_satoshis, 0)) / 1e8 as balance_bch

from received r
left join spent s
    on r.address = s.address

-- Exclude addresses involved in any coinbase transaction
where r.address not in (select address from coinbase_addresses)
