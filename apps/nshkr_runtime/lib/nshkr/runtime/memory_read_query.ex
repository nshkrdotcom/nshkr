defmodule Nshkr.Runtime.MemoryReadQuery do
  @moduledoc """
  AppKit-safe readback of exact demanded-memory refs pinned by a Mezzanine proof token.

  This boundary never re-runs retrieval and never dereferences memory bodies.
  Only immutable refs, digests, ordering evidence, and bounded provenance cross
  into the product projection.
  """

  alias Mezzanine.Audit.MemoryProofTokenStore
  alias OuterBrain.MemoryRecord
  alias OuterBrain.Persistence.Store

  @source_contract_name "OuterBrain.MemoryContextProvenance.v2"

  @spec list_fragments_by_proof_token(struct(), map(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_fragments_by_proof_token(token, attrs, opts)
      when is_map(token) and is_map(attrs) and is_list(opts) do
    with :ok <- validate_token(token, attrs),
         {:ok, records} <- fetch_exact_records(token, opts) do
      {:ok, Enum.map(records, &projection(&1, token))}
    end
  end

  def list_fragments_by_proof_token(_token, _attrs, _opts),
    do: {:error, :invalid_demanded_memory_query}

  @spec fragment_provenance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def fragment_provenance(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, fragment_ref} <- required_string(attrs, :fragment_ref),
         {:ok, proof_token_ref} <- required_option(opts, :memory_proof_token_ref),
         {:ok, token} <- proof_token_store(opts).fetch(proof_token_ref),
         :ok <- validate_token(token, attrs),
         true <- fragment_ref in token.fragment_ids,
         {:ok, record} <- fetch_record(token, fragment_ref, opts) do
      {:ok, provenance(record, token)}
    else
      false -> {:error, :memory_fragment_not_admitted_by_proof}
      :error -> {:error, :demanded_memory_fragment_not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_demanded_memory_provenance_query}
    end
  end

  def fragment_provenance(_attrs, _opts),
    do: {:error, :invalid_demanded_memory_provenance_query}

  defp validate_token(token, attrs) do
    context_tenant = value(attrs, :tenant_ref)
    context_installation = value(attrs, :installation_ref)

    cond do
      value(token, :kind) != :recall ->
        {:error, :recall_proof_token_required}

      not present?(value(token, :tenant_ref)) or not present?(value(token, :subject_id)) ->
        {:error, :invalid_demanded_memory_proof_scope}

      present?(context_tenant) and context_tenant != value(token, :tenant_ref) ->
        {:error, :unauthorized_lower_read}

      present?(context_installation) and present?(value(token, :installation_id)) and
          context_installation != value(token, :installation_id) ->
        {:error, :unauthorized_lower_read}

      not is_list(value(token, :fragment_ids)) or value(token, :fragment_ids) == [] or
          not Enum.all?(value(token, :fragment_ids), &present?/1) ->
        {:error, :invalid_demanded_memory_fragment_set}

      not positive_integer?(value(token, :epoch_used)) or
        not present?(value(token, :source_node_ref)) or
        not present?(value(token, :commit_lsn)) or
          not is_map(value(token, :commit_hlc)) ->
        {:error, :incomplete_demanded_memory_ordering_evidence}

      not valid_proof_hash?(value(token, :proof_hash)) ->
        {:error, :invalid_demanded_memory_proof_hash}

      true ->
        :ok
    end
  end

  defp fetch_exact_records(token, opts) do
    Enum.reduce_while(token.fragment_ids, {:ok, []}, fn fragment_ref, {:ok, records} ->
      case fetch_record(token, fragment_ref, opts) do
        {:ok, %MemoryRecord{} = record} -> {:cont, {:ok, [record | records]}}
        :error -> {:halt, {:error, :demanded_memory_fragment_not_found}}
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, :invalid_demanded_memory_record}}
      end
    end)
    |> then(fn
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end)
  end

  defp fetch_record(token, fragment_ref, opts) do
    memory_store(opts).fetch_memory(
      token.tenant_ref,
      token.subject_id,
      fragment_ref,
      tenant_id: token.tenant_ref,
      repo: Keyword.get(opts, :memory_repo, OuterBrain.Persistence.Repo)
    )
  end

  defp projection(%MemoryRecord{} = record, token) do
    invalidated? = not is_nil(record.deleted_at)

    %{
      fragment_ref: record.memory_ref,
      tenant_ref: record.tenant_ref,
      installation_ref: token.installation_id,
      tier: Atom.to_string(record.class),
      proof_token_ref: token.proof_id,
      proof_hash: prefixed_hash(token.proof_hash),
      source_node_ref: token.source_node_ref,
      snapshot_epoch: token.epoch_used,
      commit_lsn: token.commit_lsn,
      commit_hlc: token.commit_hlc,
      provenance_refs: provenance_refs(record),
      evidence_refs: evidence_refs(record, token),
      governance_refs: governance_refs(record, token),
      cluster_invalidation_status: if(invalidated?, do: "revoked", else: "none"),
      staleness_class: if(invalidated?, do: "invalidation_pending", else: "fresh"),
      redaction_posture: "refs_only",
      metadata: %{
        content_artifact_ref: record.content_artifact_ref,
        content_digest: record.content_digest,
        recorded_at: DateTime.to_iso8601(record.recorded_at),
        state: if(invalidated?, do: "revoked", else: "included")
      }
    }
  end

  defp provenance(%MemoryRecord{} = record, token) do
    %{
      fragment_ref: record.memory_ref,
      proof_token_ref: token.proof_id,
      proof_hash: prefixed_hash(token.proof_hash),
      source_contract_name: @source_contract_name,
      snapshot_epoch: token.epoch_used,
      source_node_ref: token.source_node_ref,
      commit_lsn: token.commit_lsn,
      commit_hlc: token.commit_hlc,
      provenance_refs: provenance_refs(record),
      evidence_refs: evidence_refs(record, token),
      governance_refs: governance_refs(record, token),
      metadata: %{
        content_artifact_ref: record.content_artifact_ref,
        content_digest: record.content_digest,
        recorded_at: DateTime.to_iso8601(record.recorded_at)
      }
    }
  end

  defp provenance_refs(%MemoryRecord{provenance: provenance}) do
    [
      %{
        source_ref: provenance.source_ref,
        producer_ref: provenance.producer_ref,
        authority_ref: provenance.authority_ref,
        trace_ref: provenance.trace_ref,
        causal_parent_refs: provenance.causal_parent_refs,
        recording_operation_ref: provenance.recording_operation_ref
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    ]
  end

  defp evidence_refs(record, token) do
    case token.evidence_refs do
      [_head | _tail] = refs -> refs
      _empty -> [record.content_artifact_ref]
    end
  end

  defp governance_refs(record, token) do
    [token.governance_decision_ref | List.wrap(token.policy_refs)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> [record.provenance.authority_ref]
      refs -> refs
    end
  end

  defp proof_token_store(opts),
    do: Keyword.get(opts, :proof_token_store, MemoryProofTokenStore)

  defp memory_store(opts), do: Keyword.get(opts, :memory_store, Store)

  defp required_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required_option, key}}
    end
  end

  defp required_string(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required_field, key}}
    end
  end

  defp prefixed_hash(<<"sha256:", _digest::binary-size(64)>> = hash), do: hash
  defp prefixed_hash(hash), do: "sha256:" <> hash

  defp valid_proof_hash?(<<"sha256:", digest::binary-size(64)>>), do: lower_hex?(digest)
  defp valid_proof_hash?(digest) when byte_size(digest) == 64, do: lower_hex?(digest)
  defp valid_proof_hash?(_value), do: false

  defp lower_hex?(digest) do
    digest
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp value(map_or_struct, key) when is_map(map_or_struct),
    do: Map.get(map_or_struct, key) || Map.get(map_or_struct, Atom.to_string(key))

  defp value(_map_or_struct, _key), do: nil
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0
end
