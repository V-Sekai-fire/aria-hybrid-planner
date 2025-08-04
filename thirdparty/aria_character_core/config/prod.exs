# Copyright (c) 2025-present K. S. Ernest (iFire) Lee

import Config

# Production configuration
config :logger, level: :info

# Production database configuration
config :aria_data, AriaData.Repo,
  url: System.get_env("DATABASE_URL") || System.get_env("CRDB_URL_MAIN"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: true

config :aria_data, AriaData.AuthRepo,
  url: System.get_env("CRDB_URL_AUTH") || "#{System.get_env("CRDB_BASE_URL")}/aria_auth",
  pool_size: String.to_integer(System.get_env("AUTH_POOL_SIZE") || "8"),
  ssl: true

# config :aria_data, AriaData.QueueRepo,
#   url: System.get_env("CRDB_URL_QUEUE") || "#{System.get_env("CRDB_BASE_URL")}/aria_queue",
#   pool_size: String.to_integer(System.get_env("QUEUE_POOL_SIZE") || "8"),
#   ssl: true

config :aria_data, AriaData.StorageRepo,
  url: System.get_env("CRDB_URL_STORAGE") || "#{System.get_env("CRDB_BASE_URL")}/aria_storage",
  pool_size: String.to_integer(System.get_env("STORAGE_POOL_SIZE") || "8"),
  ssl: true

config :aria_data, AriaData.MonitorRepo,
  url: System.get_env("CRDB_URL_MONITOR") || "#{System.get_env("CRDB_BASE_URL")}/aria_monitor",
  pool_size: String.to_integer(System.get_env("MONITOR_POOL_SIZE") || "6"),
  ssl: true

config :aria_data, AriaData.EngineRepo,
  url: System.get_env("CRDB_URL_ENGINE") || "#{System.get_env("CRDB_BASE_URL")}/aria_engine",
  pool_size: String.to_integer(System.get_env("ENGINE_POOL_SIZE") || "6"),
  ssl: true

# Production Oban configuration
# config :aria_queue, Oban,
#   repo: AriaData.QueueRepo,
#   notifier: Oban.Notifiers.PG,
#   plugins: [
#     Oban.Plugins.Pruner,
#     {Oban.Plugins.Cron,
#      crontab: [
#        {"0 2 * * *", AriaData.Workers.DatabaseCleanup},
#        {"*/15 * * * *", AriaStorage.Workers.CDNSync}
#      ]}
#   ],
#   queues: [
#     # Temporal planner queues (Resolution 2)
#     sequential_actions: 1,    # Single worker for strict temporal ordering
#     parallel_actions: String.to_integer(System.get_env("PARALLEL_ACTIONS_SIZE") || "5"),
#     instant_actions: String.to_integer(System.get_env("INSTANT_ACTIONS_SIZE") || "3"),
#     # Legacy application queues
#     ai_generation: String.to_integer(System.get_env("AI_QUEUE_SIZE") || "10"),
#     planning: String.to_integer(System.get_env("PLANNING_QUEUE_SIZE") || "20"),
#     storage_sync: String.to_integer(System.get_env("STORAGE_QUEUE_SIZE") || "5"),
#     monitoring: String.to_integer(System.get_env("MONITOR_QUEUE_SIZE") || "3")
#   ]

# Production OpenBao configuration
config :aria_security,
  openbao_url: System.get_env("OPENBAO_URL"),
  openbao_token: System.get_env("OPENBAO_TOKEN")

# Production Hammer rate limiting configuration
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}
