defmodule Cinder.ActorTransfer do
  @moduledoc false

  # A private, lossless envelope for the async collection boundary. A normal
  # process copy expands shared actors throughout a prepared query and page.
  # Put each distinct full actor in the envelope once, then rebuild references
  # in the receiver before invoking any Ash or application code.
  #
  # Discover actors through Ash's scope protocol and canonical :actor entries.
  # Also replace equal occurrences elsewhere, whatever a scope calls its fields.
  # Equality includes all fields, not just identity. Closures are opaque and unchanged;
  # their captured actors may still lose sharing during transport.
  defstruct [:payload, actors: %{}]

  def pack(payload) do
    replacements = collect_actors(payload, %{})
    {payload, _changed?} = replace(payload, replacements)

    %__MODULE__{
      payload: payload,
      actors: Map.new(replacements, fn {actor, ref} -> {ref, actor} end)
    }
  end

  def unpack(%__MODULE__{payload: payload, actors: actors}) do
    {payload, _changed?} = replace(payload, actors)
    payload
  end

  defp collect_actors({:actor, actor}, actors) when is_map(actor) do
    if Map.has_key?(actors, actor), do: actors, else: Map.put(actors, actor, make_ref())
  end

  defp collect_actors({:scope, scope}, actors) do
    actors =
      with impl when not is_nil(impl) <- Ash.Scope.ToOpts.impl_for(scope),
           {:ok, actor} when is_map(actor) <- Ash.Scope.ToOpts.get_actor(scope) do
        collect_actors({:actor, actor}, actors)
      else
        _ -> actors
      end

    collect_actors(scope, actors)
  end

  defp collect_actors(term, actors) when is_map(term) do
    term |> Map.to_list() |> collect_actors(actors)
  end

  defp collect_actors([head | tail], actors) do
    collect_actors(tail, collect_actors(head, actors))
  end

  defp collect_actors(term, actors) when is_tuple(term) do
    term |> Tuple.to_list() |> collect_actors(actors)
  end

  defp collect_actors(_term, actors), do: actors

  # Keep untouched subtrees physically intact. Rebuilding every result struct
  # would discard existing sharing even where no actor replacement is needed.
  defp replace(term, replacements) when map_size(replacements) == 0, do: {term, false}

  defp replace(term, replacements) when is_map(term) do
    case Map.fetch(replacements, term) do
      {:ok, replacement} ->
        {replacement, true}

      :error ->
        Enum.reduce(Map.to_list(term), {term, false}, fn {key, value}, {result, changed?} ->
          {new_key, key_changed?} = replace(key, replacements)
          {new_value, value_changed?} = replace(value, replacements)

          cond do
            key_changed? ->
              {result |> Map.delete(key) |> Map.put(new_key, new_value), true}

            value_changed? ->
              {Map.put(result, key, new_value), true}

            true ->
              {result, changed?}
          end
        end)
    end
  end

  defp replace(term, replacements) when is_reference(term) do
    case Map.fetch(replacements, term) do
      {:ok, replacement} -> {replacement, true}
      :error -> {term, false}
    end
  end

  defp replace([head | tail] = term, replacements) do
    {new_head, head_changed?} = replace(head, replacements)
    {new_tail, tail_changed?} = replace(tail, replacements)

    if head_changed? or tail_changed?,
      do: {[new_head | new_tail], true},
      else: {term, false}
  end

  defp replace(term, replacements) when is_tuple(term) do
    case replace(Tuple.to_list(term), replacements) do
      {list, true} -> {List.to_tuple(list), true}
      {_list, false} -> {term, false}
    end
  end

  defp replace(term, _replacements), do: {term, false}
end
