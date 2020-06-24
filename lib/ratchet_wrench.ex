defmodule RatchetWrench do
  @moduledoc """
  RatchetWrench is a easily use Google Cloud Spanner by Elixir.
  """

  def execute() do
    token = RatchetWrench.token
    connection = RatchetWrench.connection(token)
    {:ok, session} = RatchetWrench.Session.create(connection)
    json = %{sql: "SELECT 1"}
    {:ok, result_set} = GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_execute_sql(connection, session.name, [{:body, json}])
    {:ok, _} = RatchetWrench.Session.delete(connection, session)
    {:ok, result_set}
  end

  def token() do
    case Goth.Token.for_scope(token_scope()) do
      {:ok, token} -> token
<<<<<<< HEAD
      {:error, _} -> raise "goth config error. Check env `GCP_CREDENTIALS` or config"
=======
      {:error, reason} -> {:error, reason}
>>>>>>> origin/master
    end
  end

  def token_scope() do
    System.get_env("RATCHET_WRENCH_TOKEN_SCOPE") || "https://www.googleapis.com/auth/spanner.data"
  end

  def connection(token) do
    GoogleApi.Spanner.V1.Connection.new(token.token)
  end

  def create_session(connection) do
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_create(connection, database()) do
      {:ok, session} -> session
      {:error, _} -> raise "Database config error. Check env `RATCHET_WRENCH_DATABASE` or config"
    end
  end

  def batch_create_session(connection, session_count) do
    json = %{sessionCount: session_count}
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_batch_create(connection, database(), [{:body, json}]) do
      {:ok, response} -> response.session
      {:error, reason} ->
        raise "Database config error. Check env `RATCHET_WRENCH_DATABASE` or config"
    end
  end

  def delete_session(connection, session) do
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_delete(connection, session.name) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_ddl(ddl_list) do
    connection = RatchetWrench.connection(RatchetWrench.token)
    json = %{statements: ddl_list}
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_update_ddl(connection, database(), [{:body, json}]) do
      {:ok, operation} -> {:ok, operation}
      {:error, reason} -> {:error, Poison.Parser.parse!(reason.body, %{})}
    end
  end

  def database() do
    System.get_env("RATCHET_WRENCH_DATABASE") || Application.fetch_env(:ratchet_wrench, :database)
  end

  def begin_transaction(connection, session) do
    json = %{options: %{readWrite: %{}} }
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_begin_transaction(connection, session.name, [{:body, json}]) do
      {:ok, transaction} -> {:ok, transaction}
      {:error, reason} -> {:error, Poison.Parser.parse!(reason.body, %{})}
    end
  end

  def rollback_transaction(connection, session, transaction) do
    json = %{transactionId: transaction.id}
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_rollback(connection, session.name, [{:body, json}]) do
      {:ok, empty} -> {:ok, empty}
      {:error, reason} -> {:error, Poison.Parser.parse!(reason.body, %{})}
    end
  end

  def commit_transaction(connection, session, transaction) do
    RatchetWrench.Logger.info("Commit transaction request, transaction_id: #{transaction.id}")
    json = %{transactionId: transaction.id}
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_commit(connection, session.name, [{:body, json}]) do
      {:ok, commit_response} ->
        RatchetWrench.Logger.info("Commited transaction, transaction_id: #{transaction.id}, time_stamp: #{commit_response.commitTimestamp}")
        {:ok, commit_response}
      {:error, reason} -> {:error, Poison.Parser.parse!(reason.body, %{})}
    end
  end

  def select_execute_sql(sql, params) do
    json = %{sql: sql, params: params}
    connection = RatchetWrench.token |> RatchetWrench.connection
    {:ok, session} = RatchetWrench.Session.create(connection)

    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_execute_sql(connection, session.name, [{:body, json}]) do
      {:ok, result_set} ->
        {:ok, _} = RatchetWrench.Session.delete(connection, session)
        {:ok, result_set}
      {:error, reason} ->
        {:ok, _} = RatchetWrench.Session.delete(connection, session)
        {:error, Poison.Parser.parse!(reason.body, %{})}
    end
  end

  def execute_sql(sql, params, param_types, seqno \\ 1) when is_binary(sql) and is_map(params) and is_integer(seqno)  do
    connection = RatchetWrench.token |> RatchetWrench.connection
    {:ok, session} = RatchetWrench.Session.create(connection)
    {:ok, transaction} = RatchetWrench.begin_transaction(connection, session)
    json = %{seqno: seqno, transaction: %{id: transaction.id}, sql: sql, params: params, paramTypes: param_types}

    case do_execute_sql(connection, session, transaction, json) do
      {:ok, result_set} ->
        RatchetWrench.commit_transaction(connection, session, transaction)
        {:ok, _} = RatchetWrench.Session.delete(connection, session)
        {:ok, result_set}
      {:error, reason} -> {:error, reason}
    end
  end

  def do_execute_sql(connection, session, transaction, json) do
    case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_execute_sql(connection, session.name, [{:body, json}]) do
      {:ok, result_set} ->
        {:ok, result_set}
      {:error, reason} -> error_googleapi(connection, session, transaction, reason)
    end
  end

  def error_googleapi(connection, session, transaction, reason) do
    # TODO: logging error
    reason_json = Poison.Parser.parse!(reason.body, %{})

    case rollback_transaction(connection, session, transaction) do
      {:ok, _} ->
        {:ok, _} = RatchetWrench.Session.delete(connection, session)
        {:error, reason_json}
      {:error, reason} ->
        {:ok, _} = RatchetWrench.Session.delete(connection, session)
        {:error, reason} # TODO: logging can not rollback
    end
  end

  def auto_limit_offset_execute_sql(sql, params, limit \\ 1_000_000) do
    {:ok, result_set_list} = do_auto_limit_offset_execute_sql(sql, params, limit)
    {:ok, result_set_list}
  end

  def do_auto_limit_offset_execute_sql(sql, params, limit, offset \\ 0, seqno \\ 1, acc \\ []) do
    limit_offset_sql = sql <> " LIMIT #{limit} OFFSET #{offset}"
    case select_execute_sql(limit_offset_sql, params) do
      {:ok, result_set} ->
        if result_set.rows == nil do
          {:ok, []}
        else
          result_set_list = acc ++ [result_set]
          if limit == Enum.count(result_set.rows) do
            offset = offset + limit
            do_auto_limit_offset_execute_sql(sql, params, limit, offset, seqno + 1, result_set_list)
          else
            {:ok, result_set_list}
          end
        end
      {:error, reason} ->
        too_large_error_message = "Result set too large. Result sets larger than 10.00M can only be yielded through the streaming API."
        if reason["error"]["message"] == too_large_error_message do
          limit = div(limit, 2)
          auto_limit_offset_execute_sql(sql, params, limit)
        end
    end
  end

  def transaction_execute_sql(sql_map_list) when is_list(sql_map_list) do
    valid_transaction_execute_sql_map_list!(sql_map_list)

    connection = RatchetWrench.token |> RatchetWrench.connection
    {:ok, session} = RatchetWrench.Session.create(connection)
    {:ok, transaction} = RatchetWrench.begin_transaction(connection, session)

    result_set_list = Enum.map(Enum.with_index(sql_map_list), fn({map, seqno}) ->
      seqno = seqno + 1
      sql = map.sql
      params = map.params
      param_types = map.param_types

      RatchetWrench.Logger.info("Transaction transaction_id: #{transaction.id}, sqlno: #{seqno}, sql: #{sql}")
      RatchetWrench.Logger.info("Transaction transaction_id: #{transaction.id}, sqlno: #{seqno}, params: " <> inspect params)
      RatchetWrench.Logger.info("Transaction transaction_id: #{transaction.id}, sqlno: #{seqno}, param_types: " <> inspect param_types)

      RatchetWrench.Logger.info("Request transaction execute sql, seq: #{seqno}, transaction_id: #{transaction.id}")
      json = %{seqno: seqno, transaction: %{id: transaction.id}, sql: sql, params: params, param_types: param_types}

      case GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_execute_sql(connection, session.name, [{:body, json}]) do
        {:ok, result_set} ->
          RatchetWrench.Logger.info("Transaction executed sql, seq: #{seqno}, transaction_id: #{transaction.id}")
          result_set
        {:error, reason} ->
          RatchetWrench.Logger.info("Transaction executed sql error, execute rollabck, seq: #{seqno}, transaction_id: #{transaction.id}")
          case rollback_transaction(connection, session, transaction) do
            {:ok, _} ->
              RatchetWrench.Logger.error(Poison.Parser.parse!(reason.body, %{}))
              raise "Transaction executed sql error, rollbacked!"
            {:error, _} -> raise "Transaction executed sql error, can't rollback error. Check your database!"
          end
      end
    end)
    RatchetWrench.commit_transaction(connection, session, transaction)
    {:ok, _} = RatchetWrench.Session.delete(connection, session)
    result_set_list
  end

  def valid_transaction_execute_sql_map_list!(sql_map_list) do
    Enum.each(sql_map_list, fn(map) ->
      do_valid_transaction_execute_sql_map_list!(map, :sql)
      do_valid_transaction_execute_sql_map_list!(map, :params)
      do_valid_transaction_execute_sql_map_list!(map, :param_types)
    end)
  end

  def do_valid_transaction_execute_sql_map_list!(map, key) do
    unless Map.has_key?(map, key) do
      raise "Not found sql #{key} in transaction execute sql map."
    end
  end


  def sql(sql) do
    connection = RatchetWrench.token |> RatchetWrench.connection
    {:ok, session} = RatchetWrench.Session.create(connection)
    json = %{sql: sql}
    {:ok, result_set} = GoogleApi.Spanner.V1.Api.Projects.spanner_projects_instances_databases_sessions_execute_sql(connection, session.name, [{:body, json}])
    {:ok, _} = RatchetWrench.Session.delete(connection, session)
    result_set
  end
end
