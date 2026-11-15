import Config

if config_env() == :test do
  config :ebox, req_options: [plug: {Req.Test, Ebox}, retry_delay: 0]
end
