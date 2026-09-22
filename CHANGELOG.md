## [Unreleased]

## [1.2.0] - 2026-09-22

### Fixed

- **Consumers stopped consuming, permanently, after any connection recovery.**
  The exchange was declared passively, which records `durable: false` for
  topology recovery. On the first reconnect Bunny replayed that against a
  durable exchange, the broker answered `PRECONDITION_FAILED - inequivalent arg
  'durable'`, and the channel closed, taking every consumer with it. The process
  stayed alive and exited 0, so nothing restarted it.
- Acking or nacking a closed channel no longer raises into Bunny's work pool.
  The rescue for a failed ack used to nack on the same closed channel, and that
  second raise killed the consumer.
- `start` no longer raises `NameError` when the configured ORM is not loaded.
- `bunny` and `connection_pool` are required by the gem.
- Each consumer gets its own channel. Channels came from a pool that was
  handed back as soon as `subscribe` returned, so once there were more
  mappings than the pool size, consumers silently shared channels — and
  therefore shared a prefetch, a work pool, and the fate of that channel.

### Added

- A supervisor that checks the connection, consumers and channels every
  `supervision_interval`. After `unhealthy_grace` without consuming it shuts
  down and exits non-zero so the process is restarted. Transient reconnects are
  tolerated.
- `Core#start` returns false when the service died; `rabbit_carrots:eat` and the
  Puma plugin exit non-zero on it. `Core#healthy?` added.
- Config: `rabbitmq_exchange_durable` (default `true`), `prefetch` (default 10,
  was hardcoded), `supervision_interval` (5s), `startup_grace` (60s),
  `unhealthy_grace` (60s).
- Specs that run against a real broker (`docker compose up -d`), including a
  regression test that severs the connection and asserts messages are still
  consumed.

### Changed

- `bunny` floor raised from `>= 2.22` to `>= 3.1`; 2.x and 3.x record topology
  differently and only 3.x is tested.
- The rake task and Puma plugin now exit non-zero when the consumer dies.

## [0.1.0] - 2022-12-01

- Initial release
