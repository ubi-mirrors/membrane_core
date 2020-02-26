defmodule Membrane.Core.Element.LifecycleControllerTest do
  use ExUnit.Case

  require Membrane.Core.Message

  alias Membrane.Core.Element.State
  alias Membrane.Core.Message
  alias Membrane.Pad.Data
  alias Membrane.Core.InputBuffer
  alias Membrane.Core.Element.LifecycleController

  defmodule DummyElement do
    use Membrane.Filter
    def_output_pad :output, caps: :any
  end

  setup do
    input_buf = InputBuffer.init(:test, :buffers, self(), :some_pad, preferred_size: 10)

    state =
      %{
        State.new(%{module: DummyElement, name: :test_name, clock: nil, sync: nil})
        | watcher: self(),
          type: :filter,
          pads: %{
            data: %{
              input: %Data{
                ref: :input,
                accepted_caps: :any,
                direction: :input,
                pid: self(),
                mode: :pull,
                start_of_stream?: true,
                end_of_stream?: false,
                input_buf: input_buf,
                demand: 0
              }
            }
          }
      }
      |> Bunch.Struct.put_in([:playback, :state], :playing)

    assert_received Message.new(:demand, 10, for_pad: :some_pad)
    [state: state]
  end

  test "End of stream is generated when playback state changes from :playing to :prepared", %{
    state: state
  } do
    {:ok, state} = LifecycleController.handle_playback_state(:playing, :prepared, state)
    assert state.pads.data.input.end_of_stream?
  end
end
