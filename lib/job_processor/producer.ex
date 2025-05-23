defmodule JobProcessor.Producer do
  use GenStage
  require Logger

  @doc """
  Starts the producer with an initial state.

  The state can be anything, but we'll use a counter to start simple.
  """
  def start_link(initial \\ 0) do
    GenStage.start_link(__MODULE__, initial, name: __MODULE__)
  end

  @impl true
  def init(counter) do
    # Ensure counter is a number
    safe_counter = case counter do
      counter when is_number(counter) -> counter
      [] -> 0  # Handle empty list case specifically
      _ -> 0    # Default to 0 for any other non-numeric value
    end
    
    Logger.info("Producer starting with counter: #{safe_counter}")
    {:producer, safe_counter}
  end

  @impl true
  def handle_demand(demand, state) do
    Logger.info("Producer received demand for #{demand} events")

    # Ensure state is a number
    safe_state = case state do
      state when is_number(state) -> state
      [] -> 0  # Handle empty list case specifically
      _ -> 0    # Default to 0 for any other non-numeric value
    end

    # Generate events to fulfill demand
    events = Enum.to_list(safe_state..(safe_state + demand - 1))

    # Update our state
    new_state = safe_state + demand

    # Return events and new state
    {:noreply, events, new_state}
  end
end
