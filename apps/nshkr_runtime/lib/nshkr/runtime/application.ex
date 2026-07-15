defmodule Nshkr.Runtime.Application do
  @moduledoc """
  Production OTP application boundary for the NSHKR composition.

  Owner services are added here in dependency order after their contracts and
  production profiles are frozen by the implementation program.
  """

  use Application

  @impl true
  def start(_type, _args) do
    raise """
    NSHKR production composition is not configured. Complete the P00 contract
    freeze and P01 owner-service wiring before starting this release.
    """
  end
end
