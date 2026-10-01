# TODO - idea list

## Incremental reports

The AFL++ queue only grows and id: numbers increase. Keep the merged profile
and the highest replayed id per instance, then replay only new entries on the
next run. Hourly coverage tracking of a large campaign will become cheap!

## Coverage over time and first hit

Replay in queue order using the time: field and record which input first
covered each line or function, plus a coverage-versus-time curve.

## Branch frontier list

From llvm-cov branch data, list branches where one direction is covered and
the other is not, ranked by the uncovered code behind them. These are the most
actionable targets for seeds, dictionaries and harness changes!
A file, maybe called "frontier.txt", next to gaps.txt.
