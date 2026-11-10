# Prices and history

[Guide](../README.md) › Understanding it

## What a scan records
For each item, a scan keeps the **price ladder**: how many are listed at each price. From it come
the cheapest price, a sturdier price that one lone listing cannot set, and the units on sale.

## Why the ladder matters
Buying 200 of something does not cost 200 times the cheapest price: you climb the ladder. Every
cost and profit in the addon is worked out by walking the ladder for the amount in question.

## The latest scan comes first
A young server's economy does not hold still, and you will not scan all day. So the addon leads
with **what the last scan saw and how old it is**. Estimates and patterns stand beside that as a
second opinion, never in its place. An old scan is marked in orange.

## What is kept
Everything, for good, inside the game's own saved file:

| Age of a scan | What is kept |
|---|---|
| up to 2 days | every scan |
| up to 3 weeks | one an hour |
| up to 4 months | one per six hours |
| older | one a day |

A run of scans that all saw the same price is kept as its first and last point. Details:
[How history is stored](../internals/storage.md).

Next: [Forecasts](forecasts.md)
