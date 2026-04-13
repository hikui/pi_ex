defmodule PiEx.Tracing.LangSmithTest do
  # async: false — env vars and app config are process-global in these tests
  use ExUnit.Case, async: false

  alias PiEx.Tracing.LangSmith

  setup do
    on_exit(fn ->
      Application.delete_env(:pi_ex, :enable_langsmith_tracing)
      Application.delete_env(:pi_ex, :langsmith)
      System.delete_env("LANGSMITH_API_KEY")
      System.delete_env("LANGSMITH_PROJECT")
      System.delete_env("LANGSMITH_ENDPOINT")
      System.delete_env("LANGSMITH_WORKSPACE_ID")
    end)

    :ok
  end

  describe "enabled?/0" do
    test "returns false when tracing is disabled" do
      Application.put_env(:pi_ex, :enable_langsmith_tracing, false)
      assert LangSmith.enabled?() == false
    end

    test "returns false when api key is missing" do
      Application.put_env(:pi_ex, :enable_langsmith_tracing, true)
      assert LangSmith.enabled?() == false
    end

    test "returns true when enabled with credentials" do
      Application.put_env(:pi_ex, :enable_langsmith_tracing, true)
      Application.put_env(:pi_ex, :langsmith, api_key: "lsv2_config")
      assert LangSmith.enabled?() == true
    end
  end

  describe "start_span/2 and finish_span/3" do
    test "uses env vars over app config and sends LangSmith-shaped requests" do
      requests = :ets.new(:langsmith_requests, [:set, :public])

      Req.Test.stub(LangSmithStub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        :ets.insert(
          requests,
          {String.to_atom("#{conn.method}_#{conn.request_path}"), {conn, body}}
        )

        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Application.put_env(:pi_ex, :enable_langsmith_tracing, true)

      Application.put_env(:pi_ex, :langsmith,
        api_key: "lsv2_config",
        project: "config-project",
        endpoint: "https://config.example.com",
        workspace_id: "config-workspace",
        tags: ["config-tag"],
        metadata: %{source: "config"},
        plug: {Req.Test, LangSmithStub}
      )

      System.put_env("LANGSMITH_API_KEY", "lsv2_env")
      System.put_env("LANGSMITH_PROJECT", "env-project")
      System.put_env("LANGSMITH_ENDPOINT", "https://env.example.com")
      System.put_env("LANGSMITH_WORKSPACE_ID", "env-workspace")

      assert {:ok, handle} =
               LangSmith.start_span(nil, %{
                 name: "pi_ex.agent",
                 type: :chain,
                 inputs: %{prompt: "hello"},
                 metadata: %{depth: 0},
                 tags: ["runtime-tag"]
               })

      assert :ok =
               LangSmith.finish_span(
                 handle,
                 %{
                   output: "done"
                 },
                 []
               )

      [{_, {post_conn, raw_post}}] = :ets.lookup(requests, :"POST_/runs")

      [{_, {patch_conn, raw_patch}}] =
        :ets.lookup(requests, String.to_atom("PATCH_/runs/#{handle.id}"))

      post_body = Jason.decode!(raw_post)
      patch_body = Jason.decode!(raw_patch)

      assert post_conn.host == "env.example.com"
      assert Plug.Conn.get_req_header(post_conn, "x-api-key") == ["lsv2_env"]
      assert Plug.Conn.get_req_header(post_conn, "x-tenant-id") == ["env-workspace"]
      assert post_body["session_name"] == "env-project"
      assert post_body["run_type"] == "chain"
      assert Enum.sort(post_body["tags"]) == ["config-tag", "runtime-tag"]
      assert post_body["extra"]["metadata"]["source"] == "config"
      assert post_body["extra"]["metadata"]["depth"] == 0
      assert patch_conn.host == "env.example.com"
      assert patch_body["outputs"]["output"] == "done"
      assert is_binary(patch_body["end_time"])
    end
  end
end
