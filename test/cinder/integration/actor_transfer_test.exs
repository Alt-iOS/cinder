defmodule Cinder.Integration.ActorTransferTest do
  use Cinder.ConnCase, async: false
  alias Cinder.Support.ActorTransferScope
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest, only: [live: 2, render_async: 1]

  defmodule ActorLabel do
    use Ash.Resource.Calculation

    def load(_query, _opts, %{actor: actor}) do
      if actor, do: send(actor.observer, {:calculation_actor, :load, self(), actor})
      []
    end

    def calculate(records, _opts, %{actor: actor}) do
      send(actor.observer, {:calculation_actor, :calculate, self(), actor})
      Enum.map(records, fn _ -> Enum.join(actor.permissions, ",") end)
    end
  end

  defmodule Record do
    use Ash.Resource,
      domain: Cinder.Integration.ActorTransferTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:tenant_id, :string)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    calculations do
      calculate(:actor_label, :string, Cinder.Integration.ActorTransferTest.ActorLabel,
        public?: true
      )
    end

    actions do
      defaults([:destroy])

      read :read do
        primary?(true)

        pagination do
          keyset?(true)
          required?(false)
        end
      end
    end

    policies do
      policy action(:read) do
        authorize_if(actor_attribute_equals(:allowed?, true))
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Cinder.Integration.ActorTransferTest.Record)
    end
  end

  setup {Cinder.TestHelpers, :enable_async_loading}

  test "async reads restore the full actor before calculation loading and enforce overrides", %{
    conn: conn
  } do
    actor = %{id: 1, allowed?: true, permissions: ["read", "warehouse:north"], observer: self()}
    Ash.Seed.seed!(Record, %{title: "North secret", tenant_id: "north"})
    Ash.Seed.seed!(Record, %{title: "South secret", tenant_id: "south"})

    on_exit(fn ->
      for tenant <- ["north", "south"] do
        Ash.bulk_destroy!(Record, :destroy, %{}, tenant: tenant, authorize?: false)
      end
    end)

    query =
      Record
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: "north")

    # Exercise both a raw resource with a scope-only actor and a prepared query.
    for input <- [Record, query] do
      path = fixture(input, %ActorTransferScope{user: actor, account: "north"})
      {:ok, view, _html} = live(conn, path)
      html = render_async(view)
      assert html =~ "North secret"
      assert html =~ "read,warehouse:north"
      refute html =~ "South secret"

      # Ignore preparation in the test process; observe the actual worker callback.
      messages = drain_calculation_actors([])

      assert Enum.any?(messages, fn {phase, pid, value} ->
               phase == :calculate and pid != self() and pid != view.pid and value === actor
             end)

      # With a prepared query, load discovery also has the actor already set.
      if input == query do
        assert Enum.any?(messages, fn {phase, pid, value} ->
                 phase == :load and pid != self() and pid != view.pid and value === actor
               end)
      end
    end

    revoked = %{actor | allowed?: false, permissions: []}
    # The prepared query retains the allowed actor. The explicit scope overrides
    # it during execution, so same-ID canonicalization must not widen access.
    denied_path = fixture(query, %ActorTransferScope{user: revoked, account: "north"})
    {:ok, denied, _html} = live(conn, denied_path)
    denied_html = render_async(denied)
    assert denied_html =~ "Access check failed"
    refute denied_html =~ "North secret"
  end

  defp fixture(query, scope) do
    Cinder.TestLive.Fixture.register(fn assigns ->
      assigns = Phoenix.Component.assign(assigns, query: query, scope: scope)

      ~H"""
      <Cinder.collection id="secured-records" query={@query} scope={@scope} query_opts={[load: [:actor_label]]} initial_load={:async}
        pagination={:infinite} page_size={1} error_message="Access check failed">
        <:col :let={record} field="title">{record.title}</:col>
        <:col :let={record} field="actor_label">{record.actor_label}</:col>
      </Cinder.collection>
      """
    end)
  end

  defp drain_calculation_actors(acc) do
    receive do
      {:calculation_actor, phase, pid, actor} ->
        drain_calculation_actors([{phase, pid, actor} | acc])
    after
      0 -> acc
    end
  end
end
