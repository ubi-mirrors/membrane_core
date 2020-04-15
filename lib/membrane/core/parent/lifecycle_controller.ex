defmodule Membrane.Core.Parent.LifecycleController do
  @moduledoc false
  use Bunch
  use Membrane.Core.PlaybackHandler

  alias Bunch.Type
  alias Membrane.{Child, Core, Notification, Pad, Sync}

  alias Core.{
    Parent,
    Playback,
    PlaybackHandler,
    CallbackHandler,
    Message
  }

  alias Core.Child.PadModel
  alias Membrane.PlaybackState

  require Message
  require PadModel
  require PlaybackState

  @type state_t :: Core.Bin.State.t() | Core.Pipeline.State.t()

  @impl PlaybackHandler
  def handle_playback_state(old, new, state) do
    children_data =
      state
      |> Parent.ChildrenModel.get_children()
      |> Map.values()

    children_pids = children_data |> Enum.map(& &1.pid)

    children_pids
    |> Enum.each(&PlaybackHandler.request_playback_state_change(&1, new))

    :ok = toggle_syncs_active(old, new, children_data)

    state = %{state | pending_pids: children_pids |> MapSet.new()}

    if children_pids |> Enum.empty?() do
      {:ok, state}
    else
      PlaybackHandler.suspend_playback_change(state)
    end
  end

  @impl PlaybackHandler
  def handle_playback_state_changed(old, new, state) do
    callback = PlaybackHandler.state_change_callback(old, new)

    # This means all children have gone into `terminating` state
    # and we can kill their processes. They are killed synchronously.
    if new == :terminating do
      state
      |> Parent.ChildrenModel.get_children()
      |> Enum.map(fn {_name, entry} -> entry end)
      |> Enum.each(&Core.Element.shutdown(&1.pid))
    end

    action_handler = get_callback_action_handler(state)

    callback_res =
      CallbackHandler.exec_and_handle_callback(
        callback,
        action_handler,
        [],
        state
      )

    # All children should have been killed by now (we kill synchronously).
    # If this process is a process of a pipeline, there is no parent to kill
    # us so we commit suicide.
    if new == :terminating and pipeline?(state),
      do: {:stop, :normal, state},
      else: callback_res
  end

  defp pipeline?(%Core.Pipeline.State{}), do: true
  defp pipeline?(_), do: false

  @spec change_playback_state(PlaybackState.t(), Playbackable.t()) ::
          PlaybackHandler.handler_return_t()
  def change_playback_state(new_state, state) do
    PlaybackHandler.change_playback_state(new_state, __MODULE__, state)
  end

  @spec handle_terminate(state_t) ::
          PlaybackHandler.handler_return_t() | {{:ok, :stop}, state_t}
  def handle_terminate(state) do
    PlaybackHandler.change_and_lock_playback_state(
      :terminating,
      Parent.LifecycleController,
      state
    )
  end

  @spec handle_notification(Child.name_t(), Notification.t(), state_t) ::
          Type.stateful_try_t(state_t)
  def handle_notification(from, notification, state) do
    with {:ok, _} <- state |> Parent.ChildrenModel.get_child_data(from) do
      action_handler = get_callback_action_handler(state)

      CallbackHandler.exec_and_handle_callback(
        :handle_notification,
        action_handler,
        [notification, from],
        state
      )
    else
      error ->
        {error, state}
    end
  end

  @spec handle_other(any, state_t()) :: Type.stateful_try_t(state_t)
  def handle_other(message, state) do
    action_handler = get_callback_action_handler(state)

    CallbackHandler.exec_and_handle_callback(
      :handle_other,
      action_handler,
      [message],
      state
    )
  end

  @spec child_playback_changed(pid, PlaybackState.t(), state_t()) ::
          PlaybackHandler.handler_return_t()
  def child_playback_changed(
        _pid,
        # new_playback_state,
        %{pending_pids: pending_pids} = state
      )
      when pending_pids == %MapSet{} do
    {:ok, state}
  end

  def child_playback_changed(
        _pid,
        new_playback_state,
        %{playback: %Playback{pending_state: pending_playback_state}} = state
      )
      when new_playback_state != pending_playback_state do
    {:ok, state}
  end

  def child_playback_changed(pid, _new_playback_state, %{pending_pids: pending_pids} = state) do
    new_pending_pids = pending_pids |> MapSet.delete(pid)
    new_state = %{state | pending_pids: new_pending_pids}

    if new_pending_pids != pending_pids and new_pending_pids |> Enum.empty?() do
      PlaybackHandler.continue_playback_change(__MODULE__, new_state)
    else
      {:ok, new_state}
    end
  end

  # Child was removed
  def handle_child_death(pid, :normal, state) do
    new_children =
      state
      |> Parent.ChildrenModel.get_children()
      |> Enum.filter(fn {_name, entry} -> entry.pid != pid end)
      |> Enum.into(%{})

    # TODO use children model here
    {:ok, %{state | children: new_children}}
  end

  @spec handle_stream_management_event(atom, Child.name_t(), Pad.ref_t(), state_t()) ::
          Type.stateful_try_t(state_t)
  def handle_stream_management_event(cb, element_name, pad_ref, state)
      when cb in [:handle_start_of_stream, :handle_end_of_stream] do
    action_handler = get_callback_action_handler(state)

    CallbackHandler.exec_and_handle_callback(
      to_parent_sm_callback(cb),
      action_handler,
      [{element_name, pad_ref}],
      state
    )
  end

  defp get_callback_action_handler(%Core.Pipeline.State{}), do: Core.Pipeline.ActionHandler
  defp get_callback_action_handler(%Core.Bin.State{}), do: Core.Bin.ActionHandler

  defp to_parent_sm_callback(:handle_start_of_stream), do: :handle_element_start_of_stream
  defp to_parent_sm_callback(:handle_end_of_stream), do: :handle_element_end_of_stream

  defp toggle_syncs_active(:prepared, :playing, children_data) do
    do_toggle_syncs_active(children_data, &Sync.activate/1)
  end

  defp toggle_syncs_active(:playing, :prepared, children_data) do
    do_toggle_syncs_active(children_data, &Sync.deactivate/1)
  end

  defp toggle_syncs_active(_old_playback_state, _new_playback_state, _children_data) do
    :ok
  end

  defp do_toggle_syncs_active(children_data, fun) do
    children_data |> Enum.uniq_by(& &1.sync) |> Enum.map(& &1.sync) |> Bunch.Enum.try_each(fun)
  end
end
