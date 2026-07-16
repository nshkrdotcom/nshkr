defmodule Nshkr.Runtime.InfrastructureSecurityTest do
  use ExUnit.Case, async: false

  alias Nshkr.Runtime.ObjectStore.MinioS3

  alias Nshkr.Runtime.SecretStore.{
    Material,
    VaultKubernetesAuth,
    VaultKvV2
  }

  defmodule S3Credentials do
    @behaviour Nshkr.Runtime.ObjectStore.CredentialProvider

    @impl true
    def fetch(_opts) do
      {:ok,
       %{
         access_key_id: "test-access-key",
         secret_access_key: "sentinel-secret-key",
         session_token: "sentinel-session-token"
       }}
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  test "Vault login, token verification, and KV material remain transient and redacted" do
    jwt_path =
      Path.join(System.tmp_dir!(), "nshkr-vault-jwt-#{System.unique_integer([:positive])}")

    File.write!(jwt_path, "signed-service-account-jwt\n")
    on_exit(fn -> File.rm(jwt_path) end)

    Req.Test.stub(:vault_material, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/auth/kubernetes/login"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body =~ "signed-service-account-jwt"

          Req.Test.json(conn, %{
            auth: %{client_token: "sentinel-vault-token", lease_duration: 120, renewable: true}
          })

        {"GET", "/v1/kv/data/providers/gemini"} ->
          assert Plug.Conn.get_req_header(conn, "x-vault-token") == ["sentinel-vault-token"]

          Req.Test.json(conn, %{
            data: %{data: %{api_key: "sentinel-api-key"}, metadata: %{version: 7}}
          })
      end
    end)

    request_options = [plug: {Req.Test, :vault_material}]

    opts = [
      endpoint: "https://vault.test",
      mount: "kv",
      auth_module: VaultKubernetesAuth,
      auth_options: [
        role: "nshkr-runtime",
        jwt_path: jwt_path,
        request_options: request_options
      ],
      request_options: request_options
    ]

    assert {:ok, server} = VaultKvV2.start_link(Keyword.put(opts, :name, nil))
    assert {:ok, %Material{} = material} = VaultKvV2.read("providers/gemini", server)
    assert {:ok, %Material{} = fetched} = VaultKvV2.fetch("providers/gemini", opts)
    assert Material.material(material) == %{"api_key" => "sentinel-api-key"}
    assert Material.material(fetched) == %{"api_key" => "sentinel-api-key"}
    refute inspect(material) =~ "sentinel-api-key"
    refute inspect(:sys.get_state(server)) =~ "sentinel-vault-token"

    assert_raise ArgumentError, ~r/secret material is transient/, fn ->
      Jason.encode!(material)
    end
  end

  test "Vault preflight proves the authenticated token without returning it" do
    jwt_path =
      Path.join(System.tmp_dir!(), "nshkr-vault-jwt-#{System.unique_integer([:positive])}")

    File.write!(jwt_path, "jwt")
    on_exit(fn -> File.rm(jwt_path) end)

    Req.Test.stub(:vault_preflight, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/auth/kubernetes/login"} ->
          Req.Test.json(conn, %{
            auth: %{client_token: "token", lease_duration: 60, renewable: true}
          })

        {"GET", "/v1/auth/token/lookup-self"} ->
          assert Plug.Conn.get_req_header(conn, "x-vault-token") == ["token"]
          Req.Test.json(conn, %{data: %{id: "safe-token-ref"}})
      end
    end)

    request_options = [plug: {Req.Test, :vault_preflight}]

    assert :ok =
             VaultKvV2.probe(
               endpoint: "https://vault.test",
               mount: "kv",
               auth_module: VaultKubernetesAuth,
               auth_options: [
                 role: "nshkr-runtime",
                 jwt_path: jwt_path,
                 request_options: request_options
               ],
               request_options: request_options
             )
  end

  test "MinIO uses SigV4 credentials transiently for probe and object lifecycle" do
    Req.Test.stub(:minio_s3, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert authorization =~ "Credential=test-access-key/"
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["sentinel-session-token"]
      refute authorization =~ "sentinel-secret-key"

      case {conn.method, conn.request_path} do
        {"HEAD", "/artifacts"} ->
          Plug.Conn.resp(conn, 200, "")

        {"PUT", "/artifacts/tenants/t-1/result.txt"} ->
          conn |> Plug.Conn.put_resp_header("etag", "object-etag") |> Plug.Conn.resp(200, "")

        {"GET", "/artifacts/tenants/t-1/result.txt"} ->
          Plug.Conn.resp(conn, 200, "result")

        {"DELETE", "/artifacts/tenants/t-1/result.txt"} ->
          Plug.Conn.resp(conn, 204, "")
      end
    end)

    opts = [
      endpoint: "https://minio.test",
      bucket: "artifacts",
      region: "us-east-1",
      credential_provider: S3Credentials,
      credential_options: [],
      request_options: [plug: {Req.Test, :minio_s3}]
    ]

    assert :ok = MinioS3.probe(opts)
    assert {:ok, server} = MinioS3.start_link(Keyword.put(opts, :name, nil))

    assert {:ok, %{etag: "object-etag"}} =
             MinioS3.put("tenants/t-1/result.txt", "result", server: server)

    assert {:ok, "result"} = MinioS3.get("tenants/t-1/result.txt", server: server)
    assert :ok = MinioS3.delete("tenants/t-1/result.txt", server: server)
    refute inspect(:sys.get_state(server)) =~ "sentinel-secret-key"
  end
end
