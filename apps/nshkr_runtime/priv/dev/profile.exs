(fn ->
   required = [
     "NSHKR_MEZZANINE_DATABASE_URL",
     "NSHKR_CITADEL_DATABASE_URL",
     "NSHKR_OUTER_BRAIN_DATABASE_URL",
     "NSHKR_JIDO_DATABASE_URL",
     "NSHKR_SYNAPSE_PROGRAM_ID",
     "NSHKR_SYNAPSE_WORK_CLASS_ID",
     "NSHKR_SYNAPSE_MEMORY_PROOF_TOKEN_REF",
     "NSHKR_SYNAPSE_CONTROL_AUTHORITY_REF",
     "NSHKR_SYNAPSE_CONTROL_PERMISSION_DECISION_REF"
   ]

   env = Map.new(required, &{&1, System.fetch_env!(&1)})

   env =
     Map.merge(env, %{
       "NSHKR_RUNTIME_SECRET_DIR" =>
         System.get_env(
           "NSHKR_RUNTIME_SECRET_DIR",
           Path.expand("../../.runtime-secrets", __DIR__)
         ),
       "NSHKR_TEMPORAL_ADDRESS" => System.get_env("NSHKR_TEMPORAL_ADDRESS", "127.0.0.1:7233"),
       "NSHKR_VAULT_ENDPOINT" => System.get_env("NSHKR_VAULT_ENDPOINT", "http://127.0.0.1:18200"),
       "NSHKR_MINIO_ENDPOINT" => System.get_env("NSHKR_MINIO_ENDPOINT", "http://127.0.0.1:19000"),
       "NSHKR_CODEX_COMMAND" =>
         System.get_env("NSHKR_CODEX_COMMAND", System.find_executable("codex")),
       "NSHKR_CODEX_SESSION_ROOT_PARENT" =>
         System.get_env(
           "NSHKR_CODEX_SESSION_ROOT_PARENT",
           Path.join(
             System.get_env(
               "NSHKR_RUNTIME_SECRET_DIR",
               Path.expand("../../.runtime-secrets", __DIR__)
             ),
             "codex-sessions"
           )
         )
     })

   Nshkr.Runtime.DeveloperLocalProfile.document(env)
 end).()
