defmodule Nshkr.Runtime.GovernedGeminiTurnTest do
  use ExUnit.Case, async: true

  alias Nshkr.Runtime.GovernedGeminiTurn

  test "runtime starts the owned Gemini streaming manager" do
    assert :gemini_ex in Application.spec(:nshkr_runtime, :applications)
    assert is_pid(Process.whereis(Gemini.Streaming.UnifiedManager))
  end

  test "fixes the advertised provider/model and rejects secret-bearing caller input" do
    assert GovernedGeminiTurn.capability_id() ==
             "model.gemini.managed-account.local-effect"

    assert GovernedGeminiTurn.model() == "gemini-2.5-flash"

    assert {:error, {:secret_material_forbidden, [:api_key]}} =
             GovernedGeminiTurn.execute(%{api_key: "caller-secret"})
  end

  test "rejects model substitution and unknown operations before owner dispatch" do
    attrs = %{
      tenant_ref: "tenant-1",
      run_ref: "run://nshkr/test",
      turn_ref: "turn://nshkr/test/1",
      subject_ref: "subject://nshkr/test",
      input_artifact_ref: "artifact://nshkr/test/input",
      prompt: "hello"
    }

    assert {:error, {:unknown_governed_gemini_fields, [:model]}} =
             attrs
             |> Map.put(:model, "gemini-2.5-pro")
             |> GovernedGeminiTurn.execute()

    assert {:error, :invalid_governed_gemini_operation} =
             attrs
             |> Map.put(:operation, :live)
             |> GovernedGeminiTurn.execute()
  end
end
