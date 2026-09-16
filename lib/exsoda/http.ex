defmodule Exsoda.Http do
  alias Req.Response
  alias Exsoda.Config
  require Logger

  def conf_fallback(options, key) do
    Keyword.get(options, key, Config.get(:exsoda, key))
  end

  def encode(s) do
    URI.encode_www_form(to_string(s))
  end

  defp make_url(url, api_root, proto) do
    "#{proto}://#{url}#{api_root}"
  end

  def base_url(%{opts: %{
      host: {:system, env_var, default},
      api_root: api_root,
      protocol: protocol
    }}) do

    host_str = System.get_env(env_var) || default
    {:ok, make_url(host_str, api_root, protocol)}
  end
  def base_url(%{opts: %{
      host: host,
      api_root: api_root,
      protocol: protocol
    }}) when is_function(host, 0) do
    with {:ok, host_str} <- host.() do
      {:ok, make_url(host_str, api_root, protocol)}
    end
  end
  def base_url(%{opts: %{
      host: {module, func, args},
      api_root: api_root,
      protocol: protocol
    }}) do
    with {:ok, host_str} <- apply(module, func, args) do
      {:ok, make_url(host_str, api_root, protocol)}
    end
  end

  def base_url(%{opts: %{host: host, api_root: api_root, protocol: protocol}}) do
    {:ok, make_url(host, api_root, protocol)}
  end
  def base_url(%{opts: %{domain: domain, api_root: api_root, protocol: protocol}}) do
    {:ok, make_url(domain, api_root, protocol)}
  end

  def headers(%{opts: %{domain: domain, user_agent: user_agent, request_id: request_id} = opts}) do

    headers = [
      {"User-Agent", user_agent},
      {"Content-Type", Map.get(opts, :content_type, "application/json")},
      {"X-Socrata-Host", domain},
      {"X-Socrata-RequestId", request_id}
    ]

    headers = case Map.get(opts, :filename) do
      nil -> headers
      filename -> [ {"X-File-Name", filename} | headers ]
    end

    headers = case Map.get(opts, :app_token) do
      nil -> headers
      app_token -> [ {"X-App-Token", app_token} | headers ]
    end

    headers
  end

  def get_cookie_impl(%{
    spoof: %{
      spoofee_email: spoofee_email,
      spoofer_email: spoofer_email,
      spoofer_password: spoofer_password
    },
    domain: _domain,
    request_id: request_id} = opts) do
    body = [{"username", "#{spoofee_email} #{spoofer_email}"}, {"password", "#{spoofer_password}"}]
    headers = [{"Content-Type", "application/x-www-form-urlencoded"} | headers(%{opts: opts})]

    Logger.info("Authenticating with request id: #{request_id}")
    with {:ok, base} <- base_url(%{opts: opts}),
         auth_path <- "#{base}/authenticate",
         {:ok, req_opts} <- req_opts(),
         {:ok, %Response{status: 200} = response} <-
           request(:post, auth_path, headers, {:form, body}, req_opts) do
      case Response.get_header(response, "set-cookie") do
        [cookie | _] -> {:ok, cookie}
        [] -> {:error, "There was no 'Set-Cookie' header in the authentication response."}
      end
    else
      {:ok, %Response{} = non_200_resp} -> {:error, non_200_resp}
      other -> other
    end
  end

  def get_cookie(opts) do
    case Process.whereis(Exsoda.AuthServer) do
      nil -> get_cookie_impl(opts)
      _ -> Exsoda.AuthServer.get_cookie(opts)
    end
  end

  defp req_opts(%{cookie: cookie}) do
    {:ok, Keyword.update(req_opts_config(), :headers, [{"cookie", cookie}], &[{"cookie", cookie} | &1])}
  end
  defp req_opts(%{
    spoof: _spoof,
    host: _host,
  } = opts) do
    with {:ok, cookie} <- get_cookie(opts) do
      req_opts(%{cookie: cookie})
    end
  end
  defp req_opts(%{account: account, password: password}) do
    {:ok, Keyword.put(req_opts_config(), :auth, {:basic, "#{account}:#{password}"})}
  end
  defp req_opts(_), do: {:ok, req_opts_config()}
  defp req_opts(), do: {:ok, req_opts_config()}

  defp req_opts_config, do: Config.get(:exsoda, :req_options, [])

  def http_opts(%{opts: options}) do
    with {:ok, req_options} <- req_opts(options) do
      connect_options =
        req_options
        |> Keyword.get(:connect_options, [])
        |> Keyword.put(:timeout, options.timeout)

      {:ok,
       req_options
       |> Keyword.put(:connect_options, connect_options)
       |> Keyword.put(:receive_timeout, options.recv_timeout)
       |> Keyword.put(:decode_body, false)}
    end
  end

  def request(method, url, headers, body, options) do
    headers = Keyword.get(options, :headers, []) ++ headers

    options =
      options
      |> Keyword.merge(method: method, url: url, headers: headers, retry: false, redirect: false)
      |> put_body(body)

    {request, response} = Req.run(options)

    case response do
      %Response{} = response ->
        response = Response.put_private(response, :exsoda_request_url, URI.to_string(request.url))
        {:ok, response}

      error ->
        {:error, error}
    end
  end

  defp put_body(options, nil), do: options
  defp put_body(options, {:form, form}), do: Keyword.put(options, :form, form)

  defp put_body(options, {:multipart, fields}) do
    fields =
      Enum.map(fields, fn
        {name, path} when is_binary(path) ->
          {name, {File.stream!(path, [], 64_000), filename: Path.basename(path)}}

        field ->
          field
      end)

    Keyword.put(options, :form_multipart, fields)
  end

  defp put_body(options, {:stream, stream}), do: Keyword.put(options, :body, stream)
  defp put_body(options, body), do: Keyword.put(options, :body, body)

  defp add_opt(opts, user_opts, key, default) do
    r = case conf_fallback(user_opts, key) do
      nil -> default
      value -> value
    end
    Map.put(opts, key, r)
  end

  defp add_opt(opts, user_opts, key) do
    case conf_fallback(user_opts, key) do
      nil -> opts
      value -> Map.put(opts, key, value)
    end
  end

  @alphabet String.split("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "")
  @numbers String.split("0123456789", "")
  @valid (@alphabet ++ @numbers ++ Enum.map(@alphabet, &String.downcase/1))

  defp random_request_id(len \\ 32) do
    1..len
    |> Enum.map(fn _ -> Enum.random(@valid) end)
    |> Enum.join("")
    |> String.downcase
  end

  def options(user_opts) do
    %{}
    |> add_opt(user_opts, :spoof)
    |> add_opt(user_opts, :domain)
    |> add_opt(user_opts, :account)
    |> add_opt(user_opts, :password)
    |> add_opt(user_opts, :host)
    |> add_opt(user_opts, :cookie)
    |> add_opt(user_opts, :user_agent, "exsoda")
    |> add_opt(user_opts, :request_id, random_request_id())
    |> add_opt(user_opts, :api_root, "/api")
    |> add_opt(user_opts, :protocol, "https")
    |> add_opt(user_opts, :app_token, nil)
    |> add_opt(user_opts, :recv_timeout, 5_000)
    |> add_opt(user_opts, :timeout, 5_000)
    |> add_opt(user_opts, :params, Keyword.get(user_opts, :params, []))
  end

  def as_json(result), do: as_json(result, [])

  # Core sometimes gives back empty responses
  def as_json({:ok, %Response{body: "", status: status}}, _json_opts) when (status >= 200) and (status < 300)  do
    {:ok, nil}
  end
  # Parse the body as json, return an error if we can't parse it
  def as_json({:ok, %Response{body: body, status: status} = resp}, json_opts) when (status >= 200) and (status < 300)  do
    with {:ok, body} <- decode_json(body, json_opts) do
      {:ok, %{resp | body: body}}
    end
  end
  # Convert bad statuses to error tuples
  def as_json({:ok, bad_status}, _json_opts), do: {:error, bad_status}
  # Leave connection errors unchanged
  def as_json(error, _json_opts), do: error

  defp decode_json(body, json_opts) do
    {as, json_opts} = Keyword.pop(json_opts, :as)

    with {:ok, decoded} <- Jason.decode(body, json_opts) do
      {:ok, decode_as(decoded, as)}
    end
  end

  defp decode_as(value, nil), do: value
  defp decode_as(values, [prototype]) when is_list(values), do: Enum.map(values, &decode_as(&1, prototype))

  defp decode_as(value, %{__struct__: module} = prototype) when is_map(value) do
    prototype
    |> Map.from_struct()
    |> Enum.reduce(struct(module), fn {key, nested_prototype}, result ->
      case Map.fetch(value, Atom.to_string(key)) do
        {:ok, nested_value} -> Map.put(result, key, decode_as(nested_value, nested_prototype))
        :error -> result
      end
    end)
  end

  defp decode_as(value, _prototype), do: value

  def get(path, op) do
    with {:ok, base} <- base_url(op),
         {:ok, http_options} <- http_opts(op) do
      Logger.debug("Getting with request_id: #{op.opts.request_id}")
      request(:get, "#{base}#{path}", headers(op), nil, http_options)
      |> as_json
    end
  end

  def delete(path, op) do
    with {:ok, base} <- base_url(op),
         {:ok, http_options} <- http_opts(op) do
      Logger.debug("Getting with request_id: #{op.opts.request_id}")
      request(:delete, "#{base}#{path}", headers(op), nil, http_options)
      |> as_json
    end
  end

  def post(path, op, body) do
    with {:ok, base} <- base_url(op),
         {:ok, http_options} <- http_opts(op) do
      Logger.debug("Posting with request_id: #{op.opts.request_id}")
      http_options_with_params = Keyword.put_new(http_options, :params, op.opts[:params])
      request(:post, "#{base}#{path}", headers(op), body, http_options_with_params)
      |> maybe_202(path, op, fn -> post(path, op, body) end)
    end
  end

  defp poll202(path, op, ticket, redo) do
    :timer.sleep(10000) # should this be configurable?

    with {:ok, base} <- base_url(op),
         {:ok, http_options} <- http_opts(op) do
      Logger.debug("Polling a 202 with request_id: #{op.opts.request_id} and ticket #{ticket}")

      if ticket do
        unticketed_url = "#{base}#{path}"
        sep = if String.contains?(unticketed_url, "?") do "&" else "?" end
        url = "#{unticketed_url}#{sep}ticket=#{encode(ticket)}"

        request(:get, url, headers(op), nil, http_options) |> maybe_202(path, op, redo)
      else
        redo.()
      end

    end
  end

  defp maybe_202({:ok, %Response{body: body, status: 202}}, path, op, redo) do
    case Jason.decode(body) do
      {:ok, %{"ticket" => ticket}} ->
        poll202(path, op, ticket, redo)
      {:ok, _} ->
        poll202(path, op, nil, redo)
      other ->
        other
    end
  end
  defp maybe_202(resp, _path, _op, _redo) do
    as_json(resp)
  end

  def put(path, op, body \\ "{}") do
    with {:ok, base} <- base_url(op),
         {:ok, http_options} <- http_opts(op) do
      Logger.debug("Putting with request_id: #{op.opts.request_id}")
      request(:put, "#{base}#{path}", headers(op), body, http_options)
      |> as_json
    end
  end

  def patch(path, op, body \\ "{}") do
    with {:ok, base} <- base_url(op),
         {:ok, http_options} <- http_opts(op) do
      Logger.debug("Patching with request_id: #{op.opts.request_id}")
      request(:patch, "#{base}#{path}", headers(op), body, http_options)
      |> as_json
    end
  end
end
