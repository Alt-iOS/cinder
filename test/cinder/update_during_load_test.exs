defmodule Cinder.UpdateDuringLoadTest do
  use ExUnit.Case, async: true

  alias Cinder.LiveComponent

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id_field: :code,
        data: [%{code: 1, value: :original}, %{code: 2, value: :retained}],
        page: nil,
        total_count: nil,
        count_mode: true,
        selected_ids: MapSet.new(),
        __load_data_pending__: true,
        __load_data_changes__: %{},
        loading: true,
        silent: false,
        query: :test,
        filters: %{},
        sort_by: [],
        current_page: 1
      }
    }
  end

  defp deliver(socket, page) do
    {:noreply, socket} = LiveComponent.handle_async(:load_data, {:ok, {{:ok, page}, nil}}, socket)
    socket
  end

  for page <- [
        %{results: []},
        %Ash.Page.Offset{results: [], count: 2, limit: 2, offset: 2},
        %Ash.Page.Keyset{results: [], count: 2, limit: 2}
      ] do
    @page page
    test "latest concrete outcome wins with custom IDs for #{inspect(Map.get(page, :__struct__, :unpaginated))}" do
      {:ok, socket} =
        LiveComponent.update(%{__update_item__: {1, &%{&1 | value: :first}}}, socket())

      # Even returning the original value is an intervening update, not a no-op.
      {:ok, socket} =
        LiveComponent.update(%{__update_item__: {1, &%{&1 | value: :original}}}, socket)

      page = %{@page | results: [%{code: 1, value: :from_read}, %{code: 2, value: :from_read}]}
      socket = deliver(socket, page)
      assert socket.assigns.data == [%{code: 1, value: :original}, %{code: 2, value: :from_read}]
      refute socket.assigns.loading

      # A later read is authoritative: completed-read changes must not leak into it.
      socket = deliver(socket, page)
      assert socket.assigns.data == page.results
    end
  end

  test "removal wins over an earlier update and adjusts the returned count once" do
    {:ok, socket} =
      LiveComponent.update(%{__update_item__: {1, &%{&1 | value: :updated}}}, socket())

    {:ok, socket} = LiveComponent.update(%{__remove_items__: ["1"]}, socket)
    page = %Ash.Page.Offset{results: [%{code: 1}, %{code: 2}], count: 2, limit: 2}
    socket = deliver(socket, page)
    assert socket.assigns.data == [%{code: 2}]
    assert socket.assigns.total_count == 1
    assert socket.assigns.page.count == 1
  end

  for result <- [{:ok, {{:error, :failed}, nil}}, {:exit, :failed}], silent <- [true, false] do
    @result result
    @silent silent
    test "#{inspect(result)} clears intervening changes (silent=#{silent})" do
      {:ok, socket} =
        LiveComponent.update(%{__update_item__: {1, &%{&1 | value: :updated}}}, socket())

      socket = Phoenix.Component.assign(socket, :silent, @silent)

      ExUnit.CaptureLog.capture_log(fn ->
        {:noreply, socket} = LiveComponent.handle_async(:load_data, @result, socket)
        socket = deliver(socket, %{results: [%{code: 1, value: :from_read}]})
        assert socket.assigns.data == [%{code: 1, value: :from_read}]
        refute socket.assigns.loading
      end)
    end
  end
end
