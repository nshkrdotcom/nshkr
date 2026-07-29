defmodule Nshkr.Runtime.MemoryReadQueryTest do
  use ExUnit.Case, async: false

  alias AppKit.Bridges.MezzanineBridge.OperatorAdapter

  alias AppKit.Core.{
    MemoryFragmentListRequest,
    MemoryFragmentProjection,
    MemoryFragmentProvenance,
    RequestContext
  }

  alias Nshkr.Runtime.MemoryReadQuery
  alias OuterBrain.{MemoryProvenance, MemoryRecord}

  defmodule FixtureState do
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{token: nil, records: %{}} end, name: __MODULE__)
  end

  defmodule ProofTokenStore do
    def fetch(proof_ref) do
      Agent.get(FixtureState, fn
        %{token: %{proof_id: ^proof_ref} = token} -> {:ok, token}
        _state -> {:error, :not_found}
      end)
    end
  end

  defmodule MemoryStore do
    def fetch_memory(tenant_ref, subject_ref, memory_ref, _opts) do
      Agent.get(FixtureState, fn state ->
        case Map.get(state.records, memory_ref) do
          %OuterBrain.MemoryRecord{
            tenant_ref: ^tenant_ref,
            subject_ref: ^subject_ref
          } = record ->
            {:ok, record}

          _other ->
            :error
        end
      end)
    end
  end

  setup do
    start_supervised!(FixtureState)

    token = token()
    first = memory("memory://outer-brain/working/one", :working)
    second = memory("memory://outer-brain/episodic/two", :episodic)

    Agent.update(FixtureState, fn _state ->
      %{
        token: token,
        records: %{first.memory_ref => first, second.memory_ref => second}
      }
    end)

    %{token: token, first: first, second: second}
  end

  test "AppKit reads exact proof-pinned demanded memory without raw payload", %{token: token} do
    {:ok, context} =
      RequestContext.new(%{
        trace_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        actor_ref: %{id: "actor://synapse/operator", kind: :human},
        tenant_ref: %{id: token.tenant_ref},
        installation_ref: %{
          id: token.installation_id,
          pack_slug: "synapse",
          status: :active,
          compiled_pack_revision: 1
        },
        request_id: "request://nshkr/memory/readback",
        idempotency_key: "nshkr-memory-readback"
      })

    {:ok, request} =
      MemoryFragmentListRequest.new(%{
        proof_token_ref: token.proof_id,
        include_provenance?: true
      })

    assert {:ok,
            [
              %MemoryFragmentProjection{fragment_ref: first_ref},
              %MemoryFragmentProjection{fragment_ref: second_ref}
            ] = projections} =
             OperatorAdapter.list_memory_fragments(context, request, query_options(token))

    assert [first_ref, second_ref] == token.fragment_ids
    assert Enum.all?(projections, &(&1.redaction_posture == "refs_only"))
    refute inspect(projections) =~ "raw-content-sentinel"

    assert {:ok, %MemoryFragmentProvenance{fragment_ref: ^first_ref} = provenance} =
             OperatorAdapter.memory_fragment_provenance(
               context,
               first_ref,
               query_options(token)
             )

    assert provenance.source_contract_name == "OuterBrain.MemoryContextProvenance.v2"
    assert provenance.proof_token_ref == token.proof_id
    refute inspect(provenance) =~ "raw-content-sentinel"
  end

  test "missing or cross-tenant proof-pinned fragments fail closed", %{token: token} do
    attrs = %{tenant_ref: token.tenant_ref, installation_ref: token.installation_id}

    Agent.update(FixtureState, fn state ->
      %{state | records: Map.delete(state.records, List.last(token.fragment_ids))}
    end)

    assert {:error, :demanded_memory_fragment_not_found} =
             MemoryReadQuery.list_fragments_by_proof_token(
               token,
               attrs,
               query_options(token)
             )

    assert {:error, :unauthorized_lower_read} =
             MemoryReadQuery.list_fragments_by_proof_token(
               token,
               %{attrs | tenant_ref: "tenant://other"},
               query_options(token)
             )
  end

  defp query_options(token) do
    [
      memory_proof_token_ref: token.proof_id,
      memory_read_query: MemoryReadQuery,
      memory_provenance_query: MemoryReadQuery,
      proof_token_store: ProofTokenStore,
      memory_store: MemoryStore,
      memory_repo: :fixture_repo
    ]
  end

  defp token do
    %{
      proof_id: "proof://mezzanine/recall/current",
      kind: :recall,
      tenant_ref: "tenant://nshkr/developer-local",
      installation_id: "installation://nshkr/developer-local",
      subject_id: "subject://synapse/current",
      epoch_used: 7,
      fragment_ids: [
        "memory://outer-brain/working/one",
        "memory://outer-brain/episodic/two"
      ],
      proof_hash: String.duplicate("a", 64),
      source_node_ref: "node://outer-brain/developer-local",
      commit_lsn: "0/16B6C50",
      commit_hlc: %{"wall_time_ms" => 1_785_254_400_000, "logical" => 1},
      evidence_refs: [%{"ref" => "evidence://outer-brain/retrieval/current"}],
      governance_decision_ref: %{"ref" => "decision://citadel/memory/current"},
      policy_refs: [%{"ref" => "policy://outer-brain/memory/v1"}]
    }
  end

  defp memory(memory_ref, class) do
    {:ok, provenance} =
      MemoryProvenance.new(%{
        source_ref: "artifact://outer-brain/source/#{class}",
        producer_ref: "producer://outer-brain/memory-engine",
        authority_ref: "authority://citadel/memory",
        trace_ref: "trace://outer-brain/memory/current",
        causal_parent_refs: ["artifact://outer-brain/parent/current"],
        recording_operation_ref: "operation://outer-brain/record-memory"
      })

    {:ok, record} =
      MemoryRecord.new(%{
        memory_ref: memory_ref,
        tenant_ref: "tenant://nshkr/developer-local",
        subject_ref: "subject://synapse/current",
        class: class,
        content_artifact_ref: "artifact://outer-brain/content/#{class}",
        content_digest:
          "sha256:" <>
            (:crypto.hash(:sha256, "raw-content-sentinel-#{class}")
             |> Base.encode16(case: :lower)),
        provenance: provenance,
        recorded_at: ~U[2026-07-28 12:00:00.000000Z]
      })

    record
  end
end
