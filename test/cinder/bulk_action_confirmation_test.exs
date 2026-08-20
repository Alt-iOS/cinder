defmodule Cinder.BulkActionConfirmationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Cinder.BulkActionConfirmation
  alias Cinder.LiveComponent
  alias Cinder.Support.SearchTestResource

  setup {Cinder.TestHelpers, :disable_async_loading}

  @context %{
    selected_ids: MapSet.new(["one", "two"]),
    selected_count: 2,
    action: :destroy
  }

  describe "prepare/2" do
    test "returns nil data when no callback is configured" do
      assert {:ok, nil} = BulkActionConfirmation.prepare(nil, @context)
    end

    test "passes the confirmation context to the callback" do
      assert {:ok, selected_ids} =
               BulkActionConfirmation.prepare(
                 fn context -> {:ok, MapSet.to_list(context.selected_ids)} end,
                 @context
               )

      assert MapSet.new(selected_ids) == @context.selected_ids
    end

    test "normalizes plain callback values" do
      assert {:ok, :prepared} =
               BulkActionConfirmation.prepare(fn _context -> :prepared end, @context)
    end

    test "preserves callback errors" do
      assert {:error, :unavailable} =
               BulkActionConfirmation.prepare(
                 fn _context -> {:error, :unavailable} end,
                 @context
               )
    end

    test "normalizes raised exceptions as errors" do
      assert {:error, "preparation failed"} =
               BulkActionConfirmation.prepare(
                 fn _context -> raise "preparation failed" end,
                 @context
               )
    end
  end

  describe "LiveComponent confirmation lifecycle" do
    test "prepares confirmation data and clears it on cancel" do
      socket =
        socket(%{
          bulk_action_slots: [
            %{
              action: :destroy,
              confirmation: :slot,
              prepare_confirmation: fn context ->
                {:ok, MapSet.to_list(context.selected_ids)}
              end
            }
          ]
        })

      assert {:noreply, socket} =
               LiveComponent.handle_event("bulk_action_prepare", %{"index" => 0}, socket)

      assert socket.assigns.pending_bulk_action == 0
      assert MapSet.new(socket.assigns.bulk_action_confirmation_data) == @context.selected_ids
      assert socket.assigns.bulk_action_confirmation_error == nil

      assert {:noreply, socket} =
               LiveComponent.handle_event("bulk_action_cancel", %{}, socket)

      assert socket.assigns.pending_bulk_action == nil
      assert socket.assigns.bulk_action_confirmation_data == nil
      assert socket.assigns.bulk_action_confirmation_error == nil
    end

    test "keeps confirmation open and exposes preparation errors" do
      socket =
        socket(%{
          bulk_action_slots: [
            %{
              action: :destroy,
              confirmation: :slot,
              prepare_confirmation: fn _context -> {:error, :unavailable} end
            }
          ]
        })

      assert {:noreply, socket} =
               LiveComponent.handle_event("bulk_action_prepare", %{"index" => 0}, socket)

      assert socket.assigns.pending_bulk_action == 0
      assert socket.assigns.bulk_action_confirmation_data == nil
      assert socket.assigns.bulk_action_confirmation_error == :unavailable
    end

    test "keeps confirmation open and exposes execution errors" do
      action = fn _query, _opts -> {:error, :not_allowed} end

      socket =
        socket(%{
          query: SearchTestResource,
          pending_bulk_action: 0,
          bulk_action_confirmation_data: :prepared,
          bulk_action_slots: [
            %{action: action, confirmation: :slot, on_error: :bulk_action_failed}
          ]
        })

      assert {:noreply, socket} =
               LiveComponent.handle_event("bulk_action_execute", %{"index" => 0}, socket)

      assert socket.assigns.pending_bulk_action == 0
      assert socket.assigns.bulk_action_confirmation_data == :prepared
      assert socket.assigns.bulk_action_confirmation_error == :not_allowed

      assert_received {:bulk_action_failed,
                       %{
                         component_id: "test-collection",
                         action: ^action,
                         reason: :not_allowed
                       }}
    end

    test "closes confirmation state after successful execution" do
      action = fn _query, _opts -> {:ok, :done} end

      socket =
        socket(%{
          query: SearchTestResource,
          pending_bulk_action: 0,
          bulk_action_confirmation_data: :prepared,
          bulk_action_confirmation_error: :previous_error,
          bulk_action_slots: [
            %{action: action, confirmation: :slot, on_success: :bulk_action_succeeded}
          ]
        })

      assert {:noreply, socket} =
               LiveComponent.handle_event("bulk_action_execute", %{"index" => 0}, socket)

      assert socket.assigns.pending_bulk_action == nil
      assert socket.assigns.bulk_action_confirmation_data == nil
      assert socket.assigns.bulk_action_confirmation_error == nil
      assert socket.assigns.selected_ids == MapSet.new()

      assert_received {:bulk_action_succeeded,
                       %{
                         component_id: "test-collection",
                         action: ^action,
                         count: 2,
                         result: :done
                       }}
    end
  end

  describe "configuration warnings" do
    test "warns when slot confirmation content is missing" do
      log =
        capture_log(fn ->
          render_collection([
            %{action: :destroy, label: "Delete", confirmation: :slot}
          ])
        end)

      assert log =~ "require a <:bulk_action_confirmation> slot"
    end

    test "warns when browser and slot confirmations are both configured" do
      log =
        capture_log(fn ->
          render_collection(
            [
              %{
                action: :destroy,
                label: "Delete",
                confirm: "Delete records?",
                confirmation: :slot
              }
            ],
            confirmation_slot()
          )
        end)

      assert log =~ "cannot use both"
    end

    test "warns when custom confirmation content is unused" do
      log = capture_log(fn -> render_collection([], confirmation_slot()) end)

      assert log =~ "is unused"
    end
  end

  defp socket(assigns) do
    defaults = %{
      __changed__: %{},
      id: "test-collection",
      selected_ids: @context.selected_ids,
      id_field: :id,
      actor: nil,
      tenant: nil,
      scope: nil,
      pending_bulk_action: nil,
      bulk_action_confirmation_data: nil,
      bulk_action_confirmation_error: nil,
      query_opts: [],
      page_size: 25,
      current_page: 1,
      sort_by: [],
      filters: %{},
      columns: [],
      search_term: "",
      search_fn: nil,
      pagination_mode: :offset,
      after_keyset: nil,
      before_keyset: nil,
      page_size_config: Cinder.PageSize.parse(nil),
      on_query_change: nil,
      loading: false,
      error: false,
      data: []
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      root_pid: self()
    }
  end

  defp render_collection(bulk_actions, confirmation_slot \\ []) do
    render_component(&Cinder.collection/1, %{
      resource: SearchTestResource,
      actor: nil,
      selectable: true,
      col: [],
      bulk_action: bulk_actions,
      bulk_action_confirmation: confirmation_slot
    })
  end

  defp confirmation_slot do
    [%{inner_block: fn _assigns, _context -> "Confirmation" end}]
  end
end
