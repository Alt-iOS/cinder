defmodule Cinder.ActorTransferTest do
  use ExUnit.Case, async: true
  alias Cinder.ActorTransfer
  alias Cinder.Support.ActorTransferScope

  defp actor do
    %{id: make_ref(), permissions: Enum.map(1..100, &%{name: Integer.to_string(&1)})}
  end

  test "preserves sharing across both real process boundaries" do
    actor = actor()
    query = Ash.Query.set_context(Ash.Query.new(TestUserResource), %{private: %{actor: actor}})
    payload = {query, actor: actor, nested: List.duplicate(%{actor: actor}, 20)}
    envelope = ActorTransfer.pack(payload)
    parent = self()

    spawn_link(fn ->
      {query, options} = decoded = ActorTransfer.unpack(envelope)
      query_actor = query.context.private.actor
      same? = :erts_debug.same(query_actor, options[:actor])
      all_same? = Enum.all?(options[:nested], &:erts_debug.same(&1.actor, query_actor))
      send(parent, {same?, all_same?, ActorTransfer.pack(decoded)})
    end)

    assert_receive {true, true, reply}
    {query, options} = decoded = ActorTransfer.unpack(reply)
    assert decoded === payload
    assert :erts_debug.same(query.context.private.actor, options[:actor])
    assert Enum.all?(options[:nested], &:erts_debug.same(&1.actor, options[:actor]))
  end

  test "discovers scope-only actors through the protocol across both process boundaries" do
    actor = actor()
    scope = %ActorTransferScope{user: actor, account: "north"}
    payload = {TestUserResource, scope: scope, context: %{current_user: actor}}
    envelope = ActorTransfer.pack(payload)
    assert map_size(envelope.actors) == 1
    parent = self()

    spawn_link(fn ->
      {_resource, options} = decoded = ActorTransfer.unpack(envelope)
      same? = :erts_debug.same(options[:scope].user, options[:context].current_user)
      send(parent, {same?, ActorTransfer.pack(decoded)})
    end)

    assert_receive {true, reply}
    {_resource, options} = decoded = ActorTransfer.unpack(reply)
    assert decoded === payload
    assert :erts_debug.same(options[:scope].user, options[:context].current_user)
  end

  test "keeps distinct actors from custom scopes separate and preserves actor-free scopes" do
    actor = actor()
    revoked = %{actor | permissions: []}

    payload = [
      scope: %ActorTransferScope{user: actor, account: "north"},
      nested: [scope: %ActorTransferScope{user: revoked, account: "south"}]
    ]

    envelope = ActorTransfer.pack(payload)
    assert map_size(envelope.actors) == 2
    assert ActorTransfer.unpack(envelope) === payload

    for scope <- [nil, "data field", %{}, %ActorTransferScope{}] do
      payload = [scope: scope]
      envelope = ActorTransfer.pack(payload)
      assert envelope.actors == %{}
      assert ActorTransfer.unpack(envelope) === payload
    end
  end

  test "equal IDs do not merge distinct grants, tenants or authorization options" do
    actor = actor()
    revoked = %{actor | permissions: []}

    payload = %{
      actor: actor,
      scope: %{current_user: actor, tenant: "north", authorize?: true},
      nested: %{actor: revoked, tenant: "south", authorize?: false},
      same_id: actor.id
    }

    envelope = ActorTransfer.pack(payload)
    assert map_size(envelope.actors) == 2

    restored =
      envelope |> :erlang.term_to_binary() |> :erlang.binary_to_term() |> ActorTransfer.unpack()

    assert restored === payload
    assert restored.actor.permissions != restored.nested.actor.permissions
    assert :erts_debug.same(restored.actor, restored.scope.current_user)
  end

  test "round trips structs, map keys, improper lists, references and opaque closures" do
    actor = actor()
    callback = fn -> actor end
    ref = make_ref()

    page = %Ash.Page.Keyset{
      results: [%{actor => [ref | actor]}],
      rerun: {%{actor: actor, callback: callback}, [scope: %{current_user: actor}]}
    }

    restored = page |> ActorTransfer.pack() |> ActorTransfer.unpack()
    assert restored === page
    assert elem(restored.rerun, 0).callback.() === actor
  end

  test "does not rebuild result data that contains no actor occurrences" do
    results = [%{id: make_ref(), metadata: %{labels: Enum.to_list(1..100)}}]
    payload = %{actor: actor(), results: results}
    packed = ActorTransfer.pack(payload)
    assert :erts_debug.same(packed.payload.results, results)
    restored = ActorTransfer.unpack(packed)
    assert :erts_debug.same(restored.results, results)
  end

  test "leaves actor-free payloads and non-map actors unchanged" do
    for payload <- [nil, {:error, :failed}, [actor: nil], %{actor: :system}, %{actor: 42}] do
      assert payload |> ActorTransfer.pack() |> ActorTransfer.unpack() === payload
    end
  end
end
