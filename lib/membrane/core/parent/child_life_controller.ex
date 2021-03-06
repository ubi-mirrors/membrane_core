defmodule Membrane.Core.Parent.ChildLifeController do
  @moduledoc false
  use Bunch

  alias __MODULE__.{StartupHandler, LinkHandler}
  alias Membrane.ParentSpec
  alias Membrane.Core.Parent
  alias Membrane.Core.Parent.{ChildEntryParser, ClockHandler, LifecycleController, Link}
  alias Membrane.Core.PlaybackHandler

  require Membrane.Logger
  require Membrane.Bin
  require Membrane.Element

  @spec handle_spec(ParentSpec.t(), Parent.state_t()) ::
          {{:ok, [Membrane.Child.name_t()]}, Parent.state_t()} | no_return
  def handle_spec(%ParentSpec{} = spec, state) do
    Membrane.Logger.debug("""
    Initializing spec
    children: #{inspect(spec.children)}
    links: #{inspect(spec.links)}
    """)

    children = ChildEntryParser.from_spec(spec.children)
    :ok = StartupHandler.check_if_children_names_unique(children, state)
    syncs = StartupHandler.setup_syncs(children, spec.stream_sync)

    children =
      StartupHandler.start_children(
        children,
        state.synchronization.clock_proxy,
        syncs,
        state.children_log_metadata
      )

    :ok = StartupHandler.maybe_activate_syncs(syncs, state)
    {:ok, state} = StartupHandler.add_children(children, state)
    children_names = children |> Enum.map(& &1.name)
    state = ClockHandler.choose_clock(children, spec.clock_provider, state)
    {:ok, links} = Link.from_spec(spec.links)
    links = LinkHandler.resolve_links(links, state)
    {:ok, state} = LinkHandler.link_children(links, state)
    {:ok, state} = StartupHandler.exec_handle_spec_started(children_names, state)
    state = StartupHandler.init_playback_state(children_names, state)
    {{:ok, children_names}, state}
  end

  @spec handle_forward([{Membrane.Child.name_t(), any}], Parent.state_t()) ::
          {:ok | {:error, any}, Parent.state_t()}
  def handle_forward(children_messages, state) do
    result = Bunch.Enum.try_each(children_messages, &do_handle_forward(&1, state))
    {result, state}
  end

  defp do_handle_forward({child_name, message}, state) do
    with {:ok, %{pid: pid}} <- state |> Parent.ChildrenModel.get_child_data(child_name) do
      send(pid, message)
      :ok
    else
      {:error, reason} ->
        {:error, {:cannot_forward_message, [element: child_name, message: message], reason}}
    end
  end

  @spec handle_remove_child(Membrane.Child.name_t() | [Membrane.Child.name_t()], Parent.state_t()) ::
          {:ok | {:error, any}, Parent.state_t()}
  def handle_remove_child(names, state) do
    names = names |> Bunch.listify()

    {:ok, state} =
      if state.synchronization.clock_provider.provider in names do
        ClockHandler.reset_clock(state)
      else
        {:ok, state}
      end

    with {:ok, data} <- Bunch.Enum.try_map(names, &Parent.ChildrenModel.get_child_data(state, &1)) do
      {already_removing, data} = Enum.split_with(data, & &1.terminating?)

      if already_removing != [] do
        Membrane.Logger.warn("""
        Trying to remove children that are already being removed: #{
          Enum.map_join(already_removing, ", ", &inspect(&1.name))
        }. This may lead to 'unknown child' errors.
        """)
      end

      data |> Enum.each(&Process.monitor(&1.pid))
      data |> Enum.each(&PlaybackHandler.request_playback_state_change(&1.pid, :terminating))

      {:ok, state} =
        Parent.ChildrenModel.update_children(state, names, &%{&1 | terminating?: true})

      {:ok, state}
    else
      error -> {error, state}
    end
  end

  @spec child_playback_changed(pid, Membrane.PlaybackState.t(), Parent.state_t()) ::
          {:ok | {:error, any}, Parent.state_t()}
  def child_playback_changed(pid, child_pb_state, state) do
    child = child_by_pid(pid, state)
    %{playback: playback} = state

    cond do
      playback.pending_state == nil and playback.state == child_pb_state ->
        state = put_in(state, [:children, child, :playback_synced?], true)
        {:ok, state}

      playback.pending_state == child_pb_state ->
        state = put_in(state, [:children, child, :playback_synced?], true)
        LifecycleController.maybe_finish_playback_transition(state)

      true ->
        {:ok, state}
    end
  end

  @spec handle_child_death(child_pid :: pid(), reason :: atom(), state :: Parent.state_t()) ::
          {:ok, Parent.state_t()}
  def handle_child_death(pid, :normal, state) do
    child = child_by_pid(pid, state)
    state = Bunch.Access.delete_in(state, [:children, child])
    LifecycleController.maybe_finish_playback_transition(state)
  end

  defp child_by_pid(pid, state) do
    {child_name, _child_data} =
      Enum.find(state.children, fn {_name, entry} -> entry.pid == pid end)

    child_name
  end
end
