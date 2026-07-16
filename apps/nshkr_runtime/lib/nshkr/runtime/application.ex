defmodule Nshkr.Runtime.Application do
  @moduledoc """
  Production OTP application boundary for the NSHKR composition.

  The release loads one immutable profile, verifies every durable dependency,
  and then starts owner services in dependency order. Product processes never
  select lower backends themselves.
  """

  use Application

  @impl true
  def start(_type, _args) do
    profile = Nshkr.Runtime.Profile.load!()
    :ok = Nshkr.Runtime.Preflight.verify!(profile)

    Supervisor.start_link(
      Nshkr.Runtime.Profile.child_specs(profile),
      strategy: :rest_for_one,
      name: Nshkr.Runtime.Supervisor
    )
  end
end
