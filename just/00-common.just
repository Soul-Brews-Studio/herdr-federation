# Shared across every module. Imported, not a module.

port      := env_var_or_default("FED_PORT", "6750")
# the address peers should use to reach this node; loopback-only without it
advertise := env_var_or_default("FED_ADVERTISE", "")
api       := "http://127.0.0.1:" + port
