defmodule Cinder.Support.ActorTransferScope do
  @moduledoc false
  defstruct [:user, :account]

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{user: nil}), do: :error
    def get_actor(%{user: user}), do: {:ok, user}
    def get_tenant(%{account: nil}), do: :error
    def get_tenant(%{account: account}), do: {:ok, account}
    def get_context(_scope), do: :error
    def get_tracer(_scope), do: :error
    def get_authorize?(_scope), do: :error
  end
end
