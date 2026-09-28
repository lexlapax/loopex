defmodule LoopexLLMReqLLMTest.TLSSessionCacheProbe do
  @moduledoc """
  ## Concept

  Observe when an isolated TLS 1.2 control has actually saved both sessions.

  ## Technical depth

  This test-only callback delegates to OTP's role-specific default databases.
  The server database is an immutable tree, so its real cache process owns an
  unnamed protected ETS holder for each replacement. Only role and a
  credential-free observer stay in the client manager's process dictionary so
  OTP's roleless recovery init can retain the correct delegate.
  """

  @behaviour :ssl_session_cache_api

  @role_key {__MODULE__, :role}
  @observer_key {__MODULE__, :observer}
  @nonce_key {__MODULE__, :nonce}
  @fault_key {__MODULE__, :size_fault}

  @impl true
  def init(args) do
    role = Keyword.get(args, :role, Process.get(@role_key))
    observer = Keyword.get(args, :observer, Process.get(@observer_key))
    nonce = Keyword.get(args, :nonce, Process.get(@nonce_key))

    unless role in [:client, :server] and is_pid(observer) and is_reference(nonce),
      do: raise(ArgumentError, "TLS cache probe role and observer are required")

    Process.put(@role_key, role)
    Process.put(@observer_key, observer)
    Process.put(@nonce_key, nonce)

    if role == :client,
      do:
        send(observer, {:tls_cache_client_init, nonce, self(), Keyword.get(args, :fault, false)})

    if Keyword.get(args, :fault, false) and role == :client, do: Process.put(@fault_key, true)

    if role == :client and Keyword.get(args, :fault, false),
      do: send(observer, {:tls_cache_fault_armed, nonce, self()})

    if not Keyword.has_key?(args, :role),
      do: send(observer, {:tls_cache_reinit, nonce, role, self(), args == []})

    normalized_args = Keyword.put(args, :role, role)

    case role do
      :client ->
        {:client, :ssl_client_session_cache_db.init(normalized_args)}

      :server ->
        holder = :ets.new(:loopex_tls_server_cache, [:set, :protected])
        true = :ets.insert(holder, {:cache, :ssl_server_session_cache_db.init(normalized_args)})
        {:server, holder}
    end
  end

  @impl true
  def terminate({:client, cache}), do: :ssl_client_session_cache_db.terminate(cache)
  def terminate({:server, holder}), do: :ets.delete(holder)

  @impl true
  def lookup({:client, cache}, key), do: :ssl_client_session_cache_db.lookup(cache, key)
  def lookup({:server, holder}, key), do: :ssl_server_session_cache_db.lookup(tree(holder), key)

  @impl true
  def update({:client, cache}, key, session) do
    :ssl_client_session_cache_db.update(cache, key, session)

    if client_target?(key) and lookup({:client, cache}, key) == session,
      do: ready(:client)

    :ok
  end

  def update({:server, holder}, key, session) do
    next = :ssl_server_session_cache_db.update(tree(holder), key, session)
    true = :ets.insert(holder, {:cache, next})

    if target_set?() and :ssl_server_session_cache_db.lookup(next, key) == session,
      do: ready(:server)

    :ok
  end

  @impl true
  def delete({:client, cache}, key), do: :ssl_client_session_cache_db.delete(cache, key)

  def delete({:server, holder}, key) do
    next = :ssl_server_session_cache_db.delete(tree(holder), key)
    true = :ets.insert(holder, {:cache, next})
    :ok
  end

  @impl true
  def size({:client, cache}) do
    if Process.delete(@fault_key) == true do
      send(
        Process.get(@observer_key),
        {:tls_cache_fault_triggered, Process.get(@nonce_key), self()}
      )

      raise("test-only TLS client cache size fault")
    end

    :ssl_client_session_cache_db.size(cache)
  end

  def size({:server, holder}), do: :ssl_server_session_cache_db.size(tree(holder))

  @impl true
  def foldl(fun, acc, {:client, cache}),
    do: :ssl_client_session_cache_db.foldl(fun, acc, cache)

  @impl true
  def select_session({:client, cache}, server),
    do: :ssl_client_session_cache_db.select_session(cache, server)

  defp tree(holder) do
    [{:cache, tree}] = :ets.lookup(holder, :cache)
    tree
  end

  defp client_target?({{host, port}, _session_id}) do
    case Application.get_env(:ssl, :loopex_tls_probe_target) do
      {"localhost", ^port} -> host in ["localhost", ~c"localhost"]
      _ -> false
    end
  end

  defp client_target?(_), do: false

  defp target_set?,
    do:
      match?(
        {"localhost", port} when is_integer(port),
        Application.get_env(:ssl, :loopex_tls_probe_target)
      )

  defp ready(role) do
    send(Process.get(@observer_key), {:tls_cache_saved, Process.get(@nonce_key), role})
  end
end
