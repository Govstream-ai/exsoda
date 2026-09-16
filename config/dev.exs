import Config

config :exsoda,
  domain: "localhost",
  host: "localhost",
  account: {:system, "SOCRATA_LOCAL_USER"},
  password: {:system, "SOCRATA_LOCAL_PASS"},
  req_options: [connect_options: [transport_opts: [verify: :verify_none]]]
